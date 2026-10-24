// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Settable subscription registry, so vault tests can flip a subscription on and off without
///         standing up a factory.
contract MockSubscriptionRegistry {
    bool public subscribed = true;
    bool public blocked;
    uint256 public price;
    uint256 public periodsBought;

    function syncVaultOwnership(address, address) external {}

    function set(bool subscribed_, uint256 price_) external {
        subscribed = subscribed_;
        price = price_;
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

    function priceFor(address) external view returns (uint256) {
        return price;
    }

    function extendSubscription(address, uint256 periods) external payable {
        require(msg.value == price * periods, "MockSubscriptionRegistry: wrong payment");
        periodsBought += periods;
        subscribed = true;
    }
}
