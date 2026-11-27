// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseFork} from "./helpers/BaseFork.sol";
import {VaultInvariantHandler} from "./helpers/VaultInvariantHandler.sol";

/// @notice Stateful asset-safety properties under real Seaport, conduit and WETH settlement.
contract SeavaultInvariantForkTest is BaseFork {
    VaultInvariantHandler internal handler;
    uint256 private constant UNIT = 1 ether;

    function setUp() public {
        forkBase();
        handler = new VaultInvariantHandler(SEAPORT, OPENSEA_CONDUIT, OPENSEA_CONDUIT_KEY);
        // Start with live and cached orders so replay attacks do not depend on posting first.
        uint256 cached = handler.postOrder(false, true, 0, UNIT, 0);
        assertTrue(handler.validateOrder(cached));
        handler.postOrder(true, false, 3, UNIT / 2, 32);
        handler.postOrder(false, false, 2, UNIT, 16);
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.postOrder.selector;
        selectors[1] = handler.validateOrder.selector;
        selectors[2] = handler.fulfillOrder.selector;
        selectors[3] = handler.cancelOrder.selector;
        selectors[4] = handler.revokeOrders.selector;
        selectors[5] = handler.buy.selector;
        selectors[6] = handler.matchOrders.selector;
        selectors[7] = handler.configurePolicy.selector;
        selectors[8] = handler.setBudgets.selector;
        selectors[9] = handler.wrap.selector;
        selectors[10] = handler.withdraw.selector;
        selectors[11] = handler.setAutoWithdraw.selector;
        selectors[12] = handler.transferOwnership.selector;
        selectors[13] = handler.setAccess.selector;
        selectors[14] = handler.advanceTime.selector;
        selectors[15] = handler.deposit.selector;
        selectors[16] = handler.attack.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        // The handler selects/pranks every role; fresh entrypoint callers only add fork RPC reads.
        targetSender(address(handler.taker()));
    }

    function invariant_assetsAndAuthorityRemainSafe() public view {
        // Check all properties on the same state after every action.
        _assertAll();
    }

    function afterInvariant() public {
        handler.exitToOwner();
    }

    function test_partialOfferRevokedByRootChange() public {
        uint256 index = handler.postOrder(true, false, 3, UNIT / 2, 0);
        assertTrue(handler.fulfillOrder(index, 2)); // two of eight units
        handler.configurePolicy(0); // Set the ceilings to zero.
        handler.setAccess(true, false);
        assertFalse(handler.fulfillOrder(index, 2));
        assertEq(handler.successfulFills(), 1);
        _assertAll();
    }

    function test_validatedListingsRevokedByRootChange() public {
        uint256 first = handler.postOrder(false, true, 0, UNIT, 0);
        uint256 second = handler.postOrder(false, true, 1, UNIT, 0);
        assertTrue(handler.validateOrder(first));
        assertTrue(handler.validateOrder(second));
        handler.configurePolicy((2 * UNIT) << 8); // Commit a higher floor without a separate cancel.
        assertFalse(handler.fulfillOrder(first, 0));
        assertFalse(handler.fulfillOrder(second, 0));
        _assertAll();
    }

    /// @dev The lead-time bound is measured when Seaport asks: a listing posted one second past it
    ///      is refused now and accepted two hours later, when it starts within the bound again.
    function test_ordersStartingTooFarAheadCannotBeValidatedUntilTheyAreWithinBound() public {
        uint256 sleeper = handler.postOrder(false, true, 0, UNIT, 8);
        assertFalse(handler.validateOrder(sleeper));
        assertFalse(handler.fulfillOrder(sleeper, 0));
        handler.advanceTime(2 hours);
        assertTrue(handler.validateOrder(sleeper));
        assertFalse(handler.fulfillOrder(sleeper, 0));
        assertEq(handler.successfulValidations(), 2);
        _assertAll();
    }

    function test_decliningEditionQuantityCannotOverpay() public {
        uint256 index = handler.postOrder(true, false, 3, UNIT / 2, 5);
        bool validated = handler.validateOrder(index);
        handler.advanceTime(1 hours - 1);
        bool filled = handler.fulfillOrder(index, 0);
        _assertAll();
        assertFalse(validated);
        assertFalse(filled);
    }

    function test_wrappingCannotBypassTheSharedWethBudget() public {
        handler.setBudgets(0, UNIT);
        assertTrue(handler.wrap(10 * UNIT, false));
        uint256 first = handler.postOrder(true, true, 4, UNIT, 0);
        assertTrue(handler.fulfillOrder(first, 0));
        assertTrue(handler.wrap(10 * UNIT, false));
        uint256 second = handler.postOrder(true, true, 5, UNIT, 0);
        assertFalse(handler.fulfillOrder(second, 0));
        assertEq(IERC20(handler.WETH()).allowance(address(handler.vault()), OPENSEA_CONDUIT), 0);
        _assertAll();
    }

    function test_reentrantSellerCannotTakeMoreThanThePurchasePrice() public {
        uint256 attempts = handler.taker().callbackAttempts();
        assertTrue(handler.buy(false, false, 0, UNIT, 0));
        assertGt(handler.taker().callbackAttempts(), attempts);
        assertEq(handler.successfulBuys(), 1);
        _assertAll();
    }

    function test_selfMatchedOrdersCannotExtractSurplus() public {
        uint256 profitableBid = handler.postOrder(true, false, 0, UNIT / 4, 0);
        assertTrue(handler.fulfillOrder(profitableBid, 0));
        assertGt(handler.minimumEquity(), handler.INITIAL_EQUITY());
        // Ceiling stays at one unit, so the lower raw floors still cannot undercut it.
        handler.configurePolicy(4 | ((UNIT / 4) << 8));
        bool extracted = handler.matchOrders(0, UNIT, UNIT / 4);
        _assertAll();
        assertFalse(extracted);
        assertTrue(handler.matchOrders(0, UNIT, UNIT));
        assertEq(handler.successfulMatches(), 1);
        _assertAll();
    }

    function test_keepersAndOutsidersCannotAcquireOwnerAuthority() public {
        for (uint256 i; i < 18; ++i) {
            handler.attack(i, false);
            handler.attack(i, true);
        }
        assertEq(handler.rejectedAttacks(), 36);
        _assertAll();
    }

    function test_partialBuysConsumeOnlyTheirShareOfEachBudget() public {
        assertTrue(handler.buy(false, false, 1, UNIT, 1));
        assertTrue(handler.buy(false, true, 2, UNIT, 2));
        assertEq(handler.expectedNativeAllowance(), 31 * UNIT);
        assertEq(handler.expectedWethAllowance(), 31 * UNIT);
        _assertAll();
    }

    function test_partialListingAndCriteriaBidsSettleWithFees() public {
        uint256 listing = handler.postOrder(false, false, 2, UNIT, 7);
        assertTrue(handler.fulfillOrder(listing, 1));
        uint256 bid = handler.postOrder(true, false, 2, UNIT / 2, 39);
        assertTrue(handler.fulfillOrder(bid, 1));
        uint256 criteria721 = handler.postOrder(true, true, 4, UNIT, 32);
        assertTrue(handler.fulfillOrder(criteria721, 0));
        assertEq(handler.successfulFills(), 3);
        _assertAll();
    }

    function test_cancelledForgedAndTamperedOrdersCannotBeReplayed() public {
        uint256 cancelled = handler.postOrder(false, true, 0, UNIT, 0);
        assertTrue(handler.validateOrder(cancelled));
        handler.cancelOrder(cancelled);
        assertFalse(handler.fulfillOrder(cancelled, 0));
        uint256 forged = handler.postOrder(false, true, 1, UNIT, 1);
        assertFalse(handler.validateOrder(forged));
        assertFalse(handler.fulfillOrder(forged, 0));
        uint256 tampered = handler.postOrder(false, true, 2, UNIT, 3);
        assertFalse(handler.validateOrder(tampered));
        assertFalse(handler.fulfillOrder(tampered, 0));
        _assertAll();
    }

    function test_variablePaymentsMustClearBoundsAtBothEnds() public {
        uint256 listing = handler.postOrder(false, true, 0, UNIT, 64);
        uint256 bid = handler.postOrder(true, true, 4, UNIT, 192);
        assertFalse(handler.validateOrder(listing));
        assertFalse(handler.validateOrder(bid));
        assertFalse(handler.fulfillOrder(listing, 0));
        assertFalse(handler.fulfillOrder(bid, 0));
        _assertAll();
    }

    function test_ownerCanExitAfterTransferBlockAndSubscriptionExpiry() public {
        handler.setAutoWithdraw(true);
        assertTrue(handler.vault().autoWithdrawEnabled());
        handler.transferOwnership();
        handler.setAccess(true, false);
        handler.advanceTime(2 hours);
        assertFalse(handler.factory().isSubscribed(address(handler.vault())));
        handler.exitToOwner();
        _assertAll();
    }

    function test_automaticWithdrawalsPayOnlyTheCurrentOwner() public {
        handler.setAutoWithdraw(true);
        assertTrue(handler.withdraw(UNIT, false, true));
        assertTrue(handler.withdraw(UNIT, true, true));
        handler.transferOwnership();
        assertFalse(handler.withdraw(UNIT, false, true));
        handler.setAutoWithdraw(true);
        assertTrue(handler.withdraw(UNIT, false, true));
        assertTrue(handler.withdraw(UNIT, true, true));
        _assertAll();
    }

    function _assertAll() private view {
        handler.assertPortfolio();
        handler.assertConservation();
        handler.assertAuthority();
    }
}
