// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Factory service flags and ownership hook for vault unit tests.
contract MockSubscriptionRegistry {
    bool public subscribed = true;
    bool public blocked;

    function syncVaultOwnership(address, address) external {}

    function set(bool subscribed_) external {
        subscribed = subscribed_;
    }

    function setBlocked(bool blocked_) external {
        blocked = blocked_;
    }

    function isBlocked(address) external view returns (bool) {
        return blocked;
    }

    function isSubscribed(address) external view returns (bool) {
        return subscribed;
    }
}
