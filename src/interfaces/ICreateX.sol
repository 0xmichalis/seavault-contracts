// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The part of CreateX the deployment script uses.
/// @dev CreateX is deployed at 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed on every chain these
///      contracts target. Declared locally rather than pulled in as a dependency: only these two functions
///      are needed, and `DeployListoorVault.fork.t.sol` exercises them against the live deployment.
///      Upstream: https://github.com/pcaversaccio/createx (v1.0.0).
interface ICreateX {
    /// @param salt Guarded by CreateX before use; see `DeployListoorVault.saltFor`.
    function deployCreate3(bytes32 salt, bytes memory initCode)
        external
        payable
        returns (address newContract);

    /// @param salt The already-guarded salt, i.e. `DeployListoorVault.guardedSaltFor`.
    /// @param deployer The CreateX contract itself, which is what performs the CREATE2.
    function computeCreate3Address(bytes32 salt, address deployer)
        external
        pure
        returns (address computedAddress);
}
