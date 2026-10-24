// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";

/// @notice The factory's subscription registry: pricing, overrides, extension arithmetic, and the
///         promise that paid time can only grow. Needs no fork — nothing here deploys a vault.
contract ListoorVaultFactorySubscriptionsTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant PRICE = 0.05 ether;

    ListoorVaultFactory internal factory;
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal recipient = makeAddr("recipient");
    address internal payer = makeAddr("payer");
    address internal vault = makeAddr("vault");
    uint256 internal period;

    function setUp() public {
        factory = new ListoorVaultFactory(makeAddr("seaport"), makeAddr("conduit"), factoryOwner);
        period = factory.SUBSCRIPTION_PERIOD();
        // `createVault` needs CreateX, which only exists on a fork, so registration is written
        // directly here. Slot is located by probing rather than hardcoded.
        stdstore.target(address(factory))
            .sig(factory.isVault.selector)
            .with_key(vault)
            .checked_write(true);
        vm.deal(payer, 100 ether);
    }

    function test_shipsFreeSoDeploymentIsUsable() public view {
        assertEq(factory.subscriptionPrice(), 0);
        assertEq(factory.subscriptionRecipient(), factoryOwner);
        assertEq(factory.trialPeriod(), 30 days);
        assertTrue(factory.isSubscribed(vault));
    }

    /// @dev A zero price means free, whatever the clock says.
    function test_freeVaultsAreAlwaysSubscribed() public {
        vm.warp(block.timestamp + 3650 days);

        assertTrue(factory.isSubscribed(vault));
        assertTrue(factory.isSubscribed(makeAddr("neverRegistered")));
    }

    function test_zeroPriceRestoresFullAccessWithoutExtendingPaidTime() public {
        _priced();
        assertFalse(factory.isSubscribed(vault));
        uint256 expiry = factory.paidThrough(vault);

        vm.prank(factoryOwner);
        factory.setSubscription(recipient, 0);

        assertTrue(factory.isSubscribed(vault));
        assertEq(factory.paidThrough(vault), expiry);
    }

    function test_setSubscription() public {
        vm.expectEmit(true, true, true, true);
        emit ListoorVaultFactory.SubscriptionUpdated(recipient, PRICE);
        vm.prank(factoryOwner);
        factory.setSubscription(recipient, PRICE);

        assertEq(factory.subscriptionRecipient(), recipient);
        assertEq(factory.priceFor(vault), PRICE);
        // Unpaid once a price exists.
        assertFalse(factory.isSubscribed(vault));
    }

    function test_rejectsZeroRecipient() public {
        vm.expectRevert(ListoorVaultFactory.ZeroAddress.selector);
        vm.prank(factoryOwner);
        factory.setSubscription(address(0), PRICE);
    }

    function test_configIsOwnerOnly() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payer);

        vm.startPrank(payer);
        vm.expectRevert(unauthorized);
        factory.setSubscription(recipient, PRICE);
        vm.expectRevert(unauthorized);
        factory.setPriceOverride(vault, true, 0);
        vm.expectRevert(unauthorized);
        factory.setTrialPeriod(1 days);
        vm.stopPrank();
    }

    /// @dev Renouncing would freeze the price and the recipient; a recipient that stops accepting
    ///      payments would then lapse every vault for good.
    function test_ownershipCannotBeRenounced() public {
        vm.expectRevert(ListoorVaultFactory.OwnershipCannotBeRenounced.selector);
        vm.prank(factoryOwner);
        factory.renounceOwnership();

        assertEq(factory.owner(), factoryOwner);
    }

    /*//////////////////////////////////////////////////////////////
                                 PAYING
    //////////////////////////////////////////////////////////////*/

    function test_extendFromNowWhenLapsed() public {
        _priced();
        vm.warp(block.timestamp + 10 days);

        vm.expectEmit(true, true, true, true);
        emit ListoorVaultFactory.SubscriptionExtended(vault, payer, 2, block.timestamp + 2 * period);
        vm.prank(payer);
        factory.extendSubscription{value: 2 * PRICE}(vault, 2);

        assertEq(factory.paidThrough(vault), block.timestamp + 2 * period);
        assertTrue(factory.isSubscribed(vault));
        assertEq(recipient.balance, 2 * PRICE);
    }

    /// @dev Paying early stacks onto the existing expiry instead of throwing time away.
    function test_extendFromExpiryWhenStillActive() public {
        _priced();
        vm.prank(payer);
        factory.extendSubscription{value: PRICE}(vault, 1);
        uint256 firstExpiry = factory.paidThrough(vault);

        vm.prank(payer);
        factory.extendSubscription{value: PRICE}(vault, 1);

        assertEq(factory.paidThrough(vault), firstExpiry + period);
    }

    function test_anyoneCanPayForAVault() public {
        _priced();
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);

        vm.prank(stranger);
        factory.extendSubscription{value: PRICE}(vault, 1);

        assertTrue(factory.isSubscribed(vault));
    }

    function test_rejectsWrongPayment() public {
        _priced();

        vm.startPrank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(ListoorVaultFactory.IncorrectPayment.selector, PRICE, PRICE - 1)
        );
        factory.extendSubscription{value: PRICE - 1}(vault, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ListoorVaultFactory.IncorrectPayment.selector, 2 * PRICE, 2 * PRICE + 1
            )
        );
        factory.extendSubscription{value: 2 * PRICE + 1}(vault, 2);

        vm.expectRevert(ListoorVaultFactory.NoPeriods.selector);
        factory.extendSubscription{value: 0}(vault, 0);
        vm.stopPrank();
    }

    function test_rejectsPaymentForNonVaults() public {
        _priced();

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVaultFactory.NotAVault.selector, makeAddr("random"))
        );
        vm.prank(payer);
        factory.extendSubscription{value: PRICE}(makeAddr("random"), 1);
    }

    /// @dev No taking money for something that is already free.
    function test_rejectsPaymentWhenFree() public {
        vm.expectRevert(
            abi.encodeWithSelector(ListoorVaultFactory.SubscriptionNotRequired.selector, vault)
        );
        vm.prank(payer);
        factory.extendSubscription{value: 0}(vault, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          PAID TIME ONLY GROWS
    //////////////////////////////////////////////////////////////*/

    /// @dev The trust anchor: nothing the owner can do shortens time already bought.
    function test_ownerCannotShortenPaidTime() public {
        _priced();
        vm.prank(payer);
        factory.extendSubscription{value: 10 * PRICE}(vault, 10);
        uint256 expiry = factory.paidThrough(vault);

        vm.startPrank(factoryOwner);
        factory.setSubscription(recipient, 100 ether);
        factory.setTrialPeriod(0);
        factory.setPriceOverride(vault, true, 500 ether);
        vm.stopPrank();

        assertEq(factory.paidThrough(vault), expiry);
        assertTrue(factory.isSubscribed(vault));
    }

    /// @dev A price rise applies to the next purchase, not the current window.
    function test_priceRiseDoesNotDisturbTheCurrentWindow() public {
        _priced();
        vm.prank(payer);
        factory.extendSubscription{value: PRICE}(vault, 1);

        vm.prank(factoryOwner);
        factory.setSubscription(recipient, 10 * PRICE);

        assertTrue(factory.isSubscribed(vault));
        vm.prank(payer);
        factory.extendSubscription{value: 10 * PRICE}(vault, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function test_priceOverrideMakesOneVaultFree() public {
        _priced();

        vm.expectEmit(true, true, true, true);
        emit ListoorVaultFactory.PriceOverrideUpdated(vault, true, 0);
        vm.prank(factoryOwner);
        factory.setPriceOverride(vault, true, 0);

        assertEq(factory.priceFor(vault), 0);
        assertTrue(factory.isSubscribed(vault));
        assertEq(factory.priceFor(makeAddr("otherVault")), PRICE);
    }

    function test_priceOverrideCanDiscountInstead() public {
        _priced();

        vm.prank(factoryOwner);
        factory.setPriceOverride(vault, true, PRICE / 2);
        assertEq(factory.priceFor(vault), PRICE / 2);

        vm.prank(payer);
        factory.extendSubscription{value: PRICE / 2}(vault, 1);
        assertTrue(factory.isSubscribed(vault));
    }

    function test_disablingOverrideRestoresTheDefault() public {
        _priced();
        vm.startPrank(factoryOwner);
        factory.setPriceOverride(vault, true, 0);
        factory.setPriceOverride(vault, false, 0);
        vm.stopPrank();

        assertEq(factory.priceFor(vault), PRICE);
    }

    function _priced() private {
        vm.prank(factoryOwner);
        factory.setSubscription(recipient, PRICE);
    }
}
