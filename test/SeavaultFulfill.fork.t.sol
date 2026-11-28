// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {
    ConsiderationEventsAndErrors
} from "seaport-types/src/interfaces/ConsiderationEventsAndErrors.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    OfferItem,
    Order,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Seavault} from "../src/Seavault.sol";
import {SeavaultFactory} from "../src/SeavaultFactory.sol";
import {SeaportOrderHash} from "../src/libraries/SeaportOrderHash.sol";
import {BaseFork} from "./helpers/BaseFork.sol";
import {ListingPermitFixture} from "./helpers/ListingPermitFixture.sol";
import {PolicyFixture} from "./helpers/PolicyFixture.sol";
import {MockERC721} from "./mocks/TokenMocks.sol";

/// @notice End-to-end fills against the real Seaport and OpenSea conduit, with the vault created
///         through the factory: Seaport calls the vault's `isValidSignature`, the conduit moves the
///         assets, and policy failures block the fill while free-tier orders remain fillable.
contract SeavaultFulfillForkTest is BaseFork {
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant USDC_PRICE = 100e6;

    SeavaultFactory internal factory;
    Seavault internal vault;
    MockERC721 internal nft;
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal owner = makeAddr("owner");
    address internal taker = makeAddr("taker");
    address internal keeper;
    uint256 internal keeperPk;
    PolicyFixture.Rule internal policy;

    function setUp() public {
        forkBase();
        (keeper, keeperPk) = makeAddrAndKey("keeper");
        nft = new MockERC721();
        factory = new SeavaultFactory(address(SEAPORT), OPENSEA_CONDUIT, factoryOwner, WETH, USDC);
        // Short trial so the lapse test can warp past it without outliving its order. Irrelevant to
        // the rest of the suite: while the price is zero every vault counts as subscribed.
        vm.prank(factoryOwner);
        factory.setTrialPeriod(1 hours);
        vm.prank(owner);
        vault = factory.createVault(keccak256("fulfill"), keeper);
        assertTrue(vault.paymentTokenAllowed(WETH));
        assertEq(IERC20(WETH).allowance(address(vault), OPENSEA_CONDUIT), 0);
        policy = PolicyFixture.Rule(address(nft), PRICE, PRICE);

        vm.startPrank(owner);
        vault.setPolicyRoot(bytes32(0), PolicyFixture.leaf(policy));
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

    function test_takerFillsVaultListingWithPermit() public {
        uint256 ownerPk = _activatePermitListings();
        Order memory order = _signedWithPermit(_listing(PRICE), ownerPk);

        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0)));

        assertEq(nft.ownerOf(TOKEN_ID), taker);
        assertEq(address(vault).balance, PRICE);
    }

    function test_prevalidatedListingExpiresAtPermitDeadline() public {
        uint256 ownerPk = _activatePermitListings();
        OrderComponents memory components = _listing(PRICE);
        Order[] memory orders = new Order[](1);
        orders[0] = _signedWithPermit(components, ownerPk);
        assertTrue(SEAPORT.validate(orders));
        (bool isValidated,,,) = SEAPORT.getOrderStatus(SEAPORT.getOrderHash(components));
        assertTrue(isValidated);

        vm.warp(components.endTime);
        orders[0].signature = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                ConsiderationEventsAndErrors.InvalidTime.selector,
                components.startTime,
                components.endTime
            )
        );
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(orders[0], bytes32(0));
        assertEq(nft.ownerOf(TOKEN_ID), address(vault));
    }

    function test_takerFillsVaultUsdcListing() public {
        Seavault.CollectionWitness[] memory witnesses = _activateUsdcPolicy();
        nft.mint(address(vault), TOKEN_ID);
        OrderComponents memory components = _listing(USDC_PRICE);
        components.consideration[0].itemType = ItemType.ERC20;
        components.consideration[0].token = USDC;
        Order memory order = _signed(components, witnesses);
        deal(USDC, taker, USDC_PRICE);

        vm.startPrank(taker);
        IERC20(USDC).approve(address(SEAPORT), USDC_PRICE);
        assertTrue(SEAPORT.fulfillOrder(order, bytes32(0)));
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), taker);
        assertEq(IERC20(USDC).balanceOf(address(vault)), USDC_PRICE);
    }

    function test_keeperReturnsNativeSaleProceedsToSubscribedOwner() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.01 ether);
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));

        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0)));
        // The fixture owner forwards ETH on Base; verify the payment to it rather than its balance.
        vm.expectCall(owner, PRICE, bytes(""));
        vm.prank(keeper);
        vault.autoWithdrawETH(PRICE);

        assertEq(address(vault).balance, 0);
        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    function test_keeperReturnsRealWethSaleProceedsToSubscribedOwner() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.01 ether);
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
        nft.mint(address(vault), TOKEN_ID);
        OrderComponents memory components = _listing(PRICE);
        components.consideration[0].itemType = ItemType.ERC20;
        components.consideration[0].token = WETH;
        Order memory order = _signed(components);
        deal(WETH, taker, PRICE);
        uint256 ownerBalance = IERC20(WETH).balanceOf(owner);

        vm.startPrank(taker);
        IERC20(WETH).approve(address(SEAPORT), PRICE);
        assertTrue(SEAPORT.fulfillOrder(order, bytes32(0)));
        vm.stopPrank();
        vm.prank(keeper);
        vault.autoWithdrawERC20(WETH, PRICE);

        assertEq(IERC20(WETH).balanceOf(owner), ownerBalance + PRICE);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    function test_automaticWithdrawalsCanBeEnabledAndRunAfterExpiry() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.01 ether);
        vm.warp(factory.paidThrough(address(vault)) + 1);
        assertFalse(factory.isSubscribed(address(vault)));
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
        vm.deal(address(vault), PRICE);
        deal(WETH, address(vault), PRICE);
        uint256 ownerWethBalance = IERC20(WETH).balanceOf(owner);

        vm.expectCall(owner, PRICE, bytes(""));
        vm.startPrank(keeper);
        vault.autoWithdrawETH(PRICE);
        vault.autoWithdrawERC20(WETH, PRICE);
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(owner), ownerWethBalance + PRICE);
        assertEq(address(vault).balance, 0);
    }

    function test_flaggedVaultCanEnableAndRunAutomaticWithdrawals() public {
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
        vm.deal(address(vault), PRICE);
        deal(WETH, address(vault), PRICE);
        uint256 ownerWethBalance = IERC20(WETH).balanceOf(owner);

        vm.expectCall(owner, PRICE, bytes(""));
        vm.startPrank(keeper);
        vault.autoWithdrawETH(PRICE);
        vault.autoWithdrawERC20(WETH, PRICE);
        vm.stopPrank();

        assertEq(address(vault).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
        assertEq(IERC20(WETH).balanceOf(owner), ownerWethBalance + PRICE);
    }

    /// @dev A dump listing is unfillable even though the keeper key signed it, and the vault's revert
    ///      reason surfaces through Seaport.
    function test_seaportRejectsListingBelowFloor() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(1 wei));

        vm.expectRevert(abi.encodeWithSelector(Seavault.PriceBelowFloor.selector, PRICE, 1 wei));
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

    function test_flaggedVaultCanFillAnUnvalidatedListing() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);

        vm.prank(taker);
        assertTrue(SEAPORT.fulfillOrder{value: PRICE}(order, bytes32(0)));
        assertEq(nft.ownerOf(TOKEN_ID), taker);
    }

    function test_flaggedVaultCanFillAValidatedListing() public {
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

    /// @dev Seaport validates an order whatever its start time, so without the start bound a
    ///      far-future listing would carry today's floor for as long as the keeper likes.
    function test_seaportCannotValidateListingStartingTooFarAhead() public {
        nft.mint(address(vault), TOKEN_ID);
        uint256 latestStart = block.timestamp + vault.maxOrderDuration();
        OrderComponents memory components = _listing(PRICE);
        components.startTime = latestStart + 1;
        components.endTime = components.startTime + 1 hours;
        Order[] memory orders = new Order[](1);
        orders[0] = _signed(components);

        vm.expectRevert(
            abi.encodeWithSelector(
                Seavault.OrderStartsTooLate.selector, latestStart, components.startTime
            )
        );
        SEAPORT.validate(orders);
    }

    /// @dev A listing validated at the latest allowed start still has to be retired on a root change.
    function test_policyRootRevokesFutureValidatedListing() public {
        nft.mint(address(vault), TOKEN_ID);
        OrderComponents memory components = _listing(PRICE);
        components.startTime = block.timestamp + vault.maxOrderDuration();
        components.endTime = components.startTime + vault.maxOrderDuration();
        Order[] memory orders = new Order[](1);
        orders[0] = _signed(components);
        SEAPORT.validate(orders);
        bytes32 previous = vault.policyRoot();
        policy.floor = 10 * PRICE;
        vm.prank(owner);
        vault.setPolicyRoot(previous, PolicyFixture.leaf(policy));

        vm.warp(components.endTime - 1);
        vm.expectRevert(Seavault.DigestMismatch.selector);
        vm.prank(taker);
        SEAPORT.fulfillOrder{value: PRICE}(orders[0], bytes32(0));
        assertEq(nft.ownerOf(TOKEN_ID), address(vault));
    }

    function test_keeperCanCancelValidatedListingForFlaggedVault() public {
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

    function test_keeperUnwrapsRealWethBackIntoTheClone() public {
        vm.deal(address(vault), PRICE);
        vm.startPrank(keeper);
        vault.wrapETH(WETH, PRICE);
        assertEq(address(vault).balance, 0);
        vault.unwrapWETH(WETH, PRICE);
        vm.stopPrank();

        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, PRICE);
        assertEq(address(factory.vaultImplementation()).balance, 0);
    }

    function test_takerFillsVaultUsdcOffer() public {
        Seavault.CollectionWitness[] memory witnesses = _activateUsdcPolicy();
        vm.prank(owner);
        vault.setConduitAllowance(USDC, USDC_PRICE);
        deal(USDC, address(vault), USDC_PRICE);
        nft.mint(taker, TOKEN_ID);
        OrderComponents memory components = _offer(USDC_PRICE);
        components.offer[0].token = USDC;
        Order memory order = _signed(components, witnesses);

        vm.startPrank(taker);
        nft.setApprovalForAll(address(SEAPORT), true);
        assertTrue(SEAPORT.fulfillOrder(order, bytes32(0)));
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), address(vault));
        assertEq(IERC20(USDC).balanceOf(taker), USDC_PRICE);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
    }

    /// @dev Signature validation happens at fill time, so rotating the signer kills live orders.
    ///      Rotation also bumps the counter, so Seaport derives a digest the signed components no
    ///      longer hash to.
    function test_rotatingSignerKillsLiveListing() public {
        nft.mint(address(vault), TOKEN_ID);
        Order memory order = _signed(_listing(PRICE));

        vm.prank(owner);
        vault.setKeeper(makeAddr("newKeeper"));

        vm.expectRevert(Seavault.DigestMismatch.selector);
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

        vm.expectRevert(Seavault.DigestMismatch.selector);
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

    function test_keeperBuysListingForOwnerAfterSubscriptionExpires() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.01 ether);
        vm.warp(factory.paidThrough(address(vault)) + 1);
        assertFalse(factory.isSubscribed(address(vault)));
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        vm.deal(address(vault), PRICE);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, address(0), PRICE);

        vm.prank(keeper);
        assertTrue(vault.buy(order, bytes32(0), PolicyFixture.single(policy)));

        assertEq(nft.ownerOf(TOKEN_ID), owner);
        assertEq(seller.balance, PRICE);
        assertEq(address(vault).balance, 0);
    }

    function test_flaggedVaultCanBuyDirectly() public {
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        vm.deal(address(vault), PRICE);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, address(0), PRICE);
        vm.prank(factoryOwner);
        factory.setBlocked(address(vault), true);

        vm.prank(keeper);
        assertTrue(vault.buy(order, bytes32(0), PolicyFixture.single(policy)));
        assertEq(nft.ownerOf(TOKEN_ID), owner);
        assertEq(seller.balance, PRICE);
        assertEq(address(vault).balance, 0);
    }

    /// @dev WETH leaves through the vault's conduit allowance, the same cap its bids draw on.
    function test_keeperBuysWethListingThroughConduit() public {
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        deal(WETH, address(vault), PRICE);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, WETH, PRICE);

        vm.prank(keeper);
        assertTrue(vault.buy(order, OPENSEA_CONDUIT_KEY, PolicyFixture.single(policy)));

        assertEq(nft.ownerOf(TOKEN_ID), owner);
        assertEq(IERC20(WETH).balanceOf(seller), PRICE);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
    }

    function test_keeperBuysUsdcListingThroughConduit() public {
        Seavault.CollectionWitness[] memory witnesses = _activateUsdcPolicy();
        vm.prank(owner);
        vault.setConduitAllowance(USDC, USDC_PRICE);
        deal(USDC, address(vault), USDC_PRICE);
        (address seller, uint256 sellerPk) = makeAddrAndKey("seller");
        nft.mint(seller, TOKEN_ID);
        vm.prank(seller);
        nft.setApprovalForAll(address(SEAPORT), true);
        AdvancedOrder memory order = _sellersListing(seller, sellerPk, USDC, USDC_PRICE);

        vm.prank(keeper);
        assertTrue(vault.buy(order, OPENSEA_CONDUIT_KEY, witnesses));

        assertEq(nft.ownerOf(TOKEN_ID), owner);
        assertEq(IERC20(USDC).balanceOf(seller), USDC_PRICE);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        assertEq(vault.nativeBuyAllowance(), PRICE);
    }

    function _activateUsdcPolicy() private returns (Seavault.CollectionWitness[] memory) {
        PolicyFixture.Rule memory usdcRule =
            PolicyFixture.Rule(address(nft), USDC_PRICE, USDC_PRICE);
        bytes32 nativeLeaf = PolicyFixture.leaf(policy);
        bytes32 usdcLeaf = PolicyFixture.usdcLeaf(usdcRule);
        vm.prank(owner);
        vault.setPolicyRoot(nativeLeaf, Hashes.commutativeKeccak256(nativeLeaf, usdcLeaf));
        return PolicyFixture.withSibling(usdcRule, nativeLeaf);
    }

    /// @dev An ordinary EOA listing of `TOKEN_ID` at `price` in `token` (zero for native ETH).
    function _sellersListing(address seller, uint256 sellerPk, address token, uint256 price)
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
            price,
            price,
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

    function _activatePermitListings() private returns (uint256 ownerPk) {
        address permitOwner;
        (permitOwner, ownerPk) = makeAddrAndKey("seavault-fulfill-permit-owner");
        vm.prank(owner);
        vault.transferOwnership(permitOwner);
        bytes32 previous = vault.policyRoot();
        policy.floor = 0;
        vm.startPrank(permitOwner);
        vault.acceptOwnership();
        vault.setPolicyRoot(previous, PolicyFixture.leaf(policy));
        vm.stopPrank();
        nft.mint(address(vault), TOKEN_ID);
    }

    function _signedWithPermit(OrderComponents memory components, uint256 ownerPk)
        private
        view
        returns (Order memory order)
    {
        bytes32 digest = ListingPermitFixture.digest(
            address(vault),
            components.offer[0],
            address(0),
            PRICE,
            components.endTime,
            components.counter
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        Seavault.ListingPermit[] memory permits = new Seavault.ListingPermit[](1);
        permits[0] = Seavault.ListingPermit(PRICE, components.endTime, abi.encodePacked(r, s, v));

        order = _signed(components);
        (, bytes memory keeperSignature, Seavault.CollectionWitness[] memory witnesses) =
            abi.decode(order.signature, (OrderComponents, bytes, Seavault.CollectionWitness[]));
        order.signature = abi.encode(components, abi.encode(keeperSignature, permits), witnesses);
    }

    /// @dev Wraps components into the order Seaport takes, signed the way listoor will sign it.
    function _signed(OrderComponents memory components) private view returns (Order memory) {
        return _signed(components, PolicyFixture.single(policy));
    }

    function _signed(
        OrderComponents memory components,
        Seavault.CollectionWitness[] memory witnesses
    ) private view returns (Order memory) {
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
            signature: abi.encode(components, abi.encodePacked(r, s, v), witnesses)
        });
    }
}
