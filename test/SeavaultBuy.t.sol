// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    OfferItem,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Seavault} from "../src/Seavault.sol";
import {PolicyFixture} from "./helpers/PolicyFixture.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice Policy enforced when the vault buys someone else's listing for its owner.
contract SeavaultBuyTest is VaultTest {
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
        assertTrue(vault.buy(order, CONDUIT_KEY, witnessesForBuy(order)));

        assertEq(seaport.fulfilledRecipient(), owner);
        assertEq(seaport.fulfilledValue(), CEILING);
        assertEq(seaport.fulfilledConduitKey(), CONDUIT_KEY);
    }

    /// @dev ERC20 payments come out through the conduit, so no native value goes along.
    function test_paysErc20ListingWithoutNativeValue() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration[0] = payment(address(weth), CEILING, seller);

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));

        assertEq(seaport.fulfilledValue(), 0);
        assertEq(seaport.fulfilledRecipient(), owner);
        assertEq(vault.nativeBuyAllowance(), 10 ether);
    }

    /// @dev The allowance caps what buys spend in ETH, as the conduit allowance does for WETH.
    function test_nativeBuysDrawDownAllowance() public {
        AdvancedOrder memory order = sellersListing(CEILING);

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));

        assertEq(vault.nativeBuyAllowance(), 10 ether - CEILING);
    }

    function test_rejectsNativeBuyAboveAllowance() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        vm.prank(owner);
        vault.setNativeBuyAllowance(CEILING - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Seavault.NativeBuyAllowanceExceeded.selector, CEILING - 1, CEILING
            )
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    function test_spendsTheAllowanceToTheLastWei() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        vm.prank(owner);
        vault.setNativeBuyAllowance(CEILING);

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));

        assertEq(vault.nativeBuyAllowance(), 0);
    }

    /// @dev A partial fill pays its share of the price; the ceiling binds per unit either way.
    function test_paysNativeShareOfPartialFill() public {
        AdvancedOrder memory order = sellersEditions(4, 4 * CEILING);
        order.numerator = 1;
        order.denominator = 4;

        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));

        assertEq(seaport.fulfilledValue(), CEILING);
    }

    /// @dev Fees are part of what the vault pays, so they count against the ceiling.
    function test_rejectsListingWhoseFeesExceedCeiling() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration =
            withFee(order.parameters.consideration, vault.NATIVE_TOKEN(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PriceAboveCeiling.selector, CEILING, CEILING + 1)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    /// @dev A price that moves counts at its highest, since the fill may land at either end.
    function test_countsVariablePriceAtItsHigh() public {
        AdvancedOrder memory order = sellersListing(CEILING / 2);
        order.parameters.consideration[0].endAmount = CEILING + 1;

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PriceAboveCeiling.selector, CEILING, CEILING + 1)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    /// @dev A quantity that moves counts at its lowest, which is all the vault is sure to get.
    function test_countsVariableQuantityAtItsLow() public {
        AdvancedOrder memory order = sellersEditions(2, 2 * CEILING);
        order.parameters.offer[0].endAmount = 1;

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PriceAboveCeiling.selector, CEILING, 2 * CEILING)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    function test_rejectsCollectionWithoutCeiling() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        setNftPolicy(FLOOR, 0);

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.CollectionNotBiddable.selector, address(nft))
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    function test_rejectsTamperedCeilingBeforeSpending() public {
        AdvancedOrder memory order = sellersListing(CEILING + 1);
        Seavault.CollectionWitness[] memory witnesses = witnessesForBuy(order);
        witnesses[0].ceiling = CEILING + 1;

        vm.expectRevert(Seavault.InvalidCollectionWitness.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnesses);
        assertEq(vault.nativeBuyAllowance(), 10 ether);
    }

    function test_rejectsOldProofAfterRootChangeOrClear() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        Seavault.CollectionWitness[] memory witnesses = witnessesForBuy(order);
        setNftPolicy(FLOOR, CEILING / 2);
        vm.expectRevert(Seavault.InvalidCollectionWitness.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnesses);

        bytes32 active = vault.policyRoot();
        vm.prank(owner);
        vault.setPolicyRoot(active, bytes32(0));
        vm.expectRevert(Seavault.InvalidCollectionWitness.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnesses);
    }

    function test_rejectsPaymentTokenNotAllowed() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration[0] = payment(address(0xbeef), CEILING, seller);

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PaymentTokenNotAllowed.selector, address(0xbeef))
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    function test_rejectsUsdcTipOnNativeBuy() public {
        AdvancedOrder memory order = sellersListing(CEILING - 1);
        order.parameters.consideration = withFee(order.parameters.consideration, usdc, 1);

        vm.expectRevert(abi.encodeWithSelector(Seavault.PaymentTokenNotAllowed.selector, usdc));
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    /// @dev Buying never hands over the vault's own NFTs.
    function test_rejectsListingThatAsksForAnNft() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.consideration[0] =
            ConsiderationItem(ItemType.ERC721, address(nft), TOKEN_ID + 1, 1, 1, payable(seller));

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.UnsupportedConsiderationItem.selector, ItemType.ERC721)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    /// @dev Buying the vault's own listing would only move its NFT to the owner at the cost of fees.
    function test_rejectsVaultsOwnListing() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.offerer = address(vault);

        vm.expectRevert(Seavault.InvalidOfferer.selector);
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    /// @dev A listing names the tokens it sells, so criteria never apply.
    function test_rejectsCriteriaOffer() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        order.parameters.offer[0].itemType = ItemType.ERC721_WITH_CRITERIA;

        vm.expectRevert(
            abi.encodeWithSelector(
                Seavault.UnsupportedOfferItem.selector, ItemType.ERC721_WITH_CRITERIA
            )
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    function test_policyStillBoundsBuyWhileLapsed() public {
        AdvancedOrder memory order = sellersListing(CEILING + 1);
        subscriptions.set(false);

        vm.expectRevert(
            abi.encodeWithSelector(Seavault.PriceAboveCeiling.selector, CEILING, CEILING + 1)
        );
        vm.prank(keeper);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
    }

    function test_flaggedVaultSupportsOwnerAndKeeperBuys() public {
        AdvancedOrder memory order = sellersListing(CEILING);
        subscriptions.setBlocked(true);

        vm.prank(keeper);
        assertTrue(vault.buy(order, CONDUIT_KEY, witnessesForBuy(order)));
        vm.prank(owner);
        assertTrue(vault.buy(order, CONDUIT_KEY, witnessesForBuy(order)));

        assertEq(vault.nativeBuyAllowance(), 10 ether - 2 * CEILING);
        assertEq(address(vault).balance, 10 ether - 2 * CEILING);
    }

    function test_strangerCannotBuy() public {
        AdvancedOrder memory order = sellersListing(CEILING);

        vm.expectRevert(abi.encodeWithSelector(Seavault.NotOwnerOrKeeper.selector, stranger));
        vm.prank(stranger);
        vault.buy(order, CONDUIT_KEY, witnessesForBuy(order));
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

    function witnessesForBuy(AdvancedOrder memory order)
        private
        view
        returns (Seavault.CollectionWitness[] memory)
    {
        return PolicyFixture.forOfferItems(nftPolicy, editionPolicy, order.parameters.offer);
    }
}
