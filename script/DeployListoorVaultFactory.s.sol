// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";

/// @notice Deploys `ListoorVaultFactory` through CreateX's CREATE3 factory, so every chain gets the
///         same factory address for a given (deployer, salt seed) pair even though each chain's
///         Seaport and conduit differ.
/// @dev CREATE3 derives the address from the salt alone, never from the init code. The salt is
///      encoded the way CreateX expects for a permissioned, chain-independent deploy: the first 20
///      bytes are the deployer (nobody else can take the address) and the 21st byte is zero (no
///      cross-chain redeploy protection, which would mix `block.chainid` into the salt).
///
///      The factory address has to match across chains, because vault addresses are derived from it.
///      Use the same deployer key and salt seed everywhere.
///
///      Deploy:
///        forge script script/DeployListoorVaultFactory.s.sol --rpc-url base --account deployer \
///        --broadcast --verify
///
///      Predict, without touching a key:
///        forge script script/DeployListoorVaultFactory.s.sol --sig "predict(address,string)" \
///        0xDEPLOYER listoor-vault-factory-v1 --rpc-url base
contract DeployListoorVaultFactory is Script {
    ICreateX public constant CREATE_X = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address public constant SEAPORT_V1_6 = 0x0000000000000068F116a894984e2DB1123eB395;
    address public constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    string public constant DEFAULT_SALT_SEED = "listoor-vault-factory-v1";

    function run() external returns (ListoorVaultFactory factory) {
        address seaport = vm.envOr("SEAPORT", SEAPORT_V1_6);
        address conduit = vm.envOr("CONDUIT", OPENSEA_CONDUIT);
        string memory saltSeed = vm.envOr("FACTORY_SALT_SEED", string(DEFAULT_SALT_SEED));
        address deployer = msg.sender;
        address predicted = predict(deployer, saltSeed);

        console2.log("chain id         ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("salt seed        ", saltSeed);
        console2.log("predicted factory", predicted);

        vm.startBroadcast();
        factory = ListoorVaultFactory(
            CREATE_X.deployCreate3(saltFor(deployer, saltSeed), initCode(seaport, conduit))
        );
        vm.stopBroadcast();

        // Guards against a broadcaster that differs from the address the salt was built for, which
        // would silently land the factory somewhere other than the shared cross-chain address.
        require(address(factory) == predicted, "factory address does not match prediction");
        console2.log("deployed factory ", address(factory));
    }

    /// @notice Address the factory will occupy on every chain for this deployer and salt seed.
    function predict(address deployer, string memory saltSeed) public view returns (address) {
        return CREATE_X.computeCreate3Address(guardedSaltFor(deployer, saltSeed), address(CREATE_X));
    }

    function initCode(address seaport, address conduit) public pure returns (bytes memory) {
        return
            abi.encodePacked(type(ListoorVaultFactory).creationCode, abi.encode(seaport, conduit));
    }

    function saltFor(address deployer, string memory saltSeed) public pure returns (bytes32) {
        // forge-lint: disable-start(unsafe-typecast)
        return bytes32(
            abi.encodePacked(bytes20(deployer), bytes1(0x00), bytes11(keccak256(bytes(saltSeed))))
        );
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev CreateX hashes the salt with the sender before using it; mirrored here to predict the
    ///      address without a call.
    function guardedSaltFor(address deployer, string memory saltSeed)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(bytes32(uint256(uint160(deployer))), saltFor(deployer, saltSeed))
        );
    }
}
