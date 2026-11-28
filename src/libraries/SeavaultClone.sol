// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Creation code for a fixed-target Seavault clone.
library SeavaultClone {
    function initCode(address implementation) internal pure returns (bytes memory) {
        // The first 10 bytes copy and return the 52-byte runtime. Its empty-calldata branch jumps
        // to 0x32 and stops, preserving the 2,300-gas ETH receive path even with a cold target.
        // Other calls use the ERC-1167 runtime, with its success jump moved to 0x30. It delegates
        // in the vault's context and returns or reverts with the exact implementation output.
        return abi.encodePacked(
            hex"3d603480600a3d3981f3",
            hex"3615603257",
            hex"363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91603057fd5bf3",
            hex"5b00"
        );
    }
}
