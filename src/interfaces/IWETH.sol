// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Wrapped-native-token surface used by the vault to move between the native asset it
///         receives from sales and the wrapped one it needs to bid with.
interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
