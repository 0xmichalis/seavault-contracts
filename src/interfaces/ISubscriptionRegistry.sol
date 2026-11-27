// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subscription entitlement and block status for the managed keeper.
/// @custom:security-contact security@kazani.ch
/// @dev The keeper enforces these service controls offchain. Paid time can only grow.
interface ISubscriptionRegistry {
    /// @notice Whether the managed keeper should skip `vault`.
    function isBlocked(address vault) external view returns (bool);

    /// @notice Whether `vault` has premium subscription time or a zero price, regardless of blocking.
    function isSubscribed(address vault) external view returns (bool);

    /// @notice Price of one subscription period for `vault`, in wei. Zero means free.
    function priceFor(address vault) external view returns (uint256);

    /// @notice Buys `periods` further periods for `vault`, extending from whichever is later, the
    ///         current expiry or now. Callable by anyone; `msg.value` must be exact.
    function extendSubscription(address vault, uint256 periods) external payable;
}
