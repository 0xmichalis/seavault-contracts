// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {VaultTest} from "./helpers/VaultTest.sol";

contract ListoorVaultBlocklistTest is VaultTest {
    function test_blockingRejectsPaidListingsAndOffers() public {
        subscriptions.set(true, 0.01 ether);
        subscriptions.setBlocked(true);

        expectRevertOn(abi.encodeWithSelector(ListoorVault.VaultBlocked.selector), listing(FLOOR));
        expectRevertOn(abi.encodeWithSelector(ListoorVault.VaultBlocked.selector), offer(CEILING));
    }

    function test_blockingRejectsFreeTierListingsAndOffers() public {
        subscriptions.set(false, 0.01 ether);
        subscriptions.setBlocked(true);

        expectRevertOn(abi.encodeWithSelector(ListoorVault.VaultBlocked.selector), listing(FLOOR));
        expectRevertOn(abi.encodeWithSelector(ListoorVault.VaultBlocked.selector), offer(CEILING));
    }

    function test_unblockingRestoresExistingSignaturesWithoutResigning() public {
        OrderComponents memory order = listing(FLOOR);
        bytes32 digest = digestOf(order);
        bytes memory signature = payloadFor(order, keeperPk);
        subscriptions.setBlocked(true);
        vm.expectRevert(ListoorVault.VaultBlocked.selector);
        vault.isValidSignature(digest, signature);

        subscriptions.setBlocked(false);
        assertEq(vault.isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
    }

    function test_blockingDoesNotHoldAssetsOrOwnerPolicyHostage() public {
        subscriptions.setBlocked(true);
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
        assertEq(vault.listingFloor(address(nft)), 2 ether);
    }

    function test_blockedVaultCanCancelOrdersAndIncrementCounter() public {
        subscriptions.setBlocked(true);
        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = listing(FLOOR);

        vm.prank(keeper);
        assertTrue(vault.cancelOrders(orders));
        vm.prank(owner);
        assertEq(vault.incrementCounter(), 1);
    }
}
