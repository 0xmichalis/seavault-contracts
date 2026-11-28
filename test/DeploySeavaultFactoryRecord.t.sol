// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeploySeavaultFactory} from "../script/DeploySeavaultFactory.s.sol";
import {SeavaultFactory} from "../src/SeavaultFactory.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";
import {MockSeaport} from "./mocks/MockSeaport.sol";

contract DeploymentRecorder is DeploySeavaultFactory {
    string public recordedJson;

    function recordJson(string memory broadcastJson, string memory saltSeed)
        external
        returns (string memory)
    {
        return _record(broadcastJson, saltSeed);
    }

    function _writeRecord(string memory json, address) internal override returns (string memory) {
        recordedJson = json;
        return "deployment.json";
    }
}

contract DeploySeavaultFactoryRecordTest is Test {
    DeploymentRecorder internal recorder;
    SeavaultFactory internal factory;
    address internal deployer = address(0xdE10);
    address internal initialOwner = address(0xad);
    address internal wNative = makeAddr("wNative");
    address internal usdc = makeAddr("usdc");
    bytes32 internal transactionHash = keccak256("deployment transaction");
    bytes32 internal deploymentBlockHash = keccak256("deployment block");
    string internal seed;
    string internal transactionJson;
    string internal broadcastJson;
    bytes32 internal salt;
    bytes internal creationCode;

    function setUp() public {
        vm.chainId(31_337);
        vm.roll(100);
        recorder = new DeploymentRecorder();
        seed = "seavault-factory-v3";
        address seaport = address(new MockSeaport());
        factory =
            new SeavaultFactory(seaport, recorder.OPENSEA_CONDUIT(), initialOwner, wNative, usdc);
        vm.etch(address(recorder.CREATE_X()), hex"00");
        vm.mockCall(
            address(recorder.CREATE_X()),
            abi.encodeCall(
                ICreateX.computeCreate3Address,
                (recorder.guardedSaltFor(deployer, seed), address(recorder.CREATE_X()))
            ),
            abi.encode(address(factory))
        );
        salt = recorder.saltFor(deployer, seed);
        creationCode =
            recorder.initCode(seaport, recorder.OPENSEA_CONDUIT(), initialOwner, wNative, usdc);
        transactionJson = string.concat(
            '{"from":"',
            vm.toString(deployer),
            '","to":"',
            vm.toString(address(recorder.CREATE_X())),
            '","input":"',
            vm.toString(abi.encodeCall(ICreateX.deployCreate3, (salt, creationCode))),
            '"}'
        );
        broadcastJson = broadcastWith(transactionJson, string.concat("[", receipt("0x1"), "]"));
        vm.setBlockhash(42, deploymentBlockHash);
    }

    function broadcastWith(string memory transaction, string memory receipts)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"chain":31337,"commit":"75a93d1","transactions":[{"hash":"',
            vm.toString(transactionHash),
            '","arguments":["',
            vm.toString(salt),
            '","',
            vm.toString(creationCode),
            '"],"transaction":',
            transaction,
            '}],"receipts":',
            receipts,
            "}"
        );
    }

    function receipt(string memory status) internal view returns (string memory) {
        return string.concat(
            '{"status":"',
            status,
            '","transactionHash":"',
            vm.toString(transactionHash),
            '","blockNumber":"0x2a","blockHash":"',
            vm.toString(deploymentBlockHash),
            '"}'
        );
    }

    function test_runRejectsEmptySaltSeed() public {
        vm.setEnv("FACTORY_SALT_SEED", "");
        vm.expectRevert(DeploySeavaultFactory.MissingFactorySaltSeed.selector);
        recorder.run();
    }

    function test_runRejectsLegacySaltSeed() public {
        vm.setEnv("FACTORY_SALT_SEED", "seavault-factory-v1");
        vm.expectRevert(DeploySeavaultFactory.LegacyFactorySaltSeed.selector);
        recorder.run();
    }

    function test_recordRejectsEmptySaltSeedBeforeReadingBroadcast() public {
        vm.setEnv("FACTORY_SALT_SEED", "");
        vm.expectRevert(DeploySeavaultFactory.MissingFactorySaltSeed.selector);
        recorder.record("no-broadcast.json");
    }

    function test_recordsConfirmedDeploymentAndCodeHashes() public {
        assertEq(recorder.recordJson(broadcastJson, seed), "deployment.json");
        string memory json = recorder.recordedJson();
        assertEq(vm.parseJsonUint(json, ".chainId"), 31_337);
        assertEq(vm.parseJsonUint(json, ".blockNumber"), 42);
        assertEq(vm.parseJsonBytes32(json, ".transactionHash"), transactionHash);
        assertEq(vm.parseJsonBytes32(json, ".blockHash"), deploymentBlockHash);
        assertEq(vm.parseJsonAddress(json, ".factory"), address(factory));
        assertEq(vm.parseJsonAddress(json, ".deployer"), deployer);
        assertEq(vm.parseJsonAddress(json, ".initialOwner"), initialOwner);
        assertEq(vm.parseJsonAddress(json, ".wNative"), wNative);
        assertEq(vm.parseJsonAddress(json, ".usdc"), usdc);
        assertEq(vm.parseJsonString(json, ".sourceCommit"), "75a93d1");
        assertEq(vm.parseJsonString(json, ".saltSeed"), seed);
        assertEq(vm.parseJsonBytes32(json, ".factoryRuntimeCodeHash"), address(factory).codehash);
        address implementation = address(factory.vaultImplementation());
        assertEq(vm.parseJsonAddress(json, ".vaultImplementation"), implementation);
        assertEq(vm.parseJsonBytes32(json, ".vaultImplementationCodeHash"), implementation.codehash);
    }

    function test_recordsConstructorOwnerAfterOwnershipChanges() public {
        vm.prank(initialOwner);
        factory.transferOwnership(deployer);
        vm.prank(deployer);
        factory.acceptOwnership();
        recorder.recordJson(broadcastJson, seed);
        assertEq(vm.parseJsonAddress(recorder.recordedJson(), ".initialOwner"), initialOwner);
    }

    function test_rejectsWrongChain() public {
        vm.chainId(1);
        vm.expectRevert("wrong broadcast chain");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsPendingDeployment() public {
        broadcastJson = broadcastWith(transactionJson, "[]");
        vm.expectRevert("deployment is not mined");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsRevertedDeployment() public {
        broadcastJson = broadcastWith(transactionJson, string.concat("[", receipt("0x0"), "]"));
        vm.expectRevert("deployment reverted");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsDeploymentAheadOfFork() public {
        vm.roll(41);
        vm.expectRevert("deployment is ahead of fork");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsNoncanonicalBlock() public {
        vm.setBlockhash(42, keccak256("different block"));
        vm.expectRevert("deployment block is not canonical");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsMissingConstructorArguments() public {
        creationCode = new bytes(5 * 32 - 1);
        broadcastJson = broadcastWith(transactionJson, string.concat("[", receipt("0x1"), "]"));
        vm.expectRevert("missing constructor arguments");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsDifferentSaltSeed() public {
        vm.expectRevert("wrong factory salt seed");
        recorder.recordJson(broadcastJson, "other version");
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsDifferentDeploymentBytecode() public {
        broadcastJson = broadcastWith(
            string.concat(
                '{"from":"',
                vm.toString(deployer),
                '","to":"',
                vm.toString(address(recorder.CREATE_X())),
                '","input":"0x1234"}'
            ),
            string.concat("[", receipt("0x1"), "]")
        );
        vm.expectRevert("deployment input does not match current build");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsMissingFactory() public {
        vm.etch(address(factory), hex"");
        vm.expectRevert("factory is not deployed");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsDifferentFactoryPaymentToken() public {
        vm.mockCall(
            address(factory), abi.encodeWithSelector(factory.usdc.selector), abi.encode(wNative)
        );
        vm.expectRevert("factory wiring does not match deployment");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }

    function test_rejectsDifferentVaultImplementation() public {
        vm.etch(address(factory.vaultImplementation()), hex"00fe");
        vm.expectRevert("vault implementation does not match current build");
        recorder.recordJson(broadcastJson, seed);
        assertEq(recorder.recordedJson(), "");
    }
}
