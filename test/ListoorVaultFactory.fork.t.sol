// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";
import {BaseFork} from "./helpers/BaseFork.sol";

/// @notice Self-service deployment and the owner registry. Runs against the real CreateX factory,
///         which is what gives every vault the same address on every chain.
contract ListoorVaultFactoryForkTest is BaseFork {
    bytes32 internal constant SALT = keccak256("primary");

    ListoorVaultFactory internal factory;
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal aliceKeeper = makeAddr("aliceKeeper");
    address internal bobKeeper = makeAddr("bobKeeper");

    function setUp() public {
        forkBase();
        factory = new ListoorVaultFactory(address(SEAPORT), OPENSEA_CONDUIT, factoryOwner);
    }

    function test_createsVaultOwnedByCaller() public {
        address predicted = factory.predictVault(alice, SALT);

        vm.prank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);

        assertEq(address(vault), predicted);
        assertEq(vault.owner(), alice);
        assertEq(vault.keeper(), aliceKeeper);
        assertEq(address(vault.seaport()), address(SEAPORT));
        assertEq(vault.conduit(), OPENSEA_CONDUIT);
        assertEq(address(vault.subscriptions()), address(factory));
    }

    function test_registersVaultForLookup() public {
        vm.expectEmit(true, true, true, true);
        emit ListoorVaultFactory.VaultCreated(
            alice, factory.predictVault(alice, SALT), SALT, aliceKeeper
        );
        vm.prank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);

        assertEq(factory.vaultOf(alice, SALT), address(vault));
        assertTrue(factory.isVault(address(vault)));
        assertEq(factory.vaultCount(alice), 1);
        assertEq(factory.vaultsOf(alice)[0], address(vault));
    }

    function test_separatesVaultsPerOwnerAndSalt() public {
        vm.startPrank(alice);
        ListoorVault first = factory.createVault(SALT, aliceKeeper);
        ListoorVault second = factory.createVault(keccak256("secondary"), aliceKeeper);
        vm.stopPrank();

        vm.prank(bob);
        ListoorVault bobsVault = factory.createVault(SALT, bobKeeper);

        assertTrue(address(first) != address(second));
        assertTrue(address(first) != address(bobsVault));
        assertEq(factory.vaultCount(alice), 2);
        assertEq(factory.vaultCount(bob), 1);
        assertEq(bobsVault.owner(), bob);
    }

    function test_firstNativeDepositCreatesAndFundsVaultInOneTransaction() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        ListoorVault vault = factory.createVault{value: 1 ether}(SALT, aliceKeeper);

        assertEq(address(vault).balance, 1 ether);
        assertEq(address(factory).balance, 0);
        assertEq(factory.ownedVaultsOf(alice), _one(address(vault)));
    }

    function test_discoversCurrentAndPendingOwnersAfterTransfers() public {
        vm.prank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);

        vm.prank(alice);
        vault.transferOwnership(bob);
        assertEq(factory.ownedVaultsOf(alice), _one(address(vault)));
        assertEq(factory.ownedVaultsOf(bob).length, 0);
        assertEq(factory.pendingVaultsOf(bob), _one(address(vault)));

        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(factory.ownedVaultsOf(alice).length, 0);
        assertEq(factory.ownedVaultsOf(bob), _one(address(vault)));
        assertEq(factory.pendingVaultsOf(bob).length, 0);
        assertEq(factory.vaultsOf(alice), _one(address(vault)));
        assertEq(factory.vaultOf(alice, SALT), address(vault));
        assertEq(vault.keeper(), aliceKeeper);
    }

    function test_replacingAndCancellingPendingTransfersUpdatesDiscovery() public {
        vm.startPrank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);
        vault.transferOwnership(bob);
        vault.transferOwnership(factoryOwner);
        assertEq(factory.pendingVaultsOf(bob).length, 0);
        assertEq(factory.pendingVaultsOf(factoryOwner), _one(address(vault)));
        vault.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(factory.pendingVaultsOf(factoryOwner).length, 0);
        assertEq(factory.pendingVaultsOf(address(0)).length, 0);
        assertEq(factory.ownedVaultsOf(alice), _one(address(vault)));
    }

    function test_ownerIndexHandlesMultipleVaultsAndRepeatedTransfers() public {
        vm.startPrank(alice);
        ListoorVault first = factory.createVault(SALT, aliceKeeper);
        ListoorVault second = factory.createVault(keccak256("secondary"), aliceKeeper);
        first.transferOwnership(bob);
        vm.stopPrank();
        vm.startPrank(bob);
        first.acceptOwnership();
        first.transferOwnership(alice);
        vm.stopPrank();
        vm.prank(alice);
        first.acceptOwnership();

        address[] memory owned = factory.ownedVaultsOf(alice);
        assertEq(owned.length, 2);
        assertEq(owned[0], address(second));
        assertEq(owned[1], address(first));
        assertEq(factory.ownedVaultsOf(bob).length, 0);
        assertEq(factory.pendingVaultsOf(alice).length, 0);
        vm.prank(alice);
        first.transferOwnership(alice);
        vm.prank(alice);
        first.acceptOwnership();
        assertEq(factory.ownedVaultsOf(alice), owned);
    }

    function test_onlyRegisteredVaultsCanUpdateDiscovery() public {
        vm.expectRevert(abi.encodeWithSelector(ListoorVaultFactory.NotAVault.selector, alice));
        vm.prank(alice);
        factory.syncVaultOwnership(alice, bob);
    }

    function _one(address vault) private pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = vault;
    }

    function test_rejectsReusedSalt() public {
        vm.startPrank(alice);
        factory.createVault(SALT, aliceKeeper);

        vm.expectRevert(
            abi.encodeWithSelector(ListoorVaultFactory.VaultAlreadyExists.selector, SALT)
        );
        factory.createVault(SALT, aliceKeeper);
        vm.stopPrank();
    }

    /// @dev The address depends on the owner and salt only, so it is the same on every chain even
    ///      though the factory passes a different Seaport or conduit in.
    function test_sameVaultAddressAcrossChains() public {
        uint256 beforeCreate = vm.snapshotState();
        vm.prank(alice);
        address onBase = address(factory.createVault(SALT, aliceKeeper));

        vm.revertToState(beforeCreate);
        vm.chainId(1);
        vm.prank(alice);
        address onEthereum = address(factory.createVault(SALT, makeAddr("otherKeeper")));

        assertEq(onEthereum, onBase);
    }

    /// @dev Two factories cannot land on the same vault address, so a redeployed factory (new
    ///      Seaport, say) yields a fresh set of vaults rather than colliding with the old ones.
    function test_vaultAddressIsScopedToTheFactory() public {
        ListoorVaultFactory other =
            new ListoorVaultFactory(address(SEAPORT), OPENSEA_CONDUIT, factoryOwner);

        assertTrue(factory.predictVault(alice, SALT) != other.predictVault(alice, SALT));
    }

    /// @dev Nobody can put their own code at a vault address before its owner claims it: CreateX only
    ///      honours the factory's salt for the factory itself.
    function test_strangerCannotOccupyAVaultAddress() public {
        address predicted = factory.predictVault(alice, SALT);
        bytes32 factorySalt = bytes32(
            abi.encodePacked(
                bytes20(address(factory)), bytes1(0x00), bytes11(keccak256(abi.encode(alice, SALT)))
            )
        );

        vm.prank(makeAddr("stranger"));
        address squatted =
            factory.CREATE_X().deployCreate3(factorySalt, type(Squatter).creationCode);

        assertTrue(squatted != predicted);

        vm.prank(alice);
        assertEq(address(factory.createVault(SALT, aliceKeeper)), predicted);
    }

    function test_rejectsZeroKeeper() public {
        vm.expectRevert(ListoorVaultFactory.ZeroAddress.selector);
        vm.prank(alice);
        factory.createVault(SALT, address(0));
    }

    function test_rejectsZeroAddressesAtDeployment() public {
        vm.expectRevert(ListoorVaultFactory.ZeroAddress.selector);
        new ListoorVaultFactory(address(0), OPENSEA_CONDUIT, factoryOwner);

        vm.expectRevert(ListoorVaultFactory.ZeroAddress.selector);
        new ListoorVaultFactory(address(SEAPORT), address(0), factoryOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ListoorVaultFactory(address(SEAPORT), OPENSEA_CONDUIT, address(0));
    }

    /// @dev A new vault starts inside a trial window, so it can trade before anyone pays.
    function test_createdVaultStartsOnATrial() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.05 ether);

        vm.prank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);

        assertEq(factory.paidThrough(address(vault)), block.timestamp + factory.trialPeriod());
        assertTrue(factory.isSubscribed(address(vault)));

        vm.warp(block.timestamp + factory.trialPeriod() + 1);
        assertFalse(factory.isSubscribed(address(vault)));
    }

    /// @dev A vault can renew itself out of its own proceeds.
    function test_vaultRenewsItsOwnSubscription() public {
        vm.prank(factoryOwner);
        factory.setSubscription(factoryOwner, 0.05 ether);
        vm.prank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);
        vm.deal(address(vault), 1 ether);
        uint256 trialExpiry = factory.paidThrough(address(vault));
        uint256 treasuryBefore = factoryOwner.balance;

        vm.prank(alice);
        vault.renewSubscription(2, 0.1 ether);

        assertEq(
            factory.paidThrough(address(vault)), trialExpiry + 2 * factory.SUBSCRIPTION_PERIOD()
        );
        assertEq(factoryOwner.balance - treasuryBefore, 0.1 ether);
        assertEq(address(vault).balance, 0.9 ether);
    }

    /// @dev A vault from the factory behaves exactly like a directly deployed one.
    function test_vaultFromFactoryEnforcesPolicy() public {
        vm.prank(alice);
        ListoorVault vault = factory.createVault(SALT, aliceKeeper);

        vm.prank(alice);
        vault.setListingFloor(address(0xc0113c), 1 ether);
        assertEq(vault.listingFloorFor(address(0xc0113c), 1), 1 ether);

        vm.expectRevert();
        vault.setListingFloor(address(0xc0113c), 0);
    }
}

contract Squatter {}
