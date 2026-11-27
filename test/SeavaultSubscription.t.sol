// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {Seavault} from "../src/Seavault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice A lapsed subscription preserves free-tier signing and owner control.
contract SeavaultSubscriptionTest is VaultTest {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    function test_signsWhileSubscribed() public view {
        assertEq(validate(listing(FLOOR)), MAGIC_VALUE);
        assertEq(validate(offer(CEILING)), MAGIC_VALUE);
    }

    function test_freeTierStillSignsOnceLapsed() public {
        subscriptions.set(false);

        assertEq(validate(listing(FLOOR)), MAGIC_VALUE);
        assertEq(validate(offer(CEILING)), MAGIC_VALUE);
    }

    /// @dev Free-tier signatures must still obey every owner-set trading policy.
    function test_policyStillAppliesOnceLapsed() public {
        subscriptions.set(false);

        expectRevertOn(
            abi.encodeWithSelector(Seavault.PriceBelowFloor.selector, FLOOR, 1 wei), listing(1 wei)
        );
    }

    /// @dev Subscription changes do not invalidate otherwise valid listings and offers.
    function test_signaturesSurviveLapseAndRenewal() public {
        OrderComponents memory order = listing(FLOOR);
        subscriptions.set(false);
        assertEq(validate(order), MAGIC_VALUE);

        subscriptions.set(true);
        assertEq(validate(order), MAGIC_VALUE);
    }

    /*//////////////////////////////////////////////////////////////
                        CUSTODY IS NEVER HOSTAGE
    //////////////////////////////////////////////////////////////*/

    function test_ownerStillControlsAssetsWhileLapsed() public {
        subscriptions.set(false);
        address cold = makeAddr("cold");
        nft.mint(address(vault), TOKEN_ID);
        weth.mint(address(vault), 1 ether);
        vm.deal(address(vault), 1 ether);

        vm.startPrank(owner);
        vault.withdrawERC721(address(nft), cold, TOKEN_ID);
        vault.withdrawERC20(address(weth), cold, 1 ether);
        vault.withdrawETH(cold, 1 ether);
        vault.setKeeper(makeAddr("newKeeper"));
        vm.stopPrank();
        setNftPolicy(2 ether, CEILING);

        assertEq(nft.ownerOf(TOKEN_ID), cold);
        assertEq(weth.balanceOf(cold), 1 ether);
        assertEq(cold.balance, 1 ether);
    }

    /// @dev Retracting orders has to keep working, or a lapse would leave live listings unretractable.
    function test_cancellingStillWorksWhileLapsed() public {
        subscriptions.set(false);
        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = listing(FLOOR);

        vm.prank(keeper);
        assertTrue(vault.cancelOrders(orders));

        vm.prank(owner);
        vault.incrementCounter();
    }
}
