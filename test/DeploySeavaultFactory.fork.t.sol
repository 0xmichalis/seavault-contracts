// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySeavaultFactory} from "../script/DeploySeavaultFactory.s.sol";
import {SeavaultFactory} from "../src/SeavaultFactory.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";
import {BaseFork} from "./helpers/BaseFork.sol";

/// @notice Factory deployment determinism against the real CreateX factory. Vault addresses derive
///         from the factory address, so this is what makes them match across chains.
contract DeploySeavaultFactoryForkTest is BaseFork {
    DeploySeavaultFactory internal deployScript;
    ICreateX internal createX;
    string internal seed;
    address internal deployer = makeAddr("deployer");
    address internal factoryOwner = makeAddr("factoryOwner");

    function setUp() public {
        forkBase();
        deployScript = new DeploySeavaultFactory();
        createX = deployScript.CREATE_X();
        seed = deployScript.DEFAULT_SALT_SEED();
    }

    function test_deploysAtPredictedAddress() public {
        address predicted = deployScript.predict(deployer, seed);

        address factory =
            _deploy(deployer, address(SEAPORT), OPENSEA_CONDUIT, factoryOwner, WETH, USDC);

        assertEq(factory, predicted);
        assertEq(SeavaultFactory(factory).seaport(), address(SEAPORT));
        assertEq(SeavaultFactory(factory).conduit(), OPENSEA_CONDUIT);
        assertEq(SeavaultFactory(factory).owner(), factoryOwner);
        assertEq(SeavaultFactory(factory).wNative(), WETH);
        assertEq(SeavaultFactory(factory).usdc(), USDC);
    }

    /// @dev The whole point of CREATE3: chain and constructor arguments do not move the address, so
    ///      each chain's Seaport, conduit and payment tokens can be baked in.
    function test_sameAddressAcrossChainsAndConstructorArguments() public {
        uint256 beforeDeploy = vm.snapshotState();
        address onBase =
            _deploy(deployer, address(SEAPORT), OPENSEA_CONDUIT, factoryOwner, WETH, USDC);

        vm.revertToState(beforeDeploy);
        vm.chainId(1);
        address otherWrapper = makeAddr("otherWrapper");
        address onEthereum = _deploy(
            deployer,
            address(0x5EA),
            address(0xc0ffee),
            makeAddr("otherOwner"),
            otherWrapper,
            address(0)
        );

        assertEq(onEthereum, onBase);
        assertEq(SeavaultFactory(onEthereum).wNative(), otherWrapper);
        assertEq(SeavaultFactory(onEthereum).usdc(), address(0));
    }

    function test_saltSeedChangesTheAddress() public view {
        assertTrue(deployScript.predict(deployer, seed) != deployScript.predict(deployer, "other"));
    }

    /// @dev Permissioned salt: another sender reusing our salt lands somewhere else, so the address
    ///      cannot be squatted on a chain we have not deployed to yet.
    function test_strangerCannotOccupyTheAddress() public {
        address predicted = deployScript.predict(deployer, seed);

        address squatted = _deploy(
            makeAddr("stranger"), address(SEAPORT), OPENSEA_CONDUIT, factoryOwner, WETH, USDC
        );

        assertTrue(squatted != predicted);
        assertEq(
            _deploy(deployer, address(SEAPORT), OPENSEA_CONDUIT, factoryOwner, WETH, USDC),
            predicted
        );
    }

    function test_saltEncodesDeployerAndDisablesChainProtection() public view {
        bytes32 salt = deployScript.saltFor(deployer, seed);

        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(bytes20(salt)), deployer);
        assertEq(uint8(salt[20]), 0);
    }

    /// @dev Salt and init code are resolved before the prank so that it lands on the deploy call.
    function _deploy(
        address from,
        address seaport,
        address conduit,
        address owner,
        address wNative,
        address usdc
    ) private returns (address) {
        bytes32 salt = deployScript.saltFor(deployer, seed);
        bytes memory initCode = deployScript.initCode(seaport, conduit, owner, wNative, usdc);

        vm.prank(from);
        return createX.deployCreate3(salt, initCode);
    }
}
