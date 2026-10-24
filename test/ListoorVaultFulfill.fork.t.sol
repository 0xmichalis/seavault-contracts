// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";
import {SeaportOrderHash} from "../src/libraries/SeaportOrderHash.sol";
import {BaseFork} from "./helpers/BaseFork.sol";
import {MockERC721} from "./mocks/TokenMocks.sol";

/// @notice End-to-end fills against the real Seaport and OpenSea conduit, with the vault created
///         through the factory: Seaport calls the vault's `isValidSignature`, the conduit moves the
///         assets, and policy failures block the fill while free-tier orders remain fillable.
contract ListoorVaultFulfillForkTest is BaseFork {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant PRICE = 1 ether;

    ListoorVaultFactory internal factory;
    ListoorVault internal vault;
    MockERC721 internal nft;
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal owner = makeAddr("owner");
    address internal taker = makeAddr("taker");
    address internal keeper;
    uint256 internal keeperPk;

    function setUp() public {
        forkBase();
        (keeper, keeperPk) = makeAddrAndKey("keeper");
        nft = new MockERC721();
        factory = new ListoorVaultFactory(address(SEAPORT), OPENSEA_CONDUIT, factoryOwner);
        // Short trial so the lapse test can warp past it without outliving its order. Irrelevant to
        // the rest of the suite: while the price is zero every vault counts as subscribed.
        vm.prank(factoryOwner);
        factory.setTrialPeriod(1 hours);
        vm.prank(owner);
        vault = factory.createVault(keccak256("fulfill"), keeper);

        vm.startPrank(owner);
        vault.setPaymentTokenAllowed(vault.NATIVE_TOKEN(), true);
        vault.setPaymentTokenAllowed(WETH, true);
        vault.setListingFloor(address(nft), PRICE);
        vault.setOfferCeiling(address(nft), PRICE);
        vault.setConduitApprovalForAll(address(nft), true);
        vault.setConduitAllowance(WETH, type(uint256).max);
        vault.setNativeBuyAllowance(PRICE);
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

    /// @dev Free-tier orders remain fillable after the paid window ends.
    function test_lapsedSubscriptionStillAllowsListingFill() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.01 ether);

        nft.mint(address(vault), TOKEN_ID);
        OrderComponents memory components = _listing(PRICE);
        components.endTime = block.timestamp + 2 hours; // outlives the trial
        Order memory order = _signed(components);
        vm.warp(factory.paidThrough(address(vault)) + 1);

        assertFalse(factory.isSubscribed(address(vault)));

        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0)));
        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    function test_blockingStopsUnvalidatedOrdersAndUnblockingRestoresThem() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);

        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0));
        assertEq(nft.ownerOf(TOKEN_ID), address(vault));

        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), false);
        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0)));
        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    /// @dev A block cannot reach orders Seaport has already validated; those need cancellation.
    function test_validatedListingStillFillsWhileBlocked() public {
        nft.mint(address(vault), TOKEN_ID);
        Order[] memory orders = new Order[](1);
        orders[0] = _signed(_listing(PRICE));
        SEAPORT.validate(orders);
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);

        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(orders[0], bytes32(0)));
        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    function test_blockedKeeperCanCancelValidatedListing() public {
        nft.mint(address(vault), TOKEN_ID);
        OrderComponents[] memory components = new OrderComponents[](1);
        components[0] = _listing(PRICE);
        Order[] memory orders = new Order[](1);
        orders[0] = _signed(components[0]);
        SEAPORT.validate(orders);
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);

        vm.prank(keeper);
        assertTrue(vault.cancelOrders(components));
        vm.expectRevert();
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(orders[0], bytes32(0));
        assertEq(nft.ownerOf(TOKEN_ID), address(vault));
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
    ///      Rotation also bumps the counter, so Seaport derives a digest the signed components no
    ///      longer hash to.
    function test_rotatingSignerKillsLiveListing() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));

        vm.prank(owner);
        vault.setKeeper(makeAddr("newKeeper"));

        vm.expectRevert(ListoorVault.DigestMismatch.selector);
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0));
    }

    /// @dev Seaport stops asking the vault about an order once it is validated, which anyone can do
    ///      with the posted signature, or once it is partially filled. Only the counter reaches it.
    function test_rotatingSignerKillsValidatedListing() public {
        nft.mint(address(vault), TOKEN_ID);
        Order[] memory orders = new Order[](1);
        orders[0] = _signed(_listing(PRICE));
        vm.prank(taker);
        SEAPORT.validate(orders);

        vm.prank(owner);
        vault.setKeeper(makeAddr("newKeeper"));

        vm.expectRevert(ListoorVault.DigestMismatch.selector);
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(orders[0], bytes32(0));
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

    function test_keeperBuysListingForOwner() public {
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        vm.deal(address(vault), PRICE);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, address(0));

        vm.prank(keeper);
        assertTrue(vault.buy(order, bytes32(0)));

        assertEq(nft.ownerOf(TOKEN_ID), owner);
        assertEq(seller.balance, PRICE);
        assertEq(address(vault).balance, 0);
    }

    function test_blockingStopsDirectBuysUntilUnblocked() public {
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        vm.deal(address(vault), PRICE);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, address(0));
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);

        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vm.prank(keeper);
        vault.buy(order, bytes32(0));
        assertEq(nft.ownerOf(TOKEN_ID), seller);
        assertEq(address(vault).balance, PRICE);

        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), false);
        vm.prank(keeper);
        assertTrue(vault.buy(order, bytes32(0)));
        assertEq(nft.ownerOf(TOKEN_ID), owner);
    }

    /// @dev WETH leaves through the vault's conduit allowance, the same cap its bids draw on.
    function test_keeperBuysWethListingThroughConduit() public {
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        deal(WETH, address(vault), PRICE);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, WETH);

        vm.prank(keeper);
        assertTrue(vault.buy(order, OPENSEA_CONDUIT_KEY));

        assertEq(nft.ownerOf(TOKEN_ID), owner);
        assertEq(IERC20(WETH).balanceOf(seller), PRICE);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
    }

    /// @dev An ordinary EOA listing of `TOKEN_ID` at `PRICE` in `token` (zero for native ETH).
    function _sellersListing(address seller, uint256 sellerPk, address token)
        private
        view
        returns (AdvancedOrder memory)
    {
        OrderComponents memory components = _emptyOrder();
        components.offerer = seller;
        components.conduitKey = bytes32(0);
        components.counter = SEAPORT.getCounter(seller);
        components.offer = new OfferItem[](1);
        components.offer[0] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1);
        components.consideration = new ConsiderationItem[](1);
        components.consideration[0] = ConsiderationItem(
            token == address(0) ? ItemType.NATIVE : ItemType.ERC20,
            token,
            0,
            PRICE,
            PRICE,
            payable(seller)
        );

        (, bytes32 domainSeparator,) = SEAPORT.information();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(sellerPk, SeaportOrderHash.digest(domainSeparator, components));

        return AdvancedOrder({
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
            numerator: 1,
            denominator: 1,
            signature: abi.encodePacked(r, s, v),
            extraData: ""
        });
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
