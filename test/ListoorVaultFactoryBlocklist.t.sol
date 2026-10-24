// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";

contract ListoorVaultFactoryBlocklistTest is Test {
    using stdStorage for StdStorage;

    ListoorVaultFactory internal factory;
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal vault = makeAddr("vault");
    address internal otherVault = makeAddr("otherVault");

    function setUp() public {
        factory = new ListoorVaultFactory(makeAddr("seaport"), makeAddr("conduit"), factoryOwner);
        stdstore.target(address(factory))
            .sig(factory.isVault.selector)
            .with_key(vault)
            .checked_write(true);
        stdstore.target(address(factory))
            .sig(factory.isVault.selector)
            .with_key(otherVault)
            .checked_write(true);
    }

    function test_vaultsStartUnblocked() public view {
        assertFalse(factory.isBlocked(vault));
        assertFalse(factory.isBlocked(otherVault));
    }

    function test_ownerBlocksAndUnblocksOneVault() public {
        vm.startPrank(factoryOwner);
        vm.expectEmit(true, false, false, true);
        emit ListoorVaultFactory.VaultBlockStatusUpdated(vault, true);
        factory.setBlocked(vault, true);
        assertTrue(factory.isBlocked(vault));
        assertFalse(factory.isBlocked(otherVault));

        vm.expectEmit(true, false, false, true);
        emit ListoorVaultFactory.VaultBlockStatusUpdated(vault, false);
        factory.setBlocked(vault, false);
        assertFalse(factory.isBlocked(vault));
        vm.stopPrank();
    }

    function test_blockingAndUnblockingAreOwnerOnly() public {
        address caller = makeAddr("caller");
        vm.prank(factoryOwner);
        factory.setBlocked(vault, true);

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        factory.setBlocked(otherVault, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        factory.setBlocked(vault, false);
        vm.stopPrank();
        assertTrue(factory.isBlocked(vault));
        assertFalse(factory.isBlocked(otherVault));
    }

    function test_rejectsUnregisteredVaults() public {
        address unknown = makeAddr("unknown");
        vm.startPrank(factoryOwner);
        vm.expectRevert(abi.encodeWithSelector(ListoorVaultFactory.NotAVault.selector, unknown));
        factory.setBlocked(unknown, true);
        vm.expectRevert(abi.encodeWithSelector(ListoorVaultFactory.NotAVault.selector, unknown));
        factory.setBlocked(unknown, false);
        vm.stopPrank();
    }

    function test_blockingPreservesPaidTimeAndZeroPriceExceptionsDoNotUnblock() public {
        uint256 price = 0.01 ether;
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, price);
        address payer = makeAddr("payer");
        vm.deal(payer, price);
        vm.prank(payer);
        factory.extendSubscription{value: price}(vault, 1);
        uint256 expiry = factory.paidThrough(vault);

        vm.startPrank(factoryOwner);
        factory.setBlocked(vault, true);
        assertTrue(factory.isSubscribed(vault));
        assertEq(factory.paidThrough(vault), expiry);
        factory.setPriceOverride(vault, true, 0);
        assertTrue(factory.isBlocked(vault));
        assertTrue(factory.isSubscribed(vault));
        factory.setSubscription(factoryOwner, 0);
        assertTrue(factory.isBlocked(vault));
        assertEq(factory.paidThrough(vault), expiry);
        vm.stopPrank();
    }
}
