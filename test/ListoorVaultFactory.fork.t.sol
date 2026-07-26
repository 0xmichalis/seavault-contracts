// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ListoorVault} from "../src/ListoorVault.sol";
import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";
import {BaseFork} from "./helpers/BaseFork.sol";

/// @notice Self-service deployment and the owner registry. Runs against the real CreateX factory,
///         which is what gives every vault the same address on every chain.
contract ListoorVaultFactoryForkTest is BaseFork {
    bytes32 internal constant SALT = keccak256("primary");

    ListoorVaultFactory internal factory;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal aliceKeeper = makeAddr("aliceKeeper");
    address internal bobKeeper = makeAddr("bobKeeper");

    function setUp() public {
        forkBase();
        factory = new ListoorVaultFactory(address(SEAPORT), OPENSEA_CONDUIT);
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
        ListoorVaultFactory other = new ListoorVaultFactory(address(SEAPORT), OPENSEA_CONDUIT);

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
        new ListoorVaultFactory(address(0), OPENSEA_CONDUIT);

        vm.expectRevert(ListoorVaultFactory.ZeroAddress.selector);
        new ListoorVaultFactory(address(SEAPORT), address(0));
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
