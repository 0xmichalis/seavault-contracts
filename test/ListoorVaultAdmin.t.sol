// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OrderComponents} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {SeaportOrderHash} from "../src/libraries/SeaportOrderHash.sol";
import {VaultTest} from "./helpers/VaultTest.sol";
import {MockSeaport} from "./mocks/MockSeaport.sol";

/// @notice Deployment, access control, and the plumbing the owner and the keeper key operate.
contract ListoorVaultAdminTest is VaultTest {
    function test_deploymentWiring() public view {
        assertEq(address(vault.seaport()), address(seaport));
        assertEq(vault.conduit(), conduit);
        assertEq(vault.owner(), owner);
        assertEq(vault.keeper(), keeper);
        assertEq(vault.maxOrderDuration(), 30 days);
        assertEq(vault.maxFeeBps(), 1000);

        (, bytes32 domainSeparator,) = seaport.information();
        assertEq(vault.seaportDomainSeparator(), domainSeparator);
    }

    function test_rejectsSeaportWhoseDomainSeparatorDoesNotMatch() public {
        MockSeaport impostor = new MockSeaport();
        impostor.setDomainSeparatorOverride(keccak256("not seaport"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ListoorVault.SeaportDomainMismatch.selector,
                SeaportOrderHash.domainSeparator(address(impostor), keccak256("1.6")),
                keccak256("not seaport")
            )
        );
        new ListoorVault(address(impostor), conduit, owner, keeper);
    }

    function test_rejectsZeroAddressesAtDeployment() public {
        vm.expectRevert(ListoorVault.ZeroAddress.selector);
        new ListoorVault(address(0), conduit, owner, keeper);

        vm.expectRevert(ListoorVault.ZeroAddress.selector);
        new ListoorVault(address(seaport), address(0), owner, keeper);

        vm.expectRevert(ListoorVault.ZeroAddress.selector);
        new ListoorVault(address(seaport), conduit, owner, address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ListoorVault(address(seaport), conduit, address(0), keeper);
    }

    /*//////////////////////////////////////////////////////////////
                                 POLICY
    //////////////////////////////////////////////////////////////*/

    function test_setKeeper() public {
        address newKeeper = makeAddr("newKeeper");

        vm.expectEmit(true, true, true, true);
        emit ListoorVault.KeeperUpdated(newKeeper);
        vm.prank(owner);
        vault.setKeeper(newKeeper);

        assertEq(vault.keeper(), newKeeper);
    }

    function test_rejectsZeroKeeper() public {
        vm.expectRevert(ListoorVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.setKeeper(address(0));
    }

    function test_setPolicy() public {
        vm.startPrank(owner);
        vault.setListingFloor(address(nft), 5 ether);
        vault.setTokenListingFloor(address(nft), TOKEN_ID, 9 ether);
        vault.setOfferCeiling(address(nft), 3 ether);
        vault.setPaymentTokenAllowed(address(0xbeef), true);
        vault.setMaxOrderDuration(1 days);
        vault.setMaxFeeBps(2500);
        vm.stopPrank();

        assertEq(vault.listingFloor(address(nft)), 5 ether);
        assertEq(vault.tokenListingFloor(address(nft), TOKEN_ID), 9 ether);
        assertEq(vault.listingFloorFor(address(nft), TOKEN_ID), 9 ether);
        assertEq(vault.offerCeiling(address(nft)), 3 ether);
        assertTrue(vault.paymentTokenAllowed(address(0xbeef)));
        assertEq(vault.maxOrderDuration(), 1 days);
        assertEq(vault.maxFeeBps(), 2500);
    }

    function test_rejectsFeeCapAboveOneHundredPercent() public {
        vm.expectRevert(abi.encodeWithSelector(ListoorVault.InvalidFeeBps.selector, 10_001));
        vm.prank(owner);
        vault.setMaxFeeBps(10_001);
    }

    function test_policyIsOwnerOnly() public {
        vm.startPrank(keeper);
        _expectUnauthorized();
        vault.setKeeper(keeper);
        _expectUnauthorized();
        vault.setListingFloor(address(nft), 1);
        _expectUnauthorized();
        vault.setTokenListingFloor(address(nft), TOKEN_ID, 1);
        _expectUnauthorized();
        vault.setOfferCeiling(address(nft), 1);
        _expectUnauthorized();
        vault.setPaymentTokenAllowed(address(weth), false);
        _expectUnauthorized();
        vault.setMaxOrderDuration(1);
        _expectUnauthorized();
        vault.setMaxFeeBps(1);
        _expectUnauthorized();
        vault.setConduitApprovalForAll(address(nft), true);
        _expectUnauthorized();
        vault.setConduitAllowance(address(weth), 1);
        _expectUnauthorized();
        vault.incrementCounter();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  OPS
    //////////////////////////////////////////////////////////////*/

    function test_approvesConduitForCollections() public {
        vm.startPrank(owner);
        vault.setConduitApprovalForAll(address(nft), true);
        vault.setConduitApprovalForAll(address(edition), true);
        vm.stopPrank();

        assertTrue(nft.isApprovedForAll(address(vault), conduit));
        assertTrue(edition.isApprovedForAll(address(vault), conduit));

        vm.prank(owner);
        vault.setConduitApprovalForAll(address(nft), false);
        assertFalse(nft.isApprovedForAll(address(vault), conduit));
    }

    function test_approvesConduitForPaymentTokens() public {
        vm.prank(owner);
        vault.setConduitAllowance(address(weth), 5 ether);

        assertEq(weth.allowance(address(vault), conduit), 5 ether);
    }

    function test_cancelOrdersForwardsToSeaport() public {
        OrderComponents[] memory orders = new OrderComponents[](2);
        orders[0] = listing(FLOOR);
        orders[1] = offer(CEILING);

        vm.prank(keeper);
        assertTrue(vault.cancelOrders(orders));
        assertEq(seaport.cancelledCount(), 2);

        vm.prank(owner);
        vault.cancelOrders(orders);
        assertEq(seaport.cancelledCount(), 4);
    }

    function test_cancelOrdersRejectsStrangers() public {
        OrderComponents[] memory orders = new OrderComponents[](1);
        orders[0] = listing(FLOOR);

        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, stranger));
        vm.prank(stranger);
        vault.cancelOrders(orders);
    }

    function test_incrementCounterForwardsToSeaport() public {
        vm.prank(owner);
        assertEq(vault.incrementCounter(), 1);
        assertEq(seaport.incrementCounterCalls(), 1);
    }

    function test_wrapAndUnwrap() public {
        vm.deal(address(vault), 3 ether);

        vm.prank(keeper);
        vault.wrapETH(address(weth), 2 ether);
        assertEq(weth.balanceOf(address(vault)), 2 ether);
        assertEq(address(vault).balance, 1 ether);

        vm.prank(owner);
        vault.unwrapWETH(address(weth), 1 ether);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(address(vault).balance, 2 ether);
    }

    function test_wrapRejectsTokensOutsideTheAllowlist() public {
        vm.deal(address(vault), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVault.PaymentTokenNotAllowed.selector, address(0xbeef))
        );
        vm.prank(keeper);
        vault.wrapETH(address(0xbeef), 1 ether);
    }

    function test_wrapRejectsStrangers() public {
        vm.deal(address(vault), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ListoorVault.NotOwnerOrKeeper.selector, stranger));
        vm.prank(stranger);
        vault.wrapETH(address(weth), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          CUSTODY IN AND OUT
    //////////////////////////////////////////////////////////////*/

    function test_receivesAssets() public {
        address holder = makeAddr("holder");
        nft.mint(holder, TOKEN_ID);
        edition.mint(holder, EDITION_ID, 5);
        edition.mint(holder, EDITION_ID + 1, 5);
        vm.deal(holder, 1 ether);

        uint256[] memory ids = new uint256[](2);
        ids[0] = EDITION_ID;
        ids[1] = EDITION_ID + 1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5;
        amounts[1] = 5;

        vm.startPrank(holder);
        nft.safeTransferFrom(holder, address(vault), TOKEN_ID);
        edition.safeBatchTransferFrom(holder, address(vault), ids, amounts, "");
        (bool sent,) = address(vault).call{value: 1 ether}("");
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), address(vault));
        assertEq(edition.balanceOf(address(vault), EDITION_ID), 5);
        assertEq(edition.balanceOf(address(vault), EDITION_ID + 1), 5);
        assertTrue(sent);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_ownerWithdrawsEverything() public {
        address cold = makeAddr("cold");
        nft.mint(address(vault), TOKEN_ID);
        edition.mint(address(vault), EDITION_ID, 5);
        weth.mint(address(vault), 4 ether);
        vm.deal(address(vault), 2 ether);

        vm.startPrank(owner);
        vault.withdrawERC721(address(nft), cold, TOKEN_ID);
        vault.withdrawERC1155(address(edition), cold, EDITION_ID, 5);
        vault.withdrawERC20(address(weth), cold, 4 ether);
        vault.withdrawETH(cold, 2 ether);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), cold);
        assertEq(edition.balanceOf(cold, EDITION_ID), 5);
        assertEq(weth.balanceOf(cold), 4 ether);
        assertEq(cold.balance, 2 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_withdrawalsAreOwnerOnly() public {
        nft.mint(address(vault), TOKEN_ID);
        edition.mint(address(vault), EDITION_ID, 1);
        weth.mint(address(vault), 1 ether);
        vm.deal(address(vault), 1 ether);

        vm.startPrank(keeper);
        _expectUnauthorized();
        vault.withdrawERC721(address(nft), keeper, TOKEN_ID);
        _expectUnauthorized();
        vault.withdrawERC1155(address(edition), keeper, EDITION_ID, 1);
        _expectUnauthorized();
        vault.withdrawERC20(address(weth), keeper, 1 ether);
        _expectUnauthorized();
        vault.withdrawETH(keeper, 1 ether);
        vm.stopPrank();
    }

    /// @dev Renouncing would lock the assets in and the keeper in place forever.
    function test_ownershipCannotBeRenounced() public {
        vm.expectRevert(ListoorVault.OwnershipCannotBeRenounced.selector);
        vm.prank(owner);
        vault.renounceOwnership();

        assertEq(vault.owner(), owner);
    }

    /// @dev The cold key can hand over custody, but only in two steps.
    function test_ownershipTransferIsTwoStep() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), newOwner);

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    function _expectUnauthorized() private {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
    }
}
