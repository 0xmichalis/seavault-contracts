// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    ConsiderationItem,
    OfferItem,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../../src/ListoorVault.sol";
import {SeaportOrderHash} from "../../src/libraries/SeaportOrderHash.sol";
import {MockSeaport} from "../mocks/MockSeaport.sol";
import {MockERC1155, MockERC721, MockWETH} from "../mocks/TokenMocks.sol";

/// @notice Vault under a mocked Seaport, with builders for the order shapes OpenSea posts.
abstract contract VaultTest is Test {
    uint256 internal constant FLOOR = 1 ether;
    uint256 internal constant CEILING = 0.5 ether;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant EDITION_ID = 7;

    ListoorVault internal vault;
    MockSeaport internal seaport;
    MockERC721 internal nft;
    MockERC1155 internal edition;
    MockWETH internal weth;

    address internal conduit = makeAddr("conduit");
    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal stranger = makeAddr("stranger");
    address internal keeper;
    uint256 internal keeperPk;

    function setUp() public virtual {
        (keeper, keeperPk) = makeAddrAndKey("keeper");
        seaport = new MockSeaport();
        nft = new MockERC721();
        edition = new MockERC1155();
        weth = new MockWETH();
        vault = new ListoorVault(address(seaport), conduit, owner, keeper);

        vm.startPrank(owner);
        vault.setPaymentTokenAllowed(vault.NATIVE_TOKEN(), true);
        vault.setPaymentTokenAllowed(address(weth), true);
        vault.setListingFloor(address(nft), FLOOR);
        vault.setListingFloor(address(edition), FLOOR);
        vault.setOfferCeiling(address(nft), CEILING);
        vault.setOfferCeiling(address(edition), CEILING);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             ORDER BUILDERS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC721 listing paying `price` in native ETH to the vault.
    function listing(uint256 price) internal view returns (OrderComponents memory order) {
        order = emptyOrder();
        order.offer = new OfferItem[](1);
        order.offer[0] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1);
        order.consideration = new ConsiderationItem[](1);
        order.consideration[0] = payment(vault.NATIVE_TOKEN(), price, address(vault));
    }

    /// @dev ERC721 listing at `price` total, of which `feeBps` is routed to a fee recipient.
    function listingWithFee(uint256 price, uint256 feeBps)
        internal
        view
        returns (OrderComponents memory order)
    {
        uint256 fee = (price * feeBps) / BPS;
        order = listing(price - fee);
        order.consideration = withFee(order.consideration, vault.NATIVE_TOKEN(), fee);
    }

    /// @dev ERC1155 listing of `units` editions paying `proceeds` in native ETH to the vault.
    function editionListing(uint256 units, uint256 proceeds)
        internal
        view
        returns (OrderComponents memory order)
    {
        order = emptyOrder();
        order.offer = new OfferItem[](1);
        order.offer[0] = OfferItem(ItemType.ERC1155, address(edition), EDITION_ID, units, units);
        order.consideration = new ConsiderationItem[](1);
        order.consideration[0] = payment(vault.NATIVE_TOKEN(), proceeds, address(vault));
    }

    /// @dev WETH offer of `price` for one ERC721, delivered to the vault.
    function offer(uint256 price) internal view returns (OrderComponents memory order) {
        order = emptyOrder();
        order.offer = new OfferItem[](1);
        order.offer[0] = OfferItem(ItemType.ERC20, address(weth), 0, price, price);
        order.consideration = new ConsiderationItem[](1);
        order.consideration[0] = ConsiderationItem(
            ItemType.ERC721, address(nft), TOKEN_ID, 1, 1, payable(address(vault))
        );
    }

    /// @dev WETH offer of `price` total, of which `feeBps` is routed to a fee recipient.
    function offerWithFee(uint256 price, uint256 feeBps)
        internal
        view
        returns (OrderComponents memory order)
    {
        order = offer(price);
        order.consideration = withFee(order.consideration, address(weth), (price * feeBps) / BPS);
    }

    /// @dev WETH collection offer of `price` for `units` editions matching any id in `edition`.
    function criteriaOffer(uint256 price, uint256 units)
        internal
        view
        returns (OrderComponents memory order)
    {
        order = offer(price);
        order.consideration[0] = ConsiderationItem(
            ItemType.ERC1155_WITH_CRITERIA,
            address(edition),
            0,
            units,
            units,
            payable(address(vault))
        );
    }

    function emptyOrder() internal view returns (OrderComponents memory) {
        return OrderComponents({
            offerer: address(vault),
            zone: address(0),
            offer: new OfferItem[](0),
            consideration: new ConsiderationItem[](0),
            orderType: OrderType.PARTIAL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            zoneHash: bytes32(0),
            salt: 0xfeed,
            conduitKey: bytes32(0),
            counter: 0
        });
    }

    function payment(address token, uint256 amount, address recipient)
        internal
        pure
        returns (ConsiderationItem memory)
    {
        return ConsiderationItem(
            token == address(0) ? ItemType.NATIVE : ItemType.ERC20,
            token,
            0,
            amount,
            amount,
            payable(recipient)
        );
    }

    function withFee(ConsiderationItem[] memory consideration, address token, uint256 fee)
        internal
        view
        returns (ConsiderationItem[] memory extended)
    {
        extended = new ConsiderationItem[](consideration.length + 1);
        for (uint256 i; i < consideration.length; ++i) {
            extended[i] = consideration[i];
        }
        extended[consideration.length] = payment(token, fee, feeRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                          SIGNING & VALIDATION
    //////////////////////////////////////////////////////////////*/

    function digestOf(OrderComponents memory order) internal view returns (bytes32) {
        return SeaportOrderHash.digest(
            SeaportOrderHash.domainSeparator(address(seaport), keccak256("1.6")), order
        );
    }

    function validate(OrderComponents memory order) internal view returns (bytes4) {
        return vault.isValidSignature(digestOf(order), payloadFor(order, keeperPk));
    }

    function validateSignedBy(OrderComponents memory order, uint256 signerPk)
        internal
        view
        returns (bytes4)
    {
        return vault.isValidSignature(digestOf(order), payloadFor(order, signerPk));
    }

    /// @dev The signature blob a keeper hands to OpenSea: order components plus an ECDSA signature.
    function payloadFor(OrderComponents memory order, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(order, signatureFor(order, signerPk));
    }

    function signatureFor(OrderComponents memory order, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digestOf(order));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Digest and payload are prepared before arming the expectation so that it applies to the
    ///      validation call and nothing else.
    function expectRevertOn(bytes memory expectedError, OrderComponents memory order) internal {
        expectRevertOnSignedBy(expectedError, order, keeperPk);
    }

    function expectRevertOnSignedBy(
        bytes memory expectedError,
        OrderComponents memory order,
        uint256 signerPk
    ) internal {
        bytes32 digest = digestOf(order);
        bytes memory signature = payloadFor(order, signerPk);

        vm.expectRevert(expectedError);
        vault.isValidSignature(digest, signature);
    }
}
