// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    ConsiderationItem,
    OfferItem,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ISubscriptionRegistry} from "./interfaces/ISubscriptionRegistry.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {SeaportOrderHash} from "./libraries/SeaportOrderHash.sol";

/// @title ListoorVault
/// @notice Custody for NFTs and wrapped native tokens that authorizes a hot "keeper" key to sign
///         Seaport orders on its behalf via EIP-1271, so the key trading the assets never owns them.
/// @dev The keeper key never moves assets: it can only produce signatures that Seaport accepts, and
///      only for orders that satisfy owner-set policy. Since Seaport validates signatures at
///      fulfillment time, rotating `keeper` revokes every outstanding order at once.
///
///      A digest alone says nothing about what is being sold, so the signature blob carries the
///      order components next to the ECDSA signature and the digest is re-derived from them. Once
///      the re-derived digest matches the one Seaport passed in, the components are exactly what
///      Seaport is about to execute and policy can be enforced against them.
///
///      Worst case for a compromised keeper key is therefore a sale at the floor or a bid at the
///      ceiling, not asset theft. Floors are loss bounds, not live prices: repricing below a floor
///      needs an owner transaction.
///
///      Signing is also gated on the keeper service being paid for, which the vault checks against
///      `subscriptions`. A lapse stops new orders and kills outstanding ones, but never touches
///      custody: withdrawals, cancels and policy keep working, so a vault is never held hostage.
contract ListoorVault is Ownable2Step, IERC1271 {
    using SafeERC20 for IERC20;

    /// @notice Sentinel for the native asset, matching Seaport's `NATIVE` items and used as the key
    ///         for native ETH in the payment-token allowlist.
    address public constant NATIVE_TOKEN = address(0);

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant DEFAULT_MAX_FEE_BPS = 1000;
    uint256 private constant DEFAULT_MAX_ORDER_DURATION = 30 days;

    /// @notice Seaport deployment whose orders this vault signs for.
    ConsiderationInterface public immutable seaport;

    /// @notice The only operator the vault ever approves: Seaport's conduit for OpenSea's key.
    address public immutable conduit;

    /// @notice Where the vault checks its keeper service is paid for, typically its factory.
    ISubscriptionRegistry public immutable subscriptions;

    bytes32 private immutable seaportVersionHash;

    /// @notice Hot key authorized to sign orders on the vault's behalf.
    address public keeper;

    /// @notice Longest `endTime - startTime` an order may span.
    uint256 public maxOrderDuration;

    /// @notice Largest share of a sale, in basis points, that may be routed to non-vault recipients.
    uint256 public maxFeeBps;

    /// @notice Tokens accepted as payment, keyed by address (`NATIVE_TOKEN` for the native asset).
    mapping(address token => bool allowed) public paymentTokenAllowed;

    /// @notice Minimum proceeds per unit sold, per collection. Zero makes a collection unlistable.
    mapping(address collection => uint256 floorPerUnit) public listingFloor;

    /// @notice Per-token override of `listingFloor`. Zero falls back to the collection floor.
    mapping(address collection => mapping(uint256 tokenId => uint256 floorPerUnit)) public
        tokenListingFloor;

    /// @notice Maximum the vault may bid per unit, per collection. Zero makes a collection unbiddable.
    mapping(address collection => uint256 ceilingPerUnit) public offerCeiling;

    event KeeperUpdated(address keeper);
    event ListingFloorUpdated(address indexed collection, uint256 floorPerUnit);
    event TokenListingFloorUpdated(
        address indexed collection, uint256 indexed tokenId, uint256 floorPerUnit
    );
    event OfferCeilingUpdated(address indexed collection, uint256 ceilingPerUnit);
    event PaymentTokenUpdated(address indexed token, bool allowed);
    event MaxOrderDurationUpdated(uint256 maxOrderDuration);
    event MaxFeeBpsUpdated(uint256 maxFeeBps);
    event EthWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error SeaportDomainMismatch(bytes32 derived, bytes32 reported);
    error DigestMismatch();
    error UnauthorizedSigner();
    error InvalidOfferer();
    error InvalidTimeRange();
    error OrderDurationTooLong(uint256 maxOrderDuration, uint256 duration);
    error EmptyOffer();
    error UnsupportedOfferItem(ItemType itemType);
    error UnsupportedConsiderationItem(ItemType itemType);
    error MalformedNativeItem(address token);
    error PaymentTokenNotAllowed(address token);
    error CollectionNotListable(address collection);
    error CollectionNotBiddable(address collection);
    error PriceBelowFloor(uint256 requiredProceeds, uint256 proceeds);
    error PriceAboveCeiling(uint256 maxSpend, uint256 spend);
    error FeeShareTooHigh(uint256 fees, uint256 total);
    error SubscriptionInactive();
    error ItemNotReceivedByVault(address recipient);
    error NoNftConsideration();
    error NotOwnerOrKeeper(address caller);
    error InvalidFeeBps(uint256 feeBps);
    error OwnershipCannotBeRenounced();

    modifier onlyOwnerOrKeeper() {
        _checkOwnerOrKeeper();
        _;
    }

    constructor(
        address seaport_,
        address conduit_,
        address owner_,
        address keeper_,
        address subscriptions_
    ) Ownable(owner_) {
        if (
            seaport_ == address(0) || conduit_ == address(0) || keeper_ == address(0)
                || subscriptions_ == address(0)
        ) {
            revert ZeroAddress();
        }

        (string memory version, bytes32 reportedDomainSeparator,) =
            ConsiderationInterface(seaport_).information();
        bytes32 versionHash = keccak256(bytes(version));
        bytes32 derivedDomainSeparator = SeaportOrderHash.domainSeparator(seaport_, versionHash);
        if (derivedDomainSeparator != reportedDomainSeparator) {
            revert SeaportDomainMismatch(derivedDomainSeparator, reportedDomainSeparator);
        }

        seaport = ConsiderationInterface(seaport_);
        conduit = conduit_;
        subscriptions = ISubscriptionRegistry(subscriptions_);
        seaportVersionHash = versionHash;
        keeper = keeper_;
        maxOrderDuration = DEFAULT_MAX_ORDER_DURATION;
        maxFeeBps = DEFAULT_MAX_FEE_BPS;

        emit KeeperUpdated(keeper_);
        emit MaxOrderDurationUpdated(DEFAULT_MAX_ORDER_DURATION);
        emit MaxFeeBpsUpdated(DEFAULT_MAX_FEE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                            ORDER VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates a Seaport order signed by the keeper key against owner-set policy.
    /// @param digest EIP-712 digest Seaport derived for the order it is about to fulfill.
    /// @param signature `abi.encode(OrderComponents, bytes)`: the order behind `digest` and the keeper
    ///        key's ECDSA signature over it.
    /// @dev Reverts rather than returning a non-magic value, so failures surface with a reason.
    ///      Orders must be signed one at a time. Seaport reads bulk-order proofs out of the
    ///      signature itself and derives a different digest from them; this encoding is always
    ///      word-aligned and therefore never lands in the length window Seaport treats that way.
    function isValidSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        if (!subscriptions.isSubscribed(address(this))) revert SubscriptionInactive();

        (OrderComponents memory order, bytes memory orderSignature) =
            abi.decode(signature, (OrderComponents, bytes));

        if (SeaportOrderHash.digest(seaportDomainSeparator(), order) != digest) {
            revert DigestMismatch();
        }
        if (ECDSA.recover(digest, orderSignature) != keeper) revert UnauthorizedSigner();

        _validatePolicy(order);

        return IERC1271.isValidSignature.selector;
    }

    /// @notice Seaport's EIP-712 domain separator on this chain.
    function seaportDomainSeparator() public view returns (bytes32) {
        return SeaportOrderHash.domainSeparator(address(seaport), seaportVersionHash);
    }

    /// @notice Minimum proceeds per unit for a token, per-token override taking precedence.
    function listingFloorFor(address collection, uint256 tokenId) public view returns (uint256) {
        uint256 floorPerUnit = tokenListingFloor[collection][tokenId];
        return floorPerUnit == 0 ? listingFloor[collection] : floorPerUnit;
    }

    /*//////////////////////////////////////////////////////////////
                                 POLICY
    //////////////////////////////////////////////////////////////*/

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function setListingFloor(address collection, uint256 floorPerUnit) external onlyOwner {
        listingFloor[collection] = floorPerUnit;
        emit ListingFloorUpdated(collection, floorPerUnit);
    }

    function setTokenListingFloor(address collection, uint256 tokenId, uint256 floorPerUnit)
        external
        onlyOwner
    {
        tokenListingFloor[collection][tokenId] = floorPerUnit;
        emit TokenListingFloorUpdated(collection, tokenId, floorPerUnit);
    }

    function setOfferCeiling(address collection, uint256 ceilingPerUnit) external onlyOwner {
        offerCeiling[collection] = ceilingPerUnit;
        emit OfferCeilingUpdated(collection, ceilingPerUnit);
    }

    function setPaymentTokenAllowed(address token, bool allowed) external onlyOwner {
        paymentTokenAllowed[token] = allowed;
        emit PaymentTokenUpdated(token, allowed);
    }

    function setMaxOrderDuration(uint256 newMaxOrderDuration) external onlyOwner {
        maxOrderDuration = newMaxOrderDuration;
        emit MaxOrderDurationUpdated(newMaxOrderDuration);
    }

    function setMaxFeeBps(uint256 newMaxFeeBps) external onlyOwner {
        if (newMaxFeeBps > BPS_DENOMINATOR) revert InvalidFeeBps(newMaxFeeBps);
        maxFeeBps = newMaxFeeBps;
        emit MaxFeeBpsUpdated(newMaxFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                                  OPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Approves (or revokes) the conduit to move a collection's tokens, so Seaport can
    ///         settle fills. Shared by ERC721 and ERC1155, which declare the same selector.
    function setConduitApprovalForAll(address collection, bool approved) external onlyOwner {
        IERC721(collection).setApprovalForAll(conduit, approved);
    }

    /// @notice Sets the conduit's allowance over an ERC20 the vault bids with.
    function setConduitAllowance(address token, uint256 amount) external onlyOwner {
        IERC20(token).forceApprove(conduit, amount);
    }

    /// @notice Cancels orders on-chain. Also callable by the keeper: cancelling is never theft,
    ///         and it is the only way to retract a listing that no zone can cancel off-chain.
    function cancelOrders(OrderComponents[] calldata orders)
        external
        onlyOwnerOrKeeper
        returns (bool)
    {
        return seaport.cancel(orders);
    }

    /// @notice Invalidates every order the vault has ever signed.
    function incrementCounter() external onlyOwner returns (uint256) {
        return seaport.incrementCounter();
    }

    /// @dev Disabled: the owner is the only way assets leave the vault, and the only way to revoke
    ///      the keeper. Renouncing would lock both forever. Use `transferOwnership` instead.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Wraps native proceeds so they can be bid with.
    /// @dev Restricted to allowlisted payment tokens, which is where the wrapped native token lives.
    function wrapETH(address weth, uint256 amount) external onlyOwnerOrKeeper {
        if (!paymentTokenAllowed[weth]) revert PaymentTokenNotAllowed(weth);
        IWETH(weth).deposit{value: amount}();
    }

    /// @notice Unwraps to the native asset, e.g. to fund gas top-ups from the owner side.
    function unwrapWETH(address weth, uint256 amount) external onlyOwnerOrKeeper {
        if (!paymentTokenAllowed[weth]) revert PaymentTokenNotAllowed(weth);
        IWETH(weth).withdraw(amount);
    }

    /// @notice Buys further subscription periods for this vault out of its own native balance.
    /// @dev Owner only: letting the keeper spend vault funds, even on the service, would hand a
    ///      compromised key a way to burn them. Keepers watch the expiry and raise the alarm instead.
    function renewSubscription(uint256 periods) external onlyOwner {
        uint256 cost = subscriptions.priceFor(address(this)) * periods;
        subscriptions.extendSubscription{value: cost}(address(this), periods);
    }

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        Address.sendValue(payable(to), amount);
        emit EthWithdrawn(to, amount);
    }

    function withdrawERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Unsafe transfer on purpose: `to` is owner-chosen and is often a smart-contract wallet
    ///      that does not implement `onERC721Received`.
    function withdrawERC721(address collection, address to, uint256 tokenId) external onlyOwner {
        IERC721(collection).transferFrom(address(this), to, tokenId);
    }

    function withdrawERC1155(address collection, address to, uint256 tokenId, uint256 amount)
        external
        onlyOwner
    {
        IERC1155(collection).safeTransferFrom(address(this), to, tokenId, amount, "");
    }

    /*//////////////////////////////////////////////////////////////
                                RECEIVING
    //////////////////////////////////////////////////////////////*/

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                           POLICY ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function _validatePolicy(OrderComponents memory order) private view {
        if (order.offerer != address(this)) revert InvalidOfferer();
        if (order.endTime <= order.startTime) revert InvalidTimeRange();

        uint256 duration = order.endTime - order.startTime;
        if (duration > maxOrderDuration) revert OrderDurationTooLong(maxOrderDuration, duration);
        if (order.offer.length == 0) revert EmptyOffer();

        // What the vault offers decides which side of the book this is: NFTs out is a listing,
        // tokens out is a bid. Zone and order type are left alone; both only ever restrict fills.
        ItemType offered = order.offer[0].itemType;
        if (offered == ItemType.ERC721 || offered == ItemType.ERC1155) {
            _validateSale(order);
        } else if (offered == ItemType.ERC20) {
            _validateBid(order);
        } else {
            revert UnsupportedOfferItem(offered);
        }
    }

    /// @dev Selling: every offered token must have a floor, and the vault's own proceeds must clear
    ///      the sum of those floors. Fees are excluded from the proceeds and capped separately, so
    ///      they cannot double as a payout channel.
    function _validateSale(OrderComponents memory order) private view {
        uint256 requiredProceeds;
        for (uint256 i; i < order.offer.length; ++i) {
            OfferItem memory item = order.offer[i];
            if (item.itemType != ItemType.ERC721 && item.itemType != ItemType.ERC1155) {
                revert UnsupportedOfferItem(item.itemType);
            }

            uint256 floorPerUnit = listingFloorFor(item.token, item.identifierOrCriteria);
            if (floorPerUnit == 0) revert CollectionNotListable(item.token);

            // Partial fills settle pro rata, so the floor binds per unit offered.
            requiredProceeds += floorPerUnit * Math.max(item.startAmount, item.endAmount);
        }

        (uint256 proceeds, uint256 fees) = _tallyPayments(order.consideration);
        if (proceeds < requiredProceeds) revert PriceBelowFloor(requiredProceeds, proceeds);

        uint256 total = proceeds + fees;
        if (fees * BPS_DENOMINATOR > total * maxFeeBps) revert FeeShareTooHigh(fees, total);
    }

    /// @dev Bidding: everything the vault offers is spend, and it is bounded by the ceilings of the
    ///      tokens the order delivers back to the vault. Criteria items are validated the same way;
    ///      the collection is what is constrained, the token id is not.
    function _validateBid(OrderComponents memory order) private view {
        uint256 spend;
        for (uint256 i; i < order.offer.length; ++i) {
            OfferItem memory item = order.offer[i];
            if (item.itemType != ItemType.ERC20) revert UnsupportedOfferItem(item.itemType);
            if (!paymentTokenAllowed[item.token]) revert PaymentTokenNotAllowed(item.token);
            spend += Math.max(item.startAmount, item.endAmount);
        }

        uint256 maxSpend;
        for (uint256 i; i < order.consideration.length; ++i) {
            ConsiderationItem memory item = order.consideration[i];
            if (_isPaymentItem(item.itemType)) {
                // Fees come out of the offered amount, which `maxSpend` already bounds.
                _requirePaymentItem(item.itemType, item.token);
                continue;
            }

            if (item.recipient != address(this)) revert ItemNotReceivedByVault(item.recipient);

            uint256 ceilingPerUnit = offerCeiling[item.token];
            if (ceilingPerUnit == 0) revert CollectionNotBiddable(item.token);
            maxSpend += ceilingPerUnit * Math.max(item.startAmount, item.endAmount);
        }

        if (maxSpend == 0) revert NoNftConsideration();
        if (spend > maxSpend) revert PriceAboveCeiling(maxSpend, spend);
    }

    /// @return proceeds the least the vault can end up with, so variable amounts count at their low
    /// @return fees the most everyone else can end up with, so variable amounts count at their high
    function _tallyPayments(ConsiderationItem[] memory consideration)
        private
        view
        returns (uint256 proceeds, uint256 fees)
    {
        for (uint256 i; i < consideration.length; ++i) {
            ConsiderationItem memory item = consideration[i];
            _requirePaymentItem(item.itemType, item.token);

            if (item.recipient == address(this)) {
                proceeds += Math.min(item.startAmount, item.endAmount);
            } else {
                fees += Math.max(item.startAmount, item.endAmount);
            }
        }
    }

    /// @dev The allowlist is expected to hold only assets of comparable value (native and its
    ///      wrapper), since floors and ceilings are denominated in whichever of them an order uses.
    function _requirePaymentItem(ItemType itemType, address token) private view {
        if (itemType == ItemType.NATIVE) {
            if (token != NATIVE_TOKEN) revert MalformedNativeItem(token);
        } else if (itemType != ItemType.ERC20) {
            revert UnsupportedConsiderationItem(itemType);
        }
        if (!paymentTokenAllowed[token]) revert PaymentTokenNotAllowed(token);
    }

    function _isPaymentItem(ItemType itemType) private pure returns (bool) {
        return itemType == ItemType.NATIVE || itemType == ItemType.ERC20;
    }

    function _checkOwnerOrKeeper() private view {
        if (msg.sender != owner() && msg.sender != keeper) {
            revert NotOwnerOrKeeper(msg.sender);
        }
    }
}
