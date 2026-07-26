// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";

/// @notice Creates a vault through the factory, owned by the broadcasting key.
/// @dev The vault lands on the same address on every chain for a given (owner, salt), so run this
///      with the same owner and salt per chain.
///
///      Create:
///        FACTORY=0x… KEEPER=0x… VAULT_SALT=primary \
///        forge script script/CreateVault.s.sol --rpc-url base --account cold --broadcast
///
///      Look up an existing vault:
///        forge script script/CreateVault.s.sol --sig "predict(address,address,string)" \
///        0xFACTORY 0xOWNER primary --rpc-url base
contract CreateVault is Script {
    string public constant DEFAULT_SALT = "primary";

    function run() external returns (ListoorVault vault) {
        ListoorVaultFactory factory = ListoorVaultFactory(vm.envAddress("FACTORY"));
        address keeper = vm.envAddress("KEEPER");
        bytes32 salt = keccak256(bytes(vm.envOr("VAULT_SALT", string(DEFAULT_SALT))));
        address owner = msg.sender;

        console2.log("chain id       ", block.chainid);
        console2.log("owner          ", owner);
        console2.log("keeper     ", keeper);
        console2.log("predicted vault", factory.predictVault(owner, salt));

        vm.startBroadcast();
        vault = factory.createVault(salt, keeper);
        vm.stopBroadcast();

        console2.log("created vault  ", address(vault));
    }

    /// @notice Vault address for an owner and salt, whether or not it exists yet.
    function predict(address factory, address owner, string memory salt)
        public
        view
        returns (address)
    {
        return ListoorVaultFactory(factory).predictVault(owner, keccak256(bytes(salt)));
    }
}
