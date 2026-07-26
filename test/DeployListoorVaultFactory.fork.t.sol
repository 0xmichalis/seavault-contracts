// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployListoorVaultFactory} from "../script/DeployListoorVaultFactory.s.sol";
import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";
import {BaseFork} from "./helpers/BaseFork.sol";

/// @notice Factory deployment determinism against the real CreateX factory. Vault addresses derive
///         from the factory address, so this is what makes them match across chains.
contract DeployListoorVaultFactoryForkTest is BaseFork {
    string internal constant SEED = "listoor-vault-factory-test";

    DeployListoorVaultFactory internal deployScript;
    ICreateX internal createX;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        forkBase();
        deployScript = new DeployListoorVaultFactory();
        createX = deployScript.CREATE_X();
    }

    function test_deploysAtPredictedAddress() public {
        address predicted = deployScript.predict(deployer, SEED);

        address factory = _deploy(deployer, address(SEAPORT), OPENSEA_CONDUIT);

        assertEq(factory, predicted);
        assertEq(ListoorVaultFactory(factory).seaport(), address(SEAPORT));
        assertEq(ListoorVaultFactory(factory).conduit(), OPENSEA_CONDUIT);
    }

    /// @dev The whole point of CREATE3: chain and constructor arguments do not move the address, so
    ///      each chain's own Seaport and conduit can be baked in.
    function test_sameAddressAcrossChainsAndConstructorArguments() public {
        uint256 beforeDeploy = vm.snapshotState();
        address onBase = _deploy(deployer, address(SEAPORT), OPENSEA_CONDUIT);

        vm.revertToState(beforeDeploy);
        vm.chainId(1);
        address onEthereum = _deploy(deployer, address(0x5EA), address(0xc0ffee));

        assertEq(onEthereum, onBase);
    }

    function test_saltSeedChangesTheAddress() public view {
        assertTrue(deployScript.predict(deployer, SEED) != deployScript.predict(deployer, "other"));
    }

    /// @dev Permissioned salt: another sender reusing our salt lands somewhere else, so the address
    ///      cannot be squatted on a chain we have not deployed to yet.
    function test_strangerCannotOccupyTheAddress() public {
        address predicted = deployScript.predict(deployer, SEED);

        address squatted = _deploy(makeAddr("stranger"), address(SEAPORT), OPENSEA_CONDUIT);

        assertTrue(squatted != predicted);
        assertEq(_deploy(deployer, address(SEAPORT), OPENSEA_CONDUIT), predicted);
    }

    function test_saltEncodesDeployerAndDisablesChainProtection() public view {
        bytes32 salt = deployScript.saltFor(deployer, SEED);

        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(bytes20(salt)), deployer);
        assertEq(uint8(salt[20]), 0);
    }

    /// @dev Salt and init code are resolved before the prank so that it lands on the deploy call.
    function _deploy(address from, address seaport, address conduit) private returns (address) {
        bytes32 salt = deployScript.saltFor(deployer, SEED);
        bytes memory initCode = deployScript.initCode(seaport, conduit);

        vm.prank(from);
        return createX.deployCreate3(salt, initCode);
    }
}
