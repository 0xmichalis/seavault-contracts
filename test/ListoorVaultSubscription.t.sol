// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice What a lapsed subscription does to a vault: signing stops, custody does not.
contract ListoorVaultSubscriptionTest is VaultTest {
    bytes4 internal constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    function test_signsWhileSubscribed() public view {
        assertEq(validate(listing(FLOOR)), MAGIC_VALUE);
        assertEq(validate(offer(CEILING)), MAGIC_VALUE);
    }

    function test_refusesToSignOnceLapsed() public {
        subscriptions.set(false, 0.01 ether);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.SubscriptionInactive.selector), listing(FLOOR)
        );
        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.SubscriptionInactive.selector), offer(CEILING)
        );
    }

    /// @dev Checked before anything else, so an unpaid vault reports the lapse rather than some
    ///      downstream policy complaint.
    function test_lapseTakesPrecedenceOverPolicyFailures() public {
        subscriptions.set(false, 0.01 ether);

        expectRevertOn(
            abi.encodeWithSelector(ListoorVault.SubscriptionInactive.selector), listing(1 wei)
        );
    }

    /// @dev Live orders die with the lapse and come back when it is paid, without resigning.
    function test_signingResumesAfterRenewal() public {
        OrderComponents memory order = listing(FLOOR);
        subscriptions.set(false, 0.01 ether);
        expectRevertOn(abi.encodeWithSelector(ListoorVault.SubscriptionInactive.selector), order);

        subscriptions.set(true, 0.01 ether);
        assertEq(validate(order), MAGIC_VALUE);
    }

    /*//////////////////////////////////////////////////////////////
                        CUSTODY IS NEVER HOSTAGE
    //////////////////////////////////////////////////////////////*/

    function test_ownerStillControlsAssetsWhileLapsed() public {
        subscriptions.set(false, 0.01 ether);
        address cold = makeAddr("cold");
        nft.mint(address(vault), TOKEN_ID);
        weth.mint(address(vault), 1 ether);
        vm.deal(address(vault), 1 ether);

        vm.startPrank(owner);
        vault.withdrawERC721(address(nft), cold, TOKEN_ID);
        vault.withdrawERC20(address(weth), cold, 1 ether);
        vault.withdrawETH(cold, 1 ether);
        vault.setListingFloor(address(nft), 2 ether);
        vault.setKeeper(makeAddr("newKeeper"));
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), cold);
        assertEq(weth.balanceOf(cold), 1 ether);
        assertEq(cold.balance, 1 ether);
    }

    /// @dev Retracting orders has to keep working, or a lapse would leave live listings unretractable.
    function test_cancellingStillWorksWhileLapsed() public {
        subscriptions.set(false, 0.01 ether);
        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = listing(FLOOR);

        vm.prank(keeper);
        assertTrue(vault.cancelOrders(orders));

        vm.prank(owner);
        vault.incrementCounter();
    }

    /*//////////////////////////////////////////////////////////////
                                RENEWAL
    //////////////////////////////////////////////////////////////*/

    function test_ownerRenewsFromVaultBalance() public {
        subscriptions.set(false, 0.01 ether);
        vm.deal(address(vault), 1 ether);

        vm.prank(owner);
        vault.renewSubscription(3);

        assertEq(subscriptions.periodsBought(), 3);
        assertEq(address(subscriptions).balance, 0.03 ether);
        assertEq(address(vault).balance, 0.97 ether);
        assertEq(validate(listing(FLOOR)), MAGIC_VALUE);
    }

    /// @dev Keeper-callable renewal would hand a compromised key a way to burn vault funds.
    function test_renewalIsOwnerOnly() public {
        subscriptions.set(false, 0.01 ether);
        vm.deal(address(vault), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        vault.renewSubscription(1);
    }

    function test_renewalRevertsWithoutFunds() public {
        subscriptions.set(false, 1 ether);

        vm.expectRevert();
        vm.prank(owner);
        vault.renewSubscription(1);
    }
}
