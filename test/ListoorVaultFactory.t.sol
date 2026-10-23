// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ListoorVault} from "../src/ListoorVault.sol";
import {ListoorVaultFactory} from "../src/ListoorVaultFactory.sol";
import {CodeStore} from "../src/libraries/CodeStore.sol";

/// @notice What the factory carries besides its registry. Creating a vault needs CreateX, so that
///         is covered on a fork.
contract ListoorVaultFactoryTest is Test {
    function test_keepsTheVaultCreationCodeOutsideItsOwnBytecode() public {
        ListoorVaultFactory factory =
            new ListoorVaultFactory(makeAddr("seaport"), makeAddr("conduit"), makeAddr("owner"));

        assertEq(CodeStore.read(factory.vaultCodeStore()), type(ListoorVault).creationCode);
        assertLt(address(factory).code.length, type(ListoorVault).creationCode.length);
    }
}
