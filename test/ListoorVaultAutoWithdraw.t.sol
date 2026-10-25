// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

/// @notice Automatic withdrawals require owner consent, subscription entitlement and an unblocked vault.
contract ListoorVaultAutoWithdrawTest is VaultTest {
    function test_disabledByDefaultEvenForSubscribers() public {
        assertFalse(vault.autoWithdrawEnabled());
        _fundVault();

        vm.startPrank(keeper);
        vm.expectRevert(ListoorVault.AutoWithdrawDisabled.selector);
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(ListoorVault.AutoWithdrawDisabled.selector);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_onlyOwnerCanOptInOrOut() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        vault.setAutoWithdrawEnabled(true);

        _enable();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vm.prank(keeper);
        vault.setAutoWithdrawEnabled(false);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        vault.setAutoWithdrawEnabled(false);
        assertTrue(vault.autoWithdrawEnabled());
    }

    function test_cannotEnableWithoutSubscription() public {
        subscriptions.set(false, 0.01 ether);

        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
        assertFalse(vault.autoWithdrawEnabled());
    }

    function test_cannotEnableWhileBlocked() public {
        subscriptions.setBlocked(true);

        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
        assertFalse(vault.autoWithdrawEnabled());
    }

    function testFuzz_keeperReturnsEthOnlyToOwner(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        _enable();
        vm.deal(address(vault), amount + 1 ether);
        uint256 ownerBalance = owner.balance;
        uint256 keeperBalance = keeper.balance;

        vm.prank(keeper);
        vault.autoWithdrawETH(amount);

        assertEq(owner.balance, ownerBalance + amount);
        assertEq(address(vault).balance, 1 ether);
        assertEq(keeper.balance, keeperBalance);
    }

    function testFuzz_keeperReturnsErc20OnlyToOwner(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        _enable();
        weth.mint(address(vault), amount + 1 ether);

        vm.prank(keeper);
        vault.autoWithdrawERC20(address(weth), amount);

        assertEq(weth.balanceOf(owner), amount);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(weth.balanceOf(keeper), 0);
    }

    function test_ownerCanAlsoTriggerAutomaticWithdrawals() public {
        _enable();
        _fundVault();
        uint256 ownerBalance = owner.balance;

        vm.startPrank(owner);
        vault.autoWithdrawETH(1 ether);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        assertEq(owner.balance, ownerBalance + 1 ether);
        assertEq(weth.balanceOf(owner), 1 ether);
    }

    function test_strangerCannotTriggerAutomaticWithdrawals() public {
        _enable();
        _fundVault();

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, stranger));
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, stranger));
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_expiryPausesBothAutomaticWithdrawalsAndRenewalResumesThem() public {
        _enable();
        _fundVault();
        uint256 ownerBalance = owner.balance;
        subscriptions.set(false, 0.01 ether);

        vm.startPrank(keeper);
        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();
        assertTrue(vault.autoWithdrawEnabled());
        assertEq(address(vault).balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 1 ether);

        vm.prank(owner);
        vault.renewSubscription(1, 0.01 ether);
        vm.startPrank(keeper);
        vault.autoWithdrawETH(0.99 ether);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        assertEq(owner.balance, ownerBalance + 0.99 ether);
        assertEq(weth.balanceOf(owner), 1 ether);
    }

    function test_ownerCanDisableWhileLapsedAndBlocked() public {
        _enable();
        subscriptions.set(false, 0.01 ether);
        subscriptions.setBlocked(true);

        vm.expectEmit(true, true, true, true);
        emit ListoorVault.AutoWithdrawEnabledUpdated(false);
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(false);

        assertFalse(vault.autoWithdrawEnabled());
    }

    function test_optOutStopsBothAutomaticWithdrawals() public {
        _enable();
        _fundVault();
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(false);

        vm.startPrank(keeper);
        vm.expectRevert(ListoorVault.AutoWithdrawDisabled.selector);
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(ListoorVault.AutoWithdrawDisabled.selector);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_blockingPausesAutomaticWithdrawalsUntilUnblocked() public {
        _enable();
        _fundVault();
        subscriptions.setBlocked(true);
        uint256 ownerBalance = owner.balance;

        address[2] memory callers = [owner, keeper];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(ListoorVault.VaultBlocked.selector);
            vault.autoWithdrawETH(1 ether);
            vm.expectRevert(ListoorVault.VaultBlocked.selector);
            vault.autoWithdrawERC20(address(weth), 1 ether);
            vm.stopPrank();
        }
        assertTrue(vault.autoWithdrawEnabled());
        assertEq(address(vault).balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 1 ether);

        subscriptions.setBlocked(false);
        vm.startPrank(keeper);
        vault.autoWithdrawETH(1 ether);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        assertEq(owner.balance, ownerBalance + 1 ether);
        assertEq(weth.balanceOf(owner), 1 ether);
    }

    function test_unblockingDoesNotBypassSubscriptionRequirement() public {
        _enable();
        _fundVault();
        subscriptions.setBlocked(true);
        subscriptions.set(false, 0.01 ether);
        subscriptions.setBlocked(false);

        vm.startPrank(keeper);
        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(ListoorVault.SubscriptionInactive.selector);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        assertTrue(vault.autoWithdrawEnabled());
        assertEq(address(vault).balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
    }

    function test_ownerWithdrawalsRemainAvailableAfterExpiryAndBlocking() public {
        _enable();
        _fundVault();
        subscriptions.set(false, 0.01 ether);
        subscriptions.setBlocked(true);
        address cold = makeAddr("cold");

        vm.startPrank(owner);
        vault.withdrawETH(cold, 1 ether);
        vault.withdrawERC20(address(weth), cold, 1 ether);
        vm.stopPrank();

        assertEq(cold.balance, 1 ether);
        assertEq(weth.balanceOf(cold), 1 ether);
    }

    function test_optInDoesNotAuthorizeKeeperChosenRecipientsOrNftWithdrawals() public {
        _enable();
        _fundVault();
        nft.mint(address(vault), TOKEN_ID);
        edition.mint(address(vault), EDITION_ID, 1);

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.withdrawETH(keeper, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.withdrawERC20(address(weth), keeper, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.withdrawERC721(address(nft), keeper, TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.withdrawERC1155(address(edition), keeper, EDITION_ID, 1);
        vm.stopPrank();
    }

    function test_acceptingOwnershipClearsOptInAndNewOwnerMustEnableAgain() public {
        _enable();
        _fundVault();
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        vm.expectEmit(true, true, true, true);
        emit ListoorVault.AutoWithdrawEnabledUpdated(false);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertFalse(vault.autoWithdrawEnabled());

        vm.startPrank(keeper);
        vm.expectRevert(ListoorVault.AutoWithdrawDisabled.selector);
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(ListoorVault.AutoWithdrawDisabled.selector);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        vm.prank(newOwner);
        vault.setAutoWithdrawEnabled(true);
        vm.startPrank(keeper);
        vault.autoWithdrawETH(1 ether);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        assertEq(newOwner.balance, 1 ether);
        assertEq(weth.balanceOf(newOwner), 1 ether);
        assertEq(owner.balance, 0);
        assertEq(weth.balanceOf(owner), 0);
    }

    function test_pendingOwnershipDoesNotRedirectWithdrawals() public {
        _enable();
        _fundVault();
        address newOwner = makeAddr("newOwner");
        uint256 ownerBalance = owner.balance;
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        vm.startPrank(keeper);
        vault.autoWithdrawETH(1 ether);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        assertEq(owner.balance, ownerBalance + 1 ether);
        assertEq(weth.balanceOf(owner), 1 ether);
        assertEq(newOwner.balance, 0);
        assertEq(weth.balanceOf(newOwner), 0);
    }

    function test_keeperRotationRevokesAutomaticWithdrawalAccess() public {
        _enable();
        _fundVault();
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        vault.setKeeper(newKeeper);

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, keeper));
        vault.autoWithdrawETH(1 ether);
        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, keeper));
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();

        vm.startPrank(newKeeper);
        vault.autoWithdrawETH(1 ether);
        vault.autoWithdrawERC20(address(weth), 1 ether);
        vm.stopPrank();
    }

    function _enable() private {
        vm.prank(owner);
        vault.setAutoWithdrawEnabled(true);
    }

    function _fundVault() private {
        vm.deal(address(vault), 1 ether);
        weth.mint(address(vault), 1 ether);
    }
}
