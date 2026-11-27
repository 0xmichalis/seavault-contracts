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
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {IVaultOwnershipRegistry} from "./interfaces/IVaultOwnershipRegistry.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {SeaportOrderHash} from "./libraries/SeaportOrderHash.sol";

/// @title Seavault
/// @custom:security-contact security@kazani.ch
/// @notice Custody for NFTs and wrapped native tokens that authorizes a hot "keeper" key to sign
///         Seaport orders on its behalf via EIP-1271, so the key trading the assets never owns them.
/// @dev The keeper trades only within owner-set policy. With owner opt-in, it can also return ETH
///      and ERC20 funds to the owner. Rotating `keeper` also bumps the vault's
///      Seaport counter, which revokes every outstanding order at once.
///
///      A digest alone says nothing about what is being sold, so the signature blob carries the
///      order components next to the ECDSA signature and the digest is re-derived from them. Once
///      the re-derived digest matches the one Seaport passed in, the components are exactly what
///      Seaport is about to execute and policy can be enforced against them.
///
///      Worst case for a compromised keeper key is therefore a sale at the floor, or a bid or a buy
///      at the ceiling, not asset theft. A collection never sells below its ceiling in the same
///      denomination. Floors are loss bounds, not live prices: repricing below a floor needs an
///      owner transaction.
///
///      Policy binds whenever Seaport asks, and Seaport stops asking once an order is validated
///      on-chain, which anyone can do with its signature, or partially filled. Replacing the collection
///      policy root bumps the Seaport counter to retire those orders too. Other policy changes reach
///      them through a cancel or a counter bump. Orders outlive validation by at most twice the
///      `maxOrderDuration` in force when the vault vouched: an order may neither span nor start
///      further ahead than that.
contract Seavault is Ownable2Step, IERC1271 {
    using SafeERC20 for IERC20;

    /// @notice Sentinel for the native asset, matching Seaport's `NATIVE` items.
    address public constant NATIVE_TOKEN = address(0);

    /// @notice First word of an OpenSea login signature, `keccak256("Seavault.OpenSeaLogin")`.
    bytes32 public constant OPENSEA_LOGIN_TAG = keccak256("Seavault.OpenSeaLogin");

    /// @notice What the owner signs to approve an OpenSea login: EIP-712 `OpenSeaLogin` under the
    ///         domain `{name: "Seavault", version: "1", chainId, verifyingContract: vault}`.
    bytes32 public constant OPENSEA_LOGIN_TYPEHASH =
        keccak256("OpenSeaLogin(string message,uint256 deadline)");

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant DEFAULT_MAX_FEE_BPS = 1000;
    uint256 private constant DEFAULT_MAX_ORDER_DURATION = 30 days;
    uint256 private constant MAX_POLICY_DEPTH = 10;
    uint256 private constant MAX_POLICY_COLLECTIONS = 2 ** MAX_POLICY_DEPTH;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant LOGIN_DOMAIN_NAME_HASH = keccak256("Seavault");
    bytes32 private constant LOGIN_DOMAIN_VERSION_HASH = keccak256("1");
    bytes private constant OPENSEA_LOGIN_PREFIX =
        "opensea.io wants you to sign in with your Ethereum account:\n";

    /// @notice Seaport deployment whose orders this vault signs for.
    ConsiderationInterface public immutable seaport;

    /// @notice The only operator the vault ever approves: Seaport's conduit for OpenSea's key.
    address public immutable conduit;

    /// @notice The factory that keeps the vault's ownership index.
    IVaultOwnershipRegistry public immutable factory;

    bytes32 private immutable seaportVersionHash;

    address private immutable wNative;
    address private immutable usdc;

    /// @notice Hot key authorized to sign orders on the vault's behalf.
    address public keeper;

    /// @notice Longest `endTime - startTime` an order may span, and the furthest ahead of now an
    ///         order may start.
    uint256 public maxOrderDuration;

    /// @notice Largest share of a sale, in basis points, that may be routed to non-vault recipients.
    uint256 public maxFeeBps;

    /// @notice Owner's commitment to collection floors and ceilings. Zero disables listings, bids
    ///         and buys.
    bytes32 public policyRoot;

    /// @notice Native-denominated per-token floor override. Zero falls back to the collection floor.
    mapping(address collection => mapping(uint256 tokenId => uint256 floorPerUnit)) public
        tokenListingFloor;

    /// @notice The collection's minimum proceeds and maximum spend per NFT, the leaf's salt, and
    ///         its inclusion proof against `policyRoot`. Amounts use the order currency's base units.
    struct CollectionWitness {
        address collection;
        uint256 floor;
        uint256 ceiling;
        bytes32 salt;
        bytes32[] siblings;
    }

    /// @notice Native ETH buys may still spend. ERC20 buys draw on the conduit allowance, as bids do.
    uint256 public nativeBuyAllowance;

    /// @notice Owner opt-in to keeper-triggered ETH and ERC20 withdrawals to the current owner.
    /// @dev Disabled by default and cleared when ownership changes.
    bool public autoWithdrawEnabled;

    event KeeperUpdated(address keeper);
    event PolicyRootUpdated(bytes32 indexed root);
    event TokenListingFloorUpdated(
        address indexed collection, uint256 indexed tokenId, uint256 floorPerUnit
    );
    event MaxOrderDurationUpdated(uint256 maxOrderDuration);
    event MaxFeeBpsUpdated(uint256 maxFeeBps);
    event NativeBuyAllowanceUpdated(uint256 allowance);
    event AutoWithdrawEnabledUpdated(bool enabled);
    event EthWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error SeaportDomainMismatch(bytes32 derived, bytes32 reported);
    error DigestMismatch();
    error UnauthorizedSigner();
    error InvalidOfferer();
    error InvalidTimeRange();
    error OrderDurationTooLong(uint256 maxOrderDuration, uint256 duration);
    error OrderStartsTooLate(uint256 latestStartTime, uint256 startTime);
    error EmptyOffer();
    error UnsupportedOfferItem(ItemType itemType);
    error UnsupportedConsiderationItem(ItemType itemType);
    error PolicyRootMismatch(bytes32 expectedRoot, bytes32 currentRoot);
    error InvalidCollectionWitness();
    error MalformedNativeItem(address token);
    error PaymentTokenNotAllowed(address token);
    error CollectionNotListable(address collection);
    error CollectionNotBiddable(address collection);
    error PriceBelowFloor(uint256 requiredProceeds, uint256 proceeds);
    error PriceAboveCeiling(uint256 maxSpend, uint256 spend);
    error NativeBuyAllowanceExceeded(uint256 allowance, uint256 value);
    error FeeShareTooHigh(uint256 fees, uint256 total);
    error AutoWithdrawDisabled();
    error ItemNotReceivedByVault(address recipient);
    error NoNftConsideration();
    error NotOwnerOrKeeper(address caller);
    error InvalidFeeBps(uint256 feeBps);
    error OwnershipCannotBeRenounced();
    error OpenSeaLoginExpired(uint256 deadline);

    modifier onlyOwnerOrKeeper() {
        _checkOwnerOrKeeper();
        _;
    }

    constructor(
        address seaport_,
        address conduit_,
        address owner_,
        address keeper_,
        address factory_,
        address wNative_,
        address usdc_
    ) Ownable(owner_) {
        if (
            seaport_ == address(0) || conduit_ == address(0) || keeper_ == address(0)
                || factory_ == address(0) || wNative_ == address(0)
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
        factory = IVaultOwnershipRegistry(factory_);
        wNative = wNative_;
        usdc = usdc_;
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

    /// @notice Validates a Seaport order signed by the keeper key against owner-set policy, the
    ///         keeper's sign-off on cancelling an order through OpenSea without gas, or the owner's
    ///         approval of an OpenSea sign-in as the vault.
    /// @param digest EIP-712 digest Seaport derived for the order it is about to fulfill, the
    ///        `cancellationDigest` OpenSea checks before cancelling an order offchain, or the
    ///        EIP-191 hash of an OpenSea sign-in message.
    /// @param signature `abi.encode(OrderComponents, bytes, CollectionWitness[])`: the order behind
    ///        `digest`, the keeper key's ECDSA signature and the witnesses for its NFT collections in
    ///        ascending address order. For a cancellation, `abi.encode(orderHash, bytes)`. For
    ///        a sign-in, `abi.encode(OPENSEA_LOGIN_TAG, messageBody, deadline, ownerSignature)`, where
    ///        `messageBody` is the sign-in message minus its first two lines and their newlines.
    /// @dev Reverts rather than returning a non-magic value, so failures surface with a reason.
    ///      Orders must be signed one at a time: Seaport hands contract signers the single-order
    ///      digest, so a keeper signature over a bulk-order root never verifies. The encoding is
    ///      word-aligned, so Seaport never mistakes it for a bulk-order proof either.
    ///
    ///      A cancellation digest hashes an `OrderHash` struct, never an order, so vouching for one
    ///      approves that cancellation and nothing Seaport could fill. That is why it skips policy
    ///      and keeps working through a lapse, like every other way out.
    ///
    ///      A sign-in digest is re-derived from the message, which is an EIP-191 hash and never an
    ///      EIP-712 order or cancellation digest. It needs the owner, not the keeper, so it works
    ///      through a lapse or block like other owner actions.
    function isValidSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        bytes32 separator = seaportDomainSeparator();

        // An order blob opens with an ABI offset, which never hashes to the digest at hand.
        if (
            signature.length >= 32
                && SeaportOrderHash.cancellationDigest(separator, bytes32(signature[:32])) == digest
        ) {
            (, bytes memory cancellationSignature) = abi.decode(signature, (bytes32, bytes));
            if (ECDSA.recover(digest, cancellationSignature) != keeper) {
                revert UnauthorizedSigner();
            }
            return IERC1271.isValidSignature.selector;
        }

        if (signature.length >= 32 && bytes32(signature[:32]) == OPENSEA_LOGIN_TAG) {
            (, bytes memory messageBody, uint256 deadline, bytes memory ownerSignature) =
                abi.decode(signature, (bytes32, bytes, uint256, bytes));
            _validateOpenSeaLogin(digest, messageBody, deadline, ownerSignature);
            return IERC1271.isValidSignature.selector;
        }

        (
            OrderComponents memory order,
            bytes memory orderSignature,
            CollectionWitness[] memory witnesses
        ) = abi.decode(signature, (OrderComponents, bytes, CollectionWitness[]));

        if (SeaportOrderHash.digest(separator, order) != digest) {
            revert DigestMismatch();
        }
        if (ECDSA.recover(digest, orderSignature) != keeper) revert UnauthorizedSigner();

        _validatePolicy(order, witnesses);

        return IERC1271.isValidSignature.selector;
    }

    /// @notice Seaport's EIP-712 domain separator on this chain.
    function seaportDomainSeparator() public view returns (bytes32) {
        return SeaportOrderHash.domainSeparator(address(seaport), seaportVersionHash);
    }

    /// @notice What OpenSea has the offerer sign to cancel one of its orders without gas, i.e.
    ///         `OrderHash(bytes32 orderHash)` under Seaport's domain.
    function cancellationDigest(bytes32 orderHash) external view returns (bytes32) {
        return SeaportOrderHash.cancellationDigest(seaportDomainSeparator(), orderHash);
    }

    /*//////////////////////////////////////////////////////////////
                                 POLICY
    //////////////////////////////////////////////////////////////*/

    /// @notice Swaps the signing key and revokes every order the vault has signed so far.
    /// @dev The counter bump is what revokes them: Seaport stops asking the vault about an order once
    ///      it is validated on-chain or partially filled, so the signer check alone would leave those
    ///      live under the old key.
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        keeper = newKeeper;
        seaport.incrementCounter();
        emit KeeperUpdated(newKeeper);
    }

    /// @notice Activates a collection policy and revokes outstanding orders in the same transaction.
    /// @param expectedRoot The root the owner built the update from, to prevent overwriting an edit.
    /// @param newRoot The new commitment, or zero to disable listings, bids and buys.
    function setPolicyRoot(bytes32 expectedRoot, bytes32 newRoot) external onlyOwner {
        bytes32 currentRoot = policyRoot;
        if (currentRoot != expectedRoot) revert PolicyRootMismatch(expectedRoot, currentRoot);
        if (currentRoot == newRoot) return;
        policyRoot = newRoot;
        seaport.incrementCounter();
        emit PolicyRootUpdated(newRoot);
    }

    /// @notice Sets a token's own native-denominated listing floor. An override still requires a
    ///         collection witness so the vault can enforce the ceiling as well as the floor.
    function setTokenListingFloor(address collection, uint256 tokenId, uint256 floorPerUnit)
        external
        onlyOwner
    {
        tokenListingFloor[collection][tokenId] = floorPerUnit;
        emit TokenListingFloorUpdated(collection, tokenId, floorPerUnit);
    }

    /// @notice Reports whether the vault supports a currency. Orders also need a matching policy.
    function paymentTokenAllowed(address token) external view returns (bool allowed) {
        return token == NATIVE_TOKEN || token == wNative || token == usdc;
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

    /// @notice Sets whether the keeper can return ETH and ERC20 funds to the owner.
    function setAutoWithdrawEnabled(bool enabled) external onlyOwner {
        autoWithdrawEnabled = enabled;
        emit AutoWithdrawEnabledUpdated(enabled);
    }

    /*//////////////////////////////////////////////////////////////
                                  OPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Approves (or revokes) the conduit to move a collection's tokens, so Seaport can
    ///         settle fills. Shared by ERC721 and ERC1155, which declare the same selector.
    function setConduitApprovalForAll(address collection, bool approved) external onlyOwner {
        IERC721(collection).setApprovalForAll(conduit, approved);
    }

    /// @notice Sets the conduit's allowance over an ERC20 the vault bids or buys with.
    function setConduitAllowance(address token, uint256 amount) external onlyOwner {
        IERC20(token).forceApprove(conduit, amount);
    }

    /// @notice Sets how much native ETH buys may still spend. Keep it finite: together with the
    ///         conduit allowance, it is the hard cap on what a compromised keeper can spend.
    function setNativeBuyAllowance(uint256 allowance) external onlyOwner {
        nativeBuyAllowance = allowance;
        emit NativeBuyAllowanceUpdated(allowance);
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

    /// @notice Buys someone else's listing for the owner: Seaport fills it with the vault paying and
    ///         the owner receiving, in one transaction. Also callable by the keeper, held to the
    ///         same ceilings as its bids.
    /// @param order The listing as Seaport fills it, with the zone's `extraData` when it has one.
    /// @param fulfillerConduitKey Conduit ERC20 payments are pulled through. Only the vault's own
    ///        conduit holds an allowance, so any other key leaves an ERC20 price unpaid.
    /// @param witnesses Policies for the purchased NFT collections in ascending address order.
    /// @dev Bounded like a bid: everything paid, fees and tips included and counted at their high,
    ///      has to fit within the ceilings of the NFTs bought, counted at their low. Both sides scale
    ///      with the fill fraction alike, so the bound holds for partial fills too. Native payment
    ///      comes out of the vault's balance and `nativeBuyAllowance`, counted at what is sent;
    ///      Seaport refunds whatever a falling price leaves, without restoring the allowance.
    ///      The vault's own listings are refused: buying one would only move its NFT to the owner
    ///      at the cost of the fees.
    function buy(
        AdvancedOrder calldata order,
        bytes32 fulfillerConduitKey,
        CollectionWitness[] calldata witnesses
    ) external onlyOwnerOrKeeper returns (bool) {
        if (order.parameters.offerer == address(this)) {
            revert InvalidOfferer();
        }

        uint256 nativeSpend = _validateBuy(order.parameters, witnesses);
        uint256 value =
            Math.mulDiv(nativeSpend, order.numerator, order.denominator, Math.Rounding.Ceil);
        if (value > nativeBuyAllowance) {
            revert NativeBuyAllowanceExceeded(nativeBuyAllowance, value);
        }
        nativeBuyAllowance -= value;

        return seaport.fulfillAdvancedOrder{value: value}(
            order, new CriteriaResolver[](0), fulfillerConduitKey, owner()
        );
    }

    function _validateBuy(OrderParameters calldata order, CollectionWitness[] calldata witnesses)
        private
        view
        returns (uint256 nativeSpend)
    {
        _checkWitnessCount(witnesses.length, order.offer.length);
        ConsiderationItem[] calldata consideration = order.consideration;
        bool paysUsdc = consideration.length != 0 && _usesUsdc(consideration[0].token);
        CollectionWitness[] memory policies = witnesses;
        _verifyCollectionWitnesses(policies, paysUsdc);
        uint256 maxSpend;
        for (uint256 i; i < order.offer.length; ++i) {
            OfferItem calldata item = order.offer[i];
            if (item.itemType != ItemType.ERC721 && item.itemType != ItemType.ERC1155) {
                revert UnsupportedOfferItem(item.itemType);
            }
            uint256 ceilingPerUnit = _collectionPolicy(policies, item.token).ceiling;
            if (ceilingPerUnit == 0) revert CollectionNotBiddable(item.token);
            maxSpend += ceilingPerUnit * Math.min(item.startAmount, item.endAmount);
        }

        uint256 spend;
        for (uint256 i; i < consideration.length; ++i) {
            ConsiderationItem calldata item = consideration[i];
            _requirePaymentItem(item.itemType, item.token, paysUsdc);
            uint256 amount = Math.max(item.startAmount, item.endAmount);
            spend += amount;
            if (item.itemType == ItemType.NATIVE) nativeSpend += amount;
        }
        if (spend > maxSpend) revert PriceAboveCeiling(maxSpend, spend);
    }

    /// @notice Invalidates every order the vault has ever signed.
    function incrementCounter() external onlyOwner returns (uint256) {
        return seaport.incrementCounter();
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        address previousPendingOwner = pendingOwner();
        super.transferOwnership(newOwner);
        factory.syncVaultOwnership(owner(), previousPendingOwner);
    }

    function acceptOwnership() public override {
        address previousOwner = owner();
        address previousPendingOwner = pendingOwner();
        super.acceptOwnership();
        if (autoWithdrawEnabled && previousOwner != owner()) {
            autoWithdrawEnabled = false;
            emit AutoWithdrawEnabledUpdated(false);
        }
        factory.syncVaultOwnership(previousOwner, previousPendingOwner);
    }

    /// @dev Disabled: the owner controls withdrawals and is the only way to revoke the keeper.
    ///      Renouncing would lock both forever. Use `transferOwnership` instead.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Wraps native proceeds so they can be bid with.
    /// @dev Only the wrapped native token has a native deposit and redemption path.
    function wrapETH(address weth, uint256 amount) external onlyOwnerOrKeeper {
        if (weth != wNative) revert PaymentTokenNotAllowed(weth);
        IWETH(weth).deposit{value: amount}();
    }

    /// @notice Unwraps to the native asset, e.g. to fund gas top-ups from the owner side.
    function unwrapWETH(address weth, uint256 amount) external onlyOwnerOrKeeper {
        if (weth != wNative) revert PaymentTokenNotAllowed(weth);
        IWETH(weth).withdraw(amount);
    }

    /// @notice Returns ETH to the current owner after opt-in.
    /// @dev The keeper submits the transaction and pays gas; the recipient cannot be chosen.
    function autoWithdrawETH(uint256 amount) external onlyOwnerOrKeeper {
        _checkAutoWithdraw();
        address to = owner();
        Address.sendValue(payable(to), amount);
        emit EthWithdrawn(to, amount);
    }

    /// @notice Returns ERC20 funds to the current owner after opt-in.
    function autoWithdrawERC20(address token, uint256 amount) external onlyOwnerOrKeeper {
        _checkAutoWithdraw();
        IERC20(token).safeTransfer(owner(), amount);
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

    function _validatePolicy(OrderComponents memory order, CollectionWitness[] memory witnesses)
        private
        view
    {
        if (order.offerer != address(this)) revert InvalidOfferer();
        if (order.endTime <= order.startTime) revert InvalidTimeRange();

        uint256 duration = order.endTime - order.startTime;
        if (duration > maxOrderDuration) revert OrderDurationTooLong(maxOrderDuration, duration);
        // Seaport validates an order whatever its start time, so one starting far ahead would carry
        // today's policy for as long as the keeper likes.
        if (
            order.startTime > block.timestamp
                && order.startTime - block.timestamp > maxOrderDuration
        ) {
            revert OrderStartsTooLate(block.timestamp + maxOrderDuration, order.startTime);
        }
        if (order.offer.length == 0) revert EmptyOffer();

        // What the vault offers decides which side of the book this is: NFTs out is a listing,
        // tokens out is a bid. Zone and order type are left alone; both only ever restrict fills.
        ItemType offered = order.offer[0].itemType;
        if (offered == ItemType.ERC721 || offered == ItemType.ERC1155) {
            _checkWitnessCount(witnesses.length, order.offer.length);
            bool paysUsdc =
                order.consideration.length != 0 && _usesUsdc(order.consideration[0].token);
            _verifyCollectionWitnesses(witnesses, paysUsdc);
            _validateSale(order, witnesses, paysUsdc);
        } else if (offered == ItemType.ERC20) {
            _checkWitnessCount(witnesses.length, order.consideration.length);
            bool paysUsdc = _usesUsdc(order.offer[0].token);
            _verifyCollectionWitnesses(witnesses, paysUsdc);
            _validateBid(order, witnesses, paysUsdc);
        } else {
            revert UnsupportedOfferItem(offered);
        }
    }

    /// @dev Selling: every offered token must have a floor, and the vault's own proceeds must clear
    ///      the sum of those floors. Fees are excluded from the proceeds and capped separately, so
    ///      they cannot double as a payout channel.
    function _validateSale(
        OrderComponents memory order,
        CollectionWitness[] memory witnesses,
        bool paysUsdc
    ) private view {
        uint256 requiredProceeds;
        for (uint256 i; i < order.offer.length; ++i) {
            OfferItem memory item = order.offer[i];
            if (item.itemType != ItemType.ERC721 && item.itemType != ItemType.ERC1155) {
                revert UnsupportedOfferItem(item.itemType);
            }

            CollectionWitness memory policy = _collectionPolicy(witnesses, item.token);
            uint256 floorPerUnit =
                paysUsdc ? 0 : tokenListingFloor[item.token][item.identifierOrCriteria];
            if (floorPerUnit == 0) floorPerUnit = policy.floor;
            if (floorPerUnit == 0) revert CollectionNotListable(item.token);

            // Selling below the ceiling would let the keeper buy and sell back at a loss repeatedly.
            floorPerUnit = Math.max(floorPerUnit, policy.ceiling);
            // Partial fills settle pro rata, so the floor binds per unit offered.
            requiredProceeds += floorPerUnit * Math.max(item.startAmount, item.endAmount);
        }

        (uint256 proceeds, uint256 fees) = _tallyPayments(order.consideration, paysUsdc);
        if (proceeds < requiredProceeds) revert PriceBelowFloor(requiredProceeds, proceeds);

        uint256 total = proceeds + fees;
        if (fees * BPS_DENOMINATOR > total * maxFeeBps) revert FeeShareTooHigh(fees, total);
    }

    /// @dev Bidding: everything the vault offers is spend, and it is bounded by the ceilings of the
    ///      tokens the order delivers back to the vault. Criteria items are validated the same way;
    ///      the collection is what is constrained, the token id is not.
    function _validateBid(
        OrderComponents memory order,
        CollectionWitness[] memory witnesses,
        bool paysUsdc
    ) private view {
        uint256 spend;
        for (uint256 i; i < order.offer.length; ++i) {
            OfferItem memory item = order.offer[i];
            if (item.itemType != ItemType.ERC20) revert UnsupportedOfferItem(item.itemType);
            _requirePaymentItem(ItemType.ERC20, item.token, paysUsdc);
            spend += Math.max(item.startAmount, item.endAmount);
        }

        uint256 maxSpend;
        for (uint256 i; i < order.consideration.length; ++i) {
            ConsiderationItem memory item = order.consideration[i];
            if (_isPaymentItem(item.itemType)) {
                // Fees come out of the offered amount, which `maxSpend` already bounds.
                _requirePaymentItem(item.itemType, item.token, paysUsdc);
                continue;
            }

            if (item.recipient != address(this)) revert ItemNotReceivedByVault(item.recipient);

            uint256 ceilingPerUnit = _collectionPolicy(witnesses, item.token).ceiling;
            if (ceilingPerUnit == 0) revert CollectionNotBiddable(item.token);
            // Counted at its lowest: a late fill delivers whatever the amount has decayed to.
            maxSpend += ceilingPerUnit * Math.min(item.startAmount, item.endAmount);
        }

        if (maxSpend == 0) revert NoNftConsideration();
        if (spend > maxSpend) revert PriceAboveCeiling(maxSpend, spend);
    }

    function _checkWitnessCount(uint256 witnessCount, uint256 itemCount) private pure {
        if (witnessCount > itemCount || witnessCount > MAX_POLICY_COLLECTIONS) {
            revert InvalidCollectionWitness();
        }
    }

    /// @dev Verify a collection once even if several items use it. Address order gives callers a
    ///      canonical witness array and bounds item lookups to logarithmic work.
    function _verifyCollectionWitnesses(CollectionWitness[] memory witnesses, bool paysUsdc)
        private
        view
    {
        bytes32 root = policyRoot;
        if (root == bytes32(0)) revert InvalidCollectionWitness();
        address previous;
        for (uint256 i; i < witnesses.length; ++i) {
            CollectionWitness memory witness = witnesses[i];
            if (witness.collection <= previous || witness.siblings.length > MAX_POLICY_DEPTH) {
                revert InvalidCollectionWitness();
            }
            bytes32 inner = keccak256(
                abi.encode(witness.collection, witness.floor, witness.ceiling, witness.salt)
            );
            // The USDC tag makes leaf preimages 33 bytes for USDC, 32 for native and 64 for branches.
            bytes32 leaf = keccak256(paysUsdc ? bytes.concat(inner, hex"01") : bytes.concat(inner));
            if (!MerkleProof.verify(witness.siblings, root, leaf)) {
                revert InvalidCollectionWitness();
            }
            previous = witness.collection;
        }
    }

    function _collectionPolicy(CollectionWitness[] memory witnesses, address collection)
        private
        pure
        returns (CollectionWitness memory)
    {
        uint256 start;
        uint256 end = witnesses.length;
        while (start < end) {
            uint256 middle = (start + end) / 2;
            CollectionWitness memory witness = witnesses[middle];
            if (witness.collection == collection) return witness;
            if (witness.collection < collection) start = middle + 1;
            else end = middle;
        }
        revert InvalidCollectionWitness();
    }

    /// @return proceeds the least the vault can end up with, so variable amounts count at their low
    /// @return fees the most everyone else can end up with, so variable amounts count at their high
    function _tallyPayments(ConsiderationItem[] memory consideration, bool paysUsdc)
        private
        view
        returns (uint256 proceeds, uint256 fees)
    {
        for (uint256 i; i < consideration.length; ++i) {
            ConsiderationItem memory item = consideration[i];
            _requirePaymentItem(item.itemType, item.token, paysUsdc);

            if (item.recipient == address(this)) {
                proceeds += Math.min(item.startAmount, item.endAmount);
            } else {
                fees += Math.max(item.startAmount, item.endAmount);
            }
        }
    }

    function _requirePaymentItem(ItemType itemType, address token, bool paysUsdc) private view {
        if (itemType == ItemType.NATIVE) {
            if (token != NATIVE_TOKEN) revert MalformedNativeItem(token);
            if (!paysUsdc) return;
        } else if (itemType != ItemType.ERC20) {
            revert UnsupportedConsiderationItem(itemType);
        }
        if (token != (paysUsdc ? usdc : wNative)) revert PaymentTokenNotAllowed(token);
    }

    function _usesUsdc(address token) private view returns (bool) {
        return token != NATIVE_TOKEN && token == usdc;
    }

    function _isPaymentItem(ItemType itemType) private pure returns (bool) {
        return itemType == ItemType.NATIVE || itemType == ItemType.ERC20;
    }

    /// @dev Only OpenSea sign-ins as this vault qualify: the vault itself opens the message with
    ///      OpenSea's Sign-In with Ethereum preamble and its own EIP-55 address, which keeps the
    ///      owner's approval from turning the vault into a signer of arbitrary messages. OpenSea
    ///      checks the remaining fields, including its single-use nonce. The owner signs the full
    ///      message as typed data bound to this vault and chain, never as a sign-in naming the vault.
    function _validateOpenSeaLogin(
        bytes32 digest,
        bytes memory messageBody,
        uint256 deadline,
        bytes memory ownerSignature
    ) private view {
        bytes memory message = bytes.concat(
            OPENSEA_LOGIN_PREFIX,
            bytes(Strings.toChecksumHexString(address(this))),
            "\n",
            messageBody
        );
        if (MessageHashUtils.toEthSignedMessageHash(message) != digest) revert DigestMismatch();
        if (block.timestamp > deadline) revert OpenSeaLoginExpired(deadline);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                LOGIN_DOMAIN_NAME_HASH,
                LOGIN_DOMAIN_VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
        bytes32 approval = MessageHashUtils.toTypedDataHash(
            domainSeparator,
            keccak256(abi.encode(OPENSEA_LOGIN_TYPEHASH, keccak256(message), deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(owner(), approval, ownerSignature)) {
            revert UnauthorizedSigner();
        }
    }

    function _checkOwnerOrKeeper() private view {
        if (msg.sender != owner() && msg.sender != keeper) {
            revert NotOwnerOrKeeper(msg.sender);
        }
    }

    function _checkAutoWithdraw() private view {
        if (!autoWithdrawEnabled) revert AutoWithdrawDisabled();
    }
}
