// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {VaultTest} from "./helpers/VaultTest.sol";

contract SeavaultBlocklistTest is VaultTest {
    function test_flaggedVaultValidatesListingsAndOffers() public {
        subscriptions.setBlocked(true);

        OrderComponents memory listingOrder = listing(FLOOR);
        OrderComponents memory offerOrder = offer(CEILING);
        assertEq(
            vault.isValidSignature(digestOf(listingOrder), payloadFor(listingOrder, keeperPk)),
            IERC1271.isValidSignature.selector
        );
        assertEq(
            vault.isValidSignature(digestOf(offerOrder), payloadFor(offerOrder, keeperPk)),
            IERC1271.isValidSignature.selector
        );
    }

    function test_flaggedVaultCanWithdrawAndUpdatePolicy() public {
        subscriptions.setBlocked(true);
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
        assertEq(vault.policyRoot(), collectionPolicyRoot());
    }

    function test_flaggedVaultCanCancelOrdersAndIncrementCounter() public {
        subscriptions.setBlocked(true);
        uint256 counterBefore = seaport.getCounter(address(vault));
        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = listing(FLOOR);

        vm.prank(keeper);
        assertTrue(vault.cancelOrders(orders));
        vm.prank(owner);
        assertEq(vault.incrementCounter(), counterBefore + 1);
    }
}
