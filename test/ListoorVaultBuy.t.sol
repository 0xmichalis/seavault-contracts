// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    OfferItem,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice Policy enforced when the vault buys someone else's listing for its owner.
contract ListoorVaultBuyTest is VaultTest {
    bytes32 internal constant CONDUIT_KEY = keccak256("conduit key");

    address internal seller = makeAddr("seller");

    function setUp() public override {
        super.setUp();
        vm.deal(address(vault), 10 ether);
        vm.prank(owner);
        vault.setNativeBuyAllowance(10 ether);
    }

    function test_keeperBuysListingForOwner() public {
        AdvancedOrder memory order = sellersListing(CEILING);

        vm.prank(keeper);
        assertTrue(vault.buy(order, CONDUIT_KEY));

        assertEq(seaport.fulfilledRecipient(), owner);
        assertEq(seaport.fulfilledValue(), CEILING);
        assertEq(seaport.fulfilledConduitKey(), CONDUIT_KEY);
    }

    /// @dev ERC20 payments come out through the conduit, so no native value goes along.
    function test_paysErc20ListingWithoutNativeValue() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration[0] = payment(address(weth), CEILING, seller);

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);

        assertEq(seaport.fulfilledValue(), 0);
        assertEq(seaport.fulfilledRecipient(), owner);
        assertEq(vault.nativeBuyAllowance(), 10 ether);
    }

    /// @dev The allowance caps what buys spend in ETH, as the conduit allowance does for WETH.
    function test_nativeBuysDrawDownAllowance() public {
        AdvancedOrder memory order = sellersListing(CEILING);

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);

        assertEq(vault.nativeBuyAllowance(), 10 ether - CEILING);
    }

    function test_rejectsNativeBuyAboveAllowance() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        vm.prank(owner);
        vault.setNativeBuyAllowance(CEILING - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ListoorVault.NativeBuyAllowanceExceeded.selector, CEILING - 1, CEILING
            )
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    function test_spendsTheAllowanceToTheLastWei() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        vm.prank(owner);
        vault.setNativeBuyAllowance(CEILING);

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);

        assertEq(vault.nativeBuyAllowance(), 0);
    }

    /// @dev A partial fill pays its share of the price; the ceiling binds per unit either way.
    function test_paysNativeShareOfPartialFill() public {
        AdvancedOrder memory order = sellersEditions(4, 4 * CEILING);
        order.numerator = 1;
        order.denominator = 4;

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);

        assertEq(seaport.fulfilledValue(), CEILING);
    }

    /// @dev Fees are part of what the vault pays, so they count against the ceiling.
    function test_rejectsListingWhoseFeesExceedCeiling() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration =
            withFee(order.parameters.consideration, vault.NATIVE_TOKEN(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, CEILING + 1)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    /// @dev A price that moves counts at its highest, since the fill may land at either end.
    function test_countsVariablePriceAtItsHigh() public {
        AdvancedOrder memory order = sellersListing(CEILING / 2);
        order.parameters.consideration[0].endAmount = CEILING + 1;

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, CEILING + 1)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    /// @dev A quantity that moves counts at its lowest, which is all the vault is sure to get.
    function test_countsVariableQuantityAtItsLow() public {
        AdvancedOrder memory order = sellersEditions(2, 2 * CEILING);
        order.parameters.offer[0].endAmount = 1;

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, 2 * CEILING)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    function test_rejectsCollectionWithoutCeiling() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        vm.prank(owner);
        vault.setOfferCeiling(address(nft), 0);

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVault.CollectionNotBiddable.selector, address(nft))
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    function test_rejectsPaymentTokenNotAllowed() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        vm.prank(owner);
        vault.setPaymentTokenAllowed(address(0), false);

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVault.PaymentTokenNotAllowed.selector, address(0))
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    /// @dev Buying never hands over the vault's own NFTs.
    function test_rejectsListingThatAsksForAnNft() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration[0] =
            ConsiderationItem(ItemType.ERC721, address(nft), TOKEN_ID + 1, 1, 1, payable(seller));

        vm.expectRevert(
            abi.encodeWithSelector(
                ListoorVault.UnsupportedConsiderationItem.selector, ItemType.ERC721
            )
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    /// @dev Buying the vault's own listing would only move its NFT to the owner at the cost of fees.
    function test_rejectsVaultsOwnListing() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.offerer = address(vault);

        vm.expectRevert(ListoorVault.InvalidOfferer.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    /// @dev A listing names the tokens it sells, so criteria never apply.
    function test_rejectsCriteriaOffer() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.offer[0].itemType = ItemType.ERC721_WITH_CRITERIA;

        vm.expectRevert(
            abi.encodeWithSelector(
                ListoorVault.UnsupportedOfferItem.selector, ItemType.ERC721_WITH_CRITERIA
            )
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    function test_rejectsBuyWhileLapsed() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        subscriptions.set(false, 0.01 ether);

        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    function test_blockingStopsBothOwnerAndKeeperBuys() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        subscriptions.setBlocked(true);

        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vm.prank(owner);
        vault.buy(order, CONDUIT_KEY);
        assertEq(vault.nativeBuyAllowance(), 10 ether);
        assertEq(address(vault).balance, 10 ether);
    }

    function test_unblockingDoesNotBypassTheSubscriptionGate() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        subscriptions.set(false, 0.01 ether);
        subscriptions.setBlocked(true);
        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);

        subscriptions.setBlocked(false);
        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY);
    }

    function test_strangerCannotBuy() public {
        AdvancedOrder memory order = sellersListing(CEILING);

        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, stranger));
        vm.prank(stranger);
        vault.buy(order, CONDUIT_KEY);
    }

    /// @dev Seller's ERC721 listing at `price` in native ETH.
    function sellersListing(uint256 price) private view returns (AdvancedOrder memory) {
        return sellersOrder(
            OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1),
            payment(vault.NATIVE_TOKEN(), price, seller)
        );
    }

    /// @dev Seller's listing of `units` editions for `price` in native ETH.
    function sellersEditions(uint256 units, uint256 price)
        private
        view
        returns (AdvancedOrder memory)
    {
        return sellersOrder(
            OfferItem(ItemType.ERC1155, address(edition), EDITION_ID, units, units),
            payment(vault.NATIVE_TOKEN(), price, seller)
        );
    }

    function sellersOrder(OfferItem memory item, ConsiderationItem memory price)
        private
        view
        returns (AdvancedOrder memory)
    {
        OfferItem[] memory offerItems = new OfferItem[](1);
        offerItems[0] = item;
        ConsiderationItem[] memory considerationItems = new ConsiderationItem[](1);
        considerationItems[0] = price;

        return AdvancedOrder({
            parameters: OrderParameters({
                offerer: seller,
                zone: address(0),
                offer: offerItems,
                consideration: considerationItems,
                orderType: OrderType.PARTIAL_OPEN,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 hours,
                zoneHash: bytes32(0),
                salt: 0,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: 1
            }),
            numerator: 1,
            denominator: 1,
            signature: "",
            extraData: ""
        });
    }
}
