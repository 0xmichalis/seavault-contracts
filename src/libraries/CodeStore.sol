// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title CodeStore
/// @custom:security-contact security@kazani.ch
/// @notice Keeps a blob as the runtime code of a contract of its own, so a contract can deploy init
///         code larger than it could carry in its own bytecode.
/// @dev The stored code opens with a STOP byte, so calling the store never executes the blob.
///      EIP-170 caps the store at 24,576 bytes of runtime code like any contract, so a blob may be
///      24,575 bytes at most: a contract's creation code reaches that before its runtime does.
library CodeStore {
    error StoreFailed();

    function write(bytes memory data) internal returns (address store) {
        // PUSH2 size, DUP1, PUSH1 10, PUSH0, CODECOPY, PUSH0, RETURN: returns everything after
        // these 10 bytes, which is STOP followed by `data`. EIP-170 keeps `size` far below 2^16.
        bytes memory initCode = abi.encodePacked(
            hex"61",
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16(data.length + 1),
            hex"80600a5f395ff3",
            hex"00",
            data
        );
        assembly ("memory-safe") {
            store := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (store == address(0)) revert StoreFailed();
    }

    function read(address store) internal view returns (bytes memory data) {
        uint256 size = store.code.length - 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(store, add(data, 0x20), 1, size)
        }
    }
}
