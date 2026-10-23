// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Keeps current and incoming vault ownership discoverable by wallet address.
interface IVaultOwnershipRegistry {
    /// @notice Called by a registered vault after its owner or pending owner changes.
    function syncVaultOwnership(address previousOwner, address previousPendingOwner) external;
}
