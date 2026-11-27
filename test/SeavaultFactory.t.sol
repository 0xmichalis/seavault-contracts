// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Seavault} from "../src/Seavault.sol";
import {SeavaultFactory} from "../src/SeavaultFactory.sol";
import {CodeStore} from "../src/libraries/CodeStore.sol";

/// @notice What the factory carries besides its registry. Creating a vault needs CreateX, so that
///         is covered on a fork.
contract SeavaultFactoryTest is Test {
    function test_keepsTheVaultCreationCodeOutsideItsOwnBytecode() public {
        SeavaultFactory factory = new SeavaultFactory(
            makeAddr("seaport"),
            makeAddr("conduit"),
            makeAddr("owner"),
            makeAddr("wNative"),
            address(0)
        );

        assertEq(CodeStore.read(factory.vaultCodeStore()), type(Seavault).creationCode);
        assertLt(address(factory).code.length, type(Seavault).creationCode.length);
    }

    /// @dev The store is a contract like any other: EIP-170 caps it at 24,576 bytes of runtime code,
    ///      one of which is its leading STOP byte.
    function test_vaultCreationCodeFitsTheCodeStore() public pure {
        assertLe(type(Seavault).creationCode.length, 24_575);
    }

    function test_rejectsInvalidPaymentTokens() public {
        address seaport = makeAddr("seaport");
        address conduit = makeAddr("conduit");
        address owner = makeAddr("owner");
        address usdc = makeAddr("usdc");

        vm.expectRevert(SeavaultFactory.ZeroAddress.selector);
        new SeavaultFactory(seaport, conduit, owner, address(0), usdc);

        vm.expectRevert(
            abi.encodeWithSelector(SeavaultFactory.DuplicatePaymentToken.selector, usdc)
        );
        new SeavaultFactory(seaport, conduit, owner, usdc, usdc);
    }
}
