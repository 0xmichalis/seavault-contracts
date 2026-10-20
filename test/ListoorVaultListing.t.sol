// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    ConsiderationItem,
    OfferItem,
    OrderComponents
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice Policy enforced on orders where the vault sells an NFT.
contract ListoorVaultListingTest is VaultTest {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    function test_acceptsListingAtFloor() public view {
        assertEq(validate(listing(FLOOR)), MAGIC_VALUE);
    }

    function test_acceptsListingAboveFloor() public view {
        assertEq(validate(listing(FLOOR * 3)), MAGIC_VALUE);
    }

    function test_rejectsListingBelowFloor() public {
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR, FLOOR - 1),
            listing(FLOOR - 1)
        );
    }

    function test_rejectsDumpListing() public {
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR, 1), listing(1 wei)
        );
    }

    /// @dev Marketplace fees sit outside the floor, so the vault must still net the floor itself.
    function test_acceptsListingWithFeesWhenVaultNetsFloor() public view {
        assertEq(validate(listingWithFee(FLOOR * 2, 250)), MAGIC_VALUE);
    }

    function test_rejectsListingWhereFeesEatIntoFloor() public {
        uint256 fee = (FLOOR * 250) / BPS;

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR, FLOOR - fee),
            listingWithFee(FLOOR, 250)
        );
    }

    /// @dev Fees are capped so they cannot be turned into an exfiltration channel.
    function test_acceptsFeeShareAtCap() public view {
        assertEq(validate(listingWithFee(FLOOR * 10, vault.maxFeeBps())), MAGIC_VALUE);
    }

    function test_rejectsFeeShareAboveCap() public {
        uint256 feeBps = vault.maxFeeBps() + 1;
        uint256 price = FLOOR * 10;

        expectRevertOn(
            abi.encodeWithSelector(
                ListoorVault.FeeShareTooHigh.selector, (price * feeBps) / BPS, price
            ),
            listingWithFee(price, feeBps)
        );
    }

    function test_rejectsProceedsPaidToSomeoneElse() public {
        OrderComponents memory order = listing(FLOOR);
        order.consideration[0].recipient = payable(stranger);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR, 0), order
        );
    }

    /// @dev Components are only trustworthy once they hash to the digest Seaport is validating.
    function test_rejectsTamperedComponents() public {
        OrderComponents memory signedOrder = listing(FLOOR);
        OrderComponents memory tamperedOrder = listing(FLOOR);
        tamperedOrder.consideration[0].recipient = payable(stranger);
        bytes32 digest = digestOf(signedOrder);
        bytes memory tamperedPayload =
            abi.encode(tamperedOrder, signatureFor(signedOrder, keeperPk));

        vm.expectRevert(ListoorVault.DigestMismatch.selector);
        vault.isValidSignature(digest, tamperedPayload);
    }

    function test_rejectsSignatureFromNonKeeper() public {
        (, uint256 attackerPk) = makeAddrAndKey("attacker");

        expectRevertOnSignedBy(
            abi.encodeWithSelector(ListoorVault.UnauthorizedSigner.selector),
            listing(FLOOR),
            attackerPk
        );
    }

    /// @dev Rotating the signer is what revokes every outstanding order at once.
    function test_rotatingSignerInvalidatesOutstandingOrders() public {
        OrderComponents memory order = listing(FLOOR);
        assertEq(validate(order), MAGIC_VALUE);

        vm.prank(owner);
        vault.setKeeper(makeAddr("newKeeper"));

        expectRevertOn(abi.encodeWithSelector(ListoorVault.UnauthorizedSigner.selector), order);
    }

    function test_rejectsOrderOfferedBySomeoneElse() public {
        OrderComponents memory order = listing(FLOOR);
        order.offerer = stranger;

        expectRevertOn(abi.encodeWithSelector(ListoorVault.InvalidOfferer.selector), order);
    }

    function test_rejectsCollectionWithoutFloor() public {
        OrderComponents memory order = listing(FLOOR);
        order.offer[0].token = address(0xdead);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.CollectionNotListable.selector, address(0xdead)),
            order
        );
    }

    function test_perTokenFloorOverridesCollectionFloor() public {
        vm.prank(owner);
        vault.setTokenListingFloor(address(nft), TOKEN_ID, FLOOR * 10);

        assertEq(vault.listingFloorFor(address(nft), TOKEN_ID), FLOOR * 10);
        assertEq(vault.listingFloorFor(address(nft), TOKEN_ID + 1), FLOOR);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR * 10, FLOOR),
            listing(FLOOR)
        );
    }

    /// @dev A per-token floor makes one token listable in an otherwise unlistable collection.
    function test_perTokenFloorWithoutCollectionFloor() public {
        vm.startPrank(owner);
        vault.setListingFloor(address(nft), 0);
        vault.setTokenListingFloor(address(nft), TOKEN_ID, FLOOR);
        vm.stopPrank();

        assertEq(validate(listing(FLOOR)), MAGIC_VALUE);

        OrderComponents memory otherToken = listing(FLOOR);
        otherToken.offer[0].identifierOrCriteria = TOKEN_ID + 1;
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.CollectionNotListable.selector, address(nft)),
            otherToken
        );
    }

    /// @dev A collection the vault may bid on never sells below the ceiling, or a compromised keeper
    ///      could buy at the ceiling and sell back at the floor on repeat.
    function test_listingMustClearCeilingWhenAboveFloor() public {
        vm.prank(owner);
        vault.setOfferCeiling(address(nft), FLOOR * 2);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR * 2, FLOOR * 2 - 1),
            listing(FLOOR * 2 - 1)
        );
        assertEq(validate(listing(FLOOR * 2)), MAGIC_VALUE);
    }

    /// @dev Per-token floors are raised the same way, so none can undercut the ceiling.
    function test_ceilingRaisesEveryFloorBelowIt() public {
        vm.startPrank(owner);
        vault.setOfferCeiling(address(nft), FLOOR * 2);
        vault.setTokenListingFloor(address(nft), TOKEN_ID, FLOOR / 2);
        vm.stopPrank();

        assertEq(vault.listingFloorFor(address(nft), TOKEN_ID), FLOOR * 2);
        assertEq(vault.listingFloorFor(address(nft), TOKEN_ID + 1), FLOOR * 2);
    }

    /// @dev A ceiling alone does not make a collection listable.
    function test_ceilingDoesNotMakeACollectionListable() public {
        vm.prank(owner);
        vault.setListingFloor(address(nft), 0);

        assertEq(vault.listingFloorFor(address(nft), TOKEN_ID), 0);
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.CollectionNotListable.selector, address(nft)),
            listing(FLOOR)
        );
    }

    function test_rejectsNonPaymentConsideration() public {
        OrderComponents memory order = listing(FLOOR);
        order.consideration[0] =
            ConsiderationItem(ItemType.ERC721, address(nft), 1, 1, 1, payable(address(vault)));

        expectRevertOn(
            abi.encodeWithSelector(
                ListoorVault.UnsupportedConsiderationItem.selector, ItemType.ERC721
            ),
            order
        );
    }

    function test_rejectsDisallowedPaymentToken() public {
        OrderComponents memory order = listing(FLOOR);
        order.consideration[0] = payment(address(0xbeef), FLOOR, address(vault));

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PaymentTokenNotAllowed.selector, address(0xbeef)),
            order
        );
    }

    function test_rejectsNativeItemCarryingATokenAddress() public {
        OrderComponents memory order = listing(FLOOR);
        order.consideration[0].token = address(weth);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.MalformedNativeItem.selector, address(weth)), order
        );
    }

    function test_rejectsDurationLongerThanMax() public {
        uint256 maxDuration = vault.maxOrderDuration();
        OrderComponents memory order = listing(FLOOR);
        order.endTime = order.startTime + maxDuration + 1;

        expectRevertOn(
            abi.encodeWithSelector(
                ListoorVault.OrderDurationTooLong.selector, maxDuration, maxDuration + 1
            ),
            order
        );
    }

    function test_acceptsDurationAtMax() public view {
        OrderComponents memory order = listing(FLOOR);
        order.endTime = order.startTime + vault.maxOrderDuration();

        assertEq(validate(order), MAGIC_VALUE);
    }

    function test_rejectsEmptyTimeRange() public {
        OrderComponents memory order = listing(FLOOR);
        order.endTime = order.startTime;

        expectRevertOn(abi.encodeWithSelector(ListoorVault.InvalidTimeRange.selector), order);
    }

    /// @dev Editions fill pro rata, so the floor is enforced per unit offered.
    function test_editionFloorScalesWithUnits() public {
        assertEq(validate(editionListing(3, FLOOR * 3)), MAGIC_VALUE);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR * 3, FLOOR * 3 - 1),
            editionListing(3, FLOOR * 3 - 1)
        );
    }

    /// @dev A declining price has to clear the floor at its lowest point.
    function test_decliningPriceMustClearFloorAtEnd() public {
        OrderComponents memory order = listing(FLOOR);
        order.consideration[0].startAmount = FLOOR * 2;
        order.consideration[0].endAmount = FLOOR - 1;

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR, FLOOR - 1), order
        );
    }

    /// @dev A rising fee has to stay under the cap at its highest point.
    function test_risingFeeMustStayUnderCapAtEnd() public {
        uint256 price = FLOOR * 10;
        uint256 fee = (price * vault.maxFeeBps()) / BPS;
        OrderComponents memory order = listingWithFee(price, vault.maxFeeBps());
        order.consideration[1].endAmount = fee * 2;

        expectRevertOn(
            abi.encodeWithSelector(
                ListoorVault.FeeShareTooHigh.selector, fee * 2, price - fee + fee * 2
            ),
            order
        );
    }

    function test_bundleRequiresFloorOfEveryItem() public {
        OrderComponents memory order = listing(FLOOR * 2);
        order.offer = new OfferItem[](2);
        order.offer[0] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1);
        order.offer[1] = OfferItem(ItemType.ERC1155, address(edition), EDITION_ID, 2, 2);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR * 3, FLOOR * 2),
            order
        );

        assertEq(validate(_withProceeds(order, FLOOR * 3)), MAGIC_VALUE);
    }

    function test_rejectsMixedOfferItems() public {
        OrderComponents memory order = listing(FLOOR);
        order.offer = new OfferItem[](2);
        order.offer[0] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1);
        order.offer[1] = OfferItem(ItemType.ERC20, address(weth), 0, 1 ether, 1 ether);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.UnsupportedOfferItem.selector, ItemType.ERC20),
            order
        );
    }

    function test_rejectsCriteriaOfferItem() public {
        OrderComponents memory order = listing(FLOOR);
        order.offer[0].itemType = ItemType.ERC721_WITH_CRITERIA;

        expectRevertOn(
            abi.encodeWithSelector(
                ListoorVault.UnsupportedOfferItem.selector, ItemType.ERC721_WITH_CRITERIA
            ),
            order
        );
    }

    function test_rejectsEmptyOffer() public {
        OrderComponents memory order = listing(FLOOR);
        order.offer = new OfferItem[](0);

        expectRevertOn(abi.encodeWithSelector(ListoorVault.EmptyOffer.selector), order);
    }

    function testFuzz_rejectsAnythingBelowFloor(uint96 price) public {
        vm.assume(price < FLOOR);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceBelowFloor.selector, FLOOR, price),
            listing(price)
        );
    }

    function testFuzz_acceptsAtOrAboveFloor(uint96 price) public view {
        vm.assume(price >= FLOOR);

        assertEq(validate(listing(price)), MAGIC_VALUE);
    }

    function _withProceeds(OrderComponents memory order, uint256 proceeds)
        private
        pure
        returns (OrderComponents memory)
    {
        order.consideration[0].startAmount = proceeds;
        order.consideration[0].endAmount = proceeds;
        return order;
    }
}
