// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Where a vault checks that its keeper service is paid for, typically the factory that
///         created it.
/// @dev Read at validation time: a lapsed subscription stops the vault signing new orders and kills
///      outstanding ones Seaport has not already validated or partially filled, while leaving
///      withdrawals, cancels and policy untouched. Paid time can only be extended, never shortened,
///      so a paid window is guaranteed by code.
interface ISubscriptionRegistry {
    /// @notice Whether `vault` may sign orders right now. Always true where the price is zero.
    function isSubscribed(address vault) external view returns (bool);

    /// @notice Price of one subscription period for `vault`, in wei. Zero means free.
    function priceFor(address vault) external view returns (uint256);

    /// @notice Buys `periods` further periods for `vault`, extending from whichever is later, the
    ///         current expiry or now. Callable by anyone; `msg.value` must be exact.
    function extendSubscription(address vault, uint256 periods) external payable;
}
