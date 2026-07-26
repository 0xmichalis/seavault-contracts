// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConsiderationInterface} from "seaport-types/src/interfaces/ConsiderationInterface.sol";

/// @notice Base for tests that need the real Seaport deployment. Skips itself when no RPC endpoint
///         is configured, so `forge test` stays green offline and in CI.
abstract contract BaseFork is Test {
    ConsiderationInterface internal constant SEAPORT =
        ConsiderationInterface(0x0000000000000068F116a894984e2DB1123eB395);
    address internal constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    bytes32 internal constant OPENSEA_CONDUIT_KEY =
        0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    uint256 internal constant BASE_FORK_BLOCK = 49_144_697;

    function forkBase() internal {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, BASE_FORK_BLOCK);
    }
}
