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

/// @notice Policy enforced on orders where the vault bids for an NFT.
contract ListoorVaultOfferTest is VaultTest {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    function test_acceptsOfferAtCeiling() public view {
        assertEq(validate(offer(CEILING)), MAGIC_VALUE);
    }

    function test_acceptsOfferBelowCeiling() public view {
        assertEq(validate(offer(CEILING / 2)), MAGIC_VALUE);
    }

    function test_rejectsOfferAboveCeiling() public {
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, CEILING + 1),
            offer(CEILING + 1)
        );
    }

    function test_rejectsInflatedOffer() public {
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, 1000 ether),
            offer(1000 ether)
        );
    }

    function test_rejectsCollectionWithoutCeiling() public {
        OrderComponents memory order = offer(CEILING);
        order.consideration[0].token = address(0xdead);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.CollectionNotBiddable.selector, address(0xdead)),
            order
        );
    }

    function test_rejectsNftDeliveredElsewhere() public {
        OrderComponents memory order = offer(CEILING);
        order.consideration[0].recipient = payable(stranger);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.ItemNotReceivedByVault.selector, stranger), order
        );
    }

    /// @dev Fees are paid out of the offered amount, so the ceiling already covers them.
    function test_acceptsOfferWithFees() public view {
        assertEq(validate(offerWithFee(CEILING, 250)), MAGIC_VALUE);
    }

    function test_rejectsOfferWithFeeInDisallowedToken() public {
        OrderComponents memory order = offer(CEILING);
        order.consideration = withFee(order.consideration, address(0xbeef), 1 ether);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PaymentTokenNotAllowed.selector, address(0xbeef)),
            order
        );
    }

    function test_rejectsOfferInDisallowedToken() public {
        OrderComponents memory order = offer(CEILING);
        order.offer[0].token = address(0xbeef);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PaymentTokenNotAllowed.selector, address(0xbeef)),
            order
        );
    }

    function test_rejectsOfferThatReceivesNothing() public {
        OrderComponents memory order = offer(CEILING);
        order.consideration[0] = payment(address(weth), 0, address(vault));

        expectRevertOn(abi.encodeWithSelector(ListoorVault.NoNftConsideration.selector), order);
    }

    /// @dev Collection and trait offers carry criteria items; the collection is what is bounded.
    function test_acceptsCriteriaOfferAtCeiling() public view {
        assertEq(validate(criteriaOffer(CEILING, 1)), MAGIC_VALUE);
    }

    function test_criteriaOfferCeilingScalesWithUnits() public {
        assertEq(validate(criteriaOffer(CEILING * 3, 3)), MAGIC_VALUE);

        expectRevertOn(
            abi.encodeWithSelector(
                ListoorVault.PriceAboveCeiling.selector, CEILING * 3, CEILING * 3 + 1
            ),
            criteriaOffer(CEILING * 3 + 1, 3)
        );
    }

    function test_acceptsErc721CriteriaOffer() public view {
        OrderComponents memory order = offer(CEILING);
        order.consideration[0].itemType = ItemType.ERC721_WITH_CRITERIA;
        order.consideration[0].identifierOrCriteria = uint256(keccak256("merkle root"));

        assertEq(validate(order), MAGIC_VALUE);
    }

    /// @dev A rising amount has to stay under the ceiling at its highest point.
    function test_risingOfferMustStayUnderCeilingAtEnd() public {
        OrderComponents memory order = offer(CEILING);
        order.offer[0].endAmount = CEILING * 2;

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, CEILING * 2),
            order
        );
    }

    function test_sumsAllOfferedTokensAgainstCeiling() public {
        OrderComponents memory order = offer(CEILING);
        order.offer = new OfferItem[](2);
        order.offer[0] = OfferItem(ItemType.ERC20, address(weth), 0, CEILING, CEILING);
        order.offer[1] = OfferItem(ItemType.ERC20, address(weth), 0, 1, 1);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, CEILING + 1),
            order
        );
    }

    function test_rejectsMixedOfferItems() public {
        OrderComponents memory order = offer(CEILING);
        order.offer = new OfferItem[](2);
        order.offer[0] = OfferItem(ItemType.ERC20, address(weth), 0, CEILING, CEILING);
        order.offer[1] = OfferItem(ItemType.ERC721, address(nft), TOKEN_ID, 1, 1);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.UnsupportedOfferItem.selector, ItemType.ERC721),
            order
        );
    }

    /// @dev Bundle bids sum the ceilings of everything the vault receives.
    function test_bundleBidSumsCeilings() public view {
        OrderComponents memory order = offer(CEILING * 2);
        order.consideration = new ConsiderationItem[](2);
        order.consideration[0] = ConsiderationItem(
            ItemType.ERC721, address(nft), TOKEN_ID, 1, 1, payable(address(vault))
        );
        order.consideration[1] = ConsiderationItem(
            ItemType.ERC1155, address(edition), EDITION_ID, 1, 1, payable(address(vault))
        );

        assertEq(validate(order), MAGIC_VALUE);
    }

    function testFuzz_rejectsAnythingAboveCeiling(uint96 price) public {
        vm.assume(price > CEILING);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.PriceAboveCeiling.selector, CEILING, price),
            offer(price)
        );
    }

    function testFuzz_acceptsAtOrBelowCeiling(uint96 price) public view {
        vm.assume(price <= CEILING);

        assertEq(validate(offer(price)), MAGIC_VALUE);
    }
}
