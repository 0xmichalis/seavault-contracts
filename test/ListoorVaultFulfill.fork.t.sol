// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    ConsiderationItem,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {SeaportOrderHash} from "../src/libraries/SeaportOrderHash.sol";
import {BaseFork} from "./helpers/BaseFork.sol";
import {MockERC721} from "./mocks/TokenMocks.sol";

/// @notice End-to-end fills against the real Seaport and OpenSea conduit: Seaport calls the vault's
///         `isValidSignature`, the conduit moves the assets, and policy failures block the fill.
contract ListoorVaultFulfillForkTest is BaseFork {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant PRICE = 1 ether;

    ListoorVault internal vault;
    MockERC721 internal nft;
    address internal owner = makeAddr("owner");
    address internal taker = makeAddr("taker");
    address internal keeper;
    uint256 internal keeperPk;

    function setUp() public {
        forkBase();
        (keeper, keeperPk) = makeAddrAndKey("keeper");
        nft = new MockERC721();
        vault = new ListoorVault(address(SEAPORT), OPENSEA_CONDUIT, owner, keeper);

        vm.startPrank(owner);
        vault.setPaymentTokenAllowed(vault.NATIVE_TOKEN(), true);
        vault.setPaymentTokenAllowed(WETH, true);
        vault.setListingFloor(address(nft), PRICE);
        vault.setOfferCeiling(address(nft), PRICE);
        vault.setConduitApprovalForAll(address(nft), true);
        vault.setConduitAllowance(WETH, type(uint256).max);
        vm.stopPrank();

        vm.deal(taker, 10 ether);
    }

    function test_takerFillsVaultListing() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));

        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0)));

        assertEq(nft.ownerOf(TOKEN_ID), taker);
        assertEq(address(vault).balance, PRICE);
    }

    /// @dev A dump listing is unfillable even though the keeper key signed it, and the vault's revert
    ///      reason surfaces through Seaport.
    function test_seaportRejectsListingBelowFloor() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(1 wei));

        vm.expectRevert(abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, PRICE, 1 wei));
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: 1 wei}(order, bytes32(0));
    }

    function test_takerFillsVaultOffer() public {
        deal(WETH, address(vault), PRICE);
        nft.mint(taker, TOKEN_ID);
        Order memory order = _signed(_offer(PRICE));

        vm.startPrank(taker);
        nft.setApprovalForAll(address(SEAPORT), true);
        assertTrue(SEAPORT.fulfillOrder(order, bytes32(0)));
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), address(vault));
        assertEq(IERC20(WETH).balanceOf(taker), PRICE);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
    }

    /// @dev Signature validation happens at fill time, so rotating the signer kills live orders.
    function test_rotatingSignerKillsLiveListing() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));

        vm.prank(owner);
        vault.setKeeper(makeAddr("newKeeper"));

        vm.expectRevert(ListoorVault.UnauthorizedSigner.selector);
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0));
    }

    /// @dev And so does an on-chain cancel, which the keeper key is allowed to send.
    function test_keeperCancelKillsLiveListing() public {
        nft.mint(address(vault), TOKEN_ID);
        OrderComponents memory components = _listing(PRICE);
        Order memory order = _signed(components);

        OrderComponents[] memory toCancel = new OrderComponents[](1);
        toCancel[0] = components;
        vm.prank(keeper);
        vault.cancelOrders(toCancel);

        vm.expectRevert();
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0));
    }

    function _listing(uint256 price) private view returns (OrderComponents memory order) {
        order = _emptyOrder();
        order.offer = new OfferItem[](1);
        order.offer[0] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1);
        order.consideration = new ConsiderationItem[](1);
        order.consideration[0] = ConsiderationItem(
            ItemType.NATIVE, address(0), 0, price, price, payable(address(vault))
        );
    }

    function _offer(uint256 price) private view returns (OrderComponents memory order) {
        order = _emptyOrder();
        order.offer = new OfferItem[](1);
        order.offer[0] = OfferItem(ItemType.ERC20, WETH, 0, price, price);
        order.consideration = new ConsiderationItem[](1);
        order.consideration[0] = ConsiderationItem(
            ItemType.ERC721, address(nft), TOKEN_ID, 1, 1, payable(address(vault))
        );
    }

    function _emptyOrder() private view returns (OrderComponents memory) {
        return OrderComponents({
            offerer: address(vault),
            zone: address(0),
            offer: new OfferItem[](0),
            consideration: new ConsiderationItem[](0),
            orderType: OrderType.FULL_OPEN,
            startTime: block.timestamp,
            endTime: block.timestamp + 1 hours,
            zoneHash: bytes32(0),
            salt: 0xfeed,
            conduitKey: OPENSEA_CONDUIT_KEY,
            counter: SEAPORT.getCounter(address(vault))
        });
    }

    /// @dev Wraps components into the order Seaport takes, signed the way listoor will sign it.
    function _signed(OrderComponents memory components) private view returns (Order memory) {
        (, bytes32 domainSeparator,) = SEAPORT.information();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keeperPk, SeaportOrderHash.digest(domainSeparator, components));

        return Order({
            parameters: OrderParameters({
                offerer: components.offerer,
                zone: components.zone,
                offer: components.offer,
                consideration: components.consideration,
                orderType: components.orderType,
                startTime: components.startTime,
                endTime: components.endTime,
                zoneHash: components.zoneHash,
                salt: components.salt,
                conduitKey: components.conduitKey,
                totalOriginalConsiderationItems: components.consideration.length
            }),
            signature: abi.encode(components, abi.encodePacked(r, s, v))
        });
    }
}
