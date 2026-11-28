// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Seavault} from "../src/Seavault.sol";
import {SeavaultFactory} from "../src/SeavaultFactory.sol";
import {MockSeaport} from "./mocks/MockSeaport.sol";

/// @notice What the factory carries besides its registry. Creating a vault needs CreateX, so that
///         is covered on a fork.
contract SeavaultFactoryTest is Test {
    function test_deploysSharedImplementationWithFactoryWiring() public {
        address seaport = address(new MockSeaport());
        address conduit = makeAddr("conduit");
        address wNative = makeAddr("wNative");
        address usdc = makeAddr("usdc");
        SeavaultFactory factory =
            new SeavaultFactory(seaport, conduit, makeAddr("owner"), wNative, usdc);

        Seavault implementation = factory.vaultImplementation();
        assertEq(address(implementation.seaport()), seaport);
        assertEq(implementation.conduit(), conduit);
        assertEq(address(implementation.factory()), address(factory));
        assertEq(implementation.owner(), address(implementation));
        assertTrue(implementation.paymentTokenAllowed(wNative));
        assertTrue(implementation.paymentTokenAllowed(usdc));
        assertLe(address(implementation).code.length, 24_576);
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
