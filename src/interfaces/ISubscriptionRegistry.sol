// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Where a vault checks subscription entitlement and trading access, typically its factory.
/// @custom:security-contact security@kazani.ch
/// @dev A lapsed subscription blocks direct buys and automatic withdrawals; the keeper enforces
///      free-tier listing and offer limits offchain. The blocklist separately gates order validation,
///      direct buys and automatic withdrawals, including paid vaults. Owner withdrawals, cancels and
///      other policy remain available. Paid time can only grow.
interface ISubscriptionRegistry {
    /// @notice Whether `vault` is blocked from order validation, direct buys and automatic withdrawals.
    function isBlocked(address vault) external view returns (bool);

    /// @notice Whether `vault` has premium subscription time or a zero price, regardless of blocking.
    function isSubscribed(address vault) external view returns (bool);

    /// @notice Price of one subscription period for `vault`, in wei. Zero means free.
    function priceFor(address vault) external view returns (uint256);

    /// @notice Buys `periods` further periods for `vault`, extending from whichever is later, the
    ///         current expiry or now. Callable by anyone; `msg.value` must be exact.
    function extendSubscription(address vault, uint256 periods) external payable;
}
