// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Seavault} from "../src/Seavault.sol";
import {SeavaultFactory} from "../src/SeavaultFactory.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";

/// @notice Deploys `SeavaultFactory` through CreateX's CREATE3 factory, so every chain gets the
///         same factory address for a given (deployer, salt seed) pair even though each chain's
///         Seaport, conduit and payment tokens can differ.
/// @dev CREATE3 derives the address from the salt alone, never from the init code. The salt is
///      encoded the way CreateX expects for a permissioned, chain-independent deploy: the first 20
///      bytes are the deployer (nobody else can take the address) and the 21st byte is zero (no
///      cross-chain redeploy protection, which would mix `block.chainid` into the salt).
///
///      The factory address has to match across chains, because vault addresses are derived from it.
///      Use the same deployer key and salt seed everywhere. `FACTORY_OWNER` (default: the deployer)
///      becomes the fee admin and the initial fee recipient.
///
///      Deploy:
///        FACTORY_SALT_SEED=seavault-factory-v2 \
///        W_NATIVE=0x4200000000000000000000000000000000000006 \
///        USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
///        forge script script/DeploySeavaultFactory.s.sol --rpc-url base --account deployer \
///        --broadcast --verify
///
///      Predict, without touching a key:
///        forge script script/DeploySeavaultFactory.s.sol --sig "predict(address,string)" \
///        0xDEPLOYER seavault-factory-v2 --rpc-url base
contract DeploySeavaultFactory is Script {
    ICreateX public constant CREATE_X = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address public constant SEAPORT_V1_6 = 0x0000000000000068F116a894984e2DB1123eB395;
    address public constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    bytes32 private constant LEGACY_FACTORY_SALT_SEED_HASH = keccak256("seavault-factory-v1");
    uint256 private constant CONSTRUCTOR_ARGS_LENGTH = 5 * 32;

    struct DeploymentRecord {
        bytes32 transactionHash;
        bytes32 blockHash;
        uint256 blockNumber;
        address deployer;
        address initialOwner;
        address seaport;
        address conduit;
        address wNative;
        address usdc;
        SeavaultFactory factory;
        string sourceCommit;
        string saltSeed;
    }

    error MissingFactorySaltSeed();
    error LegacyFactorySaltSeed();

    function run() external returns (SeavaultFactory factory) {
        string memory saltSeed = _requiredSaltSeed();
        if (keccak256(bytes(saltSeed)) == LEGACY_FACTORY_SALT_SEED_HASH) {
            revert LegacyFactorySaltSeed();
        }
        address seaport = vm.envOr("SEAPORT", SEAPORT_V1_6);
        address conduit = vm.envOr("CONDUIT", OPENSEA_CONDUIT);
        address owner = vm.envOr("FACTORY_OWNER", msg.sender);
        address wNative = vm.envAddress("W_NATIVE");
        address usdc = vm.envOr("USDC", address(0));
        address deployer = msg.sender;
        address predicted = predict(deployer, saltSeed);

        console2.log("chain id         ", block.chainid);
        console2.log("deployer         ", deployer);
        console2.log("factory owner    ", owner);
        console2.log("wrapped native   ", wNative);
        console2.log("USDC             ", usdc);
        console2.log("salt seed        ", saltSeed);
        console2.log("predicted factory", predicted);

        vm.startBroadcast();
        factory = SeavaultFactory(
            CREATE_X.deployCreate3(
                saltFor(deployer, saltSeed), initCode(seaport, conduit, owner, wNative, usdc)
            )
        );
        vm.stopBroadcast();

        // Guards against a broadcaster that differs from the address the salt was built for, which
        // would silently land the factory somewhere other than the shared cross-chain address.
        require(address(factory) == predicted, "factory address does not match prediction");
        console2.log("deployed factory ", address(factory));
    }

    /// @notice Records a confirmed deployment from this chain's latest broadcast, without a wallet.
    /// @dev Run separately after broadcasting: `run` executes before transactions have been mined.
    function record() external returns (string memory) {
        return record(
            string.concat(
                vm.projectRoot(),
                "/broadcast/DeploySeavaultFactory.s.sol/",
                vm.toString(block.chainid),
                "/run-latest.json"
            )
        );
    }

    /// @notice Records an earlier deployment from a saved broadcast file.
    function record(string memory broadcastPath) public returns (string memory) {
        string memory saltSeed = _requiredSaltSeed();
        return _record(vm.readFile(broadcastPath), saltSeed);
    }

    function _requiredSaltSeed() internal view returns (string memory seed) {
        seed = vm.envOr("FACTORY_SALT_SEED", string(""));
        if (bytes(seed).length == 0) revert MissingFactorySaltSeed();
    }

    function _record(string memory broadcastJson, string memory saltSeed)
        internal
        returns (string memory path)
    {
        require(vm.parseJsonUint(broadcastJson, ".chain") == block.chainid, "wrong broadcast chain");
        DeploymentRecord memory deployment;
        deployment.transactionHash = vm.parseJsonBytes32(broadcastJson, ".transactions[0].hash");
        require(
            vm.keyExistsJson(broadcastJson, ".receipts[0].transactionHash"),
            "deployment is not mined"
        );
        require(
            vm.parseUint(vm.parseJsonString(broadcastJson, ".receipts[0].status")) == 1,
            "deployment reverted"
        );
        require(
            vm.parseJsonBytes32(broadcastJson, ".receipts[0].transactionHash")
                == deployment.transactionHash,
            "wrong deployment receipt"
        );
        deployment.blockNumber =
            vm.parseUint(vm.parseJsonString(broadcastJson, ".receipts[0].blockNumber"));
        require(deployment.blockNumber <= block.number, "deployment is ahead of fork");
        deployment.blockHash = vm.parseJsonBytes32(broadcastJson, ".receipts[0].blockHash");
        bytes32 canonicalBlock = blockhash(deployment.blockNumber);
        require(
            canonicalBlock == bytes32(0) || canonicalBlock == deployment.blockHash,
            "deployment block is not canonical"
        );

        require(
            vm.parseJsonAddress(broadcastJson, ".transactions[0].transaction.to")
                == address(CREATE_X),
            "wrong deployment target"
        );
        deployment.deployer =
            vm.parseJsonAddress(broadcastJson, ".transactions[0].transaction.from");
        deployment.saltSeed = saltSeed;
        bytes32 salt = vm.parseJsonBytes32(broadcastJson, ".transactions[0].arguments[0]");
        require(
            salt == saltFor(deployment.deployer, deployment.saltSeed), "wrong factory salt seed"
        );

        bytes memory creationCode =
            vm.parseJsonBytes(broadcastJson, ".transactions[0].arguments[1]");
        require(creationCode.length >= CONSTRUCTOR_ARGS_LENGTH, "missing constructor arguments");
        bytes memory constructorArgs = new bytes(CONSTRUCTOR_ARGS_LENGTH);
        uint256 argsStart = creationCode.length - CONSTRUCTOR_ARGS_LENGTH;
        for (uint256 i; i < CONSTRUCTOR_ARGS_LENGTH; ++i) {
            constructorArgs[i] = creationCode[argsStart + i];
        }
        (
            deployment.seaport,
            deployment.conduit,
            deployment.initialOwner,
            deployment.wNative,
            deployment.usdc
        ) = abi.decode(constructorArgs, (address, address, address, address, address));
        require(
            keccak256(vm.parseJsonBytes(broadcastJson, ".transactions[0].transaction.input"))
                == keccak256(
                    abi.encodeCall(
                        CREATE_X.deployCreate3,
                        (
                            salt,
                            initCode(
                                deployment.seaport,
                                deployment.conduit,
                                deployment.initialOwner,
                                deployment.wNative,
                                deployment.usdc
                            )
                        )
                    )
                ),
            "deployment input does not match current build"
        );
        deployment.factory = SeavaultFactory(predict(deployment.deployer, deployment.saltSeed));
        require(address(deployment.factory).code.length != 0, "factory is not deployed");
        require(
            deployment.factory.seaport() == deployment.seaport
                && deployment.factory.conduit() == deployment.conduit
                && deployment.factory.wNative() == deployment.wNative
                && deployment.factory.usdc() == deployment.usdc,
            "factory wiring does not match deployment"
        );
        require(
            deployment.factory.vaultCodeStore().codehash
                == keccak256(abi.encodePacked(bytes1(0x00), type(Seavault).creationCode)),
            "vault code store does not match current build"
        );
        deployment.sourceCommit = vm.parseJsonString(broadcastJson, ".commit");

        string memory object = "factoryDeployment";
        vm.serializeJson(object, "{}");
        vm.serializeUint(object, "chainId", block.chainid);
        vm.serializeAddress(object, "factory", address(deployment.factory));
        vm.serializeBytes32(object, "transactionHash", deployment.transactionHash);
        vm.serializeUint(object, "blockNumber", deployment.blockNumber);
        vm.serializeBytes32(object, "blockHash", deployment.blockHash);
        vm.serializeString(object, "sourceCommit", deployment.sourceCommit);
        vm.serializeAddress(object, "deployer", deployment.deployer);
        vm.serializeAddress(object, "initialOwner", deployment.initialOwner);
        vm.serializeString(object, "saltSeed", deployment.saltSeed);
        vm.serializeAddress(object, "createX", address(CREATE_X));
        vm.serializeAddress(object, "seaport", deployment.seaport);
        vm.serializeAddress(object, "conduit", deployment.conduit);
        vm.serializeAddress(object, "wNative", deployment.wNative);
        vm.serializeAddress(object, "usdc", deployment.usdc);
        vm.serializeAddress(object, "vaultCodeStore", deployment.factory.vaultCodeStore());
        vm.serializeBytes32(object, "factoryRuntimeCodeHash", address(deployment.factory).codehash);
        string memory json = vm.serializeBytes32(
            object, "vaultCodeStoreHash", deployment.factory.vaultCodeStore().codehash
        );
        return _writeRecord(json, address(deployment.factory));
    }

    function _writeRecord(string memory json, address factory)
        internal
        virtual
        returns (string memory path)
    {
        string memory directory =
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid));
        vm.createDir(directory, true);
        path = string.concat(directory, "/", vm.toString(factory), ".json");
        vm.writeJson(json, path);
        console2.log("deployment record", path);
    }

    /// @notice Address the factory will occupy on every chain for this deployer and salt seed.
    function predict(address deployer, string memory saltSeed) public view returns (address) {
        return CREATE_X.computeCreate3Address(guardedSaltFor(deployer, saltSeed), address(CREATE_X));
    }

    function initCode(
        address seaport,
        address conduit,
        address owner,
        address wNative,
        address usdc
    ) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(SeavaultFactory).creationCode, abi.encode(seaport, conduit, owner, wNative, usdc)
        );
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
