// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ListoorVault} from "./ListoorVault.sol";
import {ICreateX} from "./interfaces/ICreateX.sol";

/// @title ListoorVaultFactory
/// @notice Deploys `ListoorVault` instances and keeps a registry of them, so an owner can get a vault
///         in one transaction and the keeper can look the vault up on-chain instead of being configured
///         with an address per chain.
/// @dev Vaults are real deployments, not proxies: the vault keeps its immutable Seaport wiring and
///      its constructor-time domain-separator check. Deployment goes through CreateX's CREATE3, so a
///      vault's address depends only on its owner and salt — identical on every chain even though
///      the factory feeds each chain's own Seaport and conduit into the constructor.
///
///      The CreateX salt embeds this factory's address with redeploy protection off, which asks
///      CreateX for a permissioned, chain-independent deploy: no other caller can occupy a vault
///      address before its owner claims it, on this chain or any other.
contract ListoorVaultFactory {
    ICreateX public constant CREATE_X = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @notice Seaport deployment every vault from this factory signs orders for.
    address public immutable seaport;

    /// @notice Conduit every vault from this factory approves for settlement.
    address public immutable conduit;

    /// @notice Vault deployed for an owner under a given salt, zero if not created yet.
    mapping(address owner => mapping(bytes32 salt => address vault)) public vaultOf;

    /// @notice Whether an address is a vault this factory deployed.
    mapping(address vault => bool) public isVault;

    mapping(address owner => address[] vaults) private _vaults;

    event VaultCreated(
        address indexed owner, address indexed vault, bytes32 indexed salt, address keeper
    );

    error ZeroAddress();
    error VaultAlreadyExists(bytes32 salt);

    constructor(address seaport_, address conduit_) {
        if (seaport_ == address(0) || conduit_ == address(0)) revert ZeroAddress();
        seaport = seaport_;
        conduit = conduit_;
    }

    /// @notice Deploys a vault owned by the caller.
    /// @param salt Chosen by the caller; distinguishes multiple vaults with the same owner and fixes
    ///        the vault's address across chains.
    /// @param keeper Hot key authorized to sign orders for the vault.
    /// @dev Inputs are checked here rather than left to the vault's constructor, because CreateX
    ///      replaces a failed construction with its own opaque `FailedContractCreation`.
    function createVault(bytes32 salt, address keeper) external returns (ListoorVault vault) {
        if (keeper == address(0)) revert ZeroAddress();
        if (vaultOf[msg.sender][salt] != address(0)) revert VaultAlreadyExists(salt);

        vault = ListoorVault(
            payable(CREATE_X.deployCreate3(
                    _createXSalt(msg.sender, salt),
                    abi.encodePacked(
                        type(ListoorVault).creationCode,
                        abi.encode(seaport, conduit, msg.sender, keeper)
                    )
                ))
        );

        vaultOf[msg.sender][salt] = address(vault);
        isVault[address(vault)] = true;
        _vaults[msg.sender].push(address(vault));

        emit VaultCreated(msg.sender, address(vault), salt, keeper);
    }

    /// @notice Address a vault will occupy on every chain, before it is created.
    function predictVault(address owner, bytes32 salt) public view returns (address) {
        return
            CREATE_X.computeCreate3Address(
                _guardedSalt(_createXSalt(owner, salt)), address(CREATE_X)
            );
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaults[owner];
    }

    function vaultCount(address owner) external view returns (uint256) {
        return _vaults[owner].length;
    }

    /// @dev `bytes20(this) ++ 0x00 ++ owner-and-salt digest`: permissioned to this factory, with
    ///      CreateX's cross-chain redeploy protection deliberately switched off.
    function _createXSalt(address owner, bytes32 salt) private view returns (bytes32) {
        // forge-lint: disable-start(unsafe-typecast)
        return bytes32(
            abi.encodePacked(
                bytes20(address(this)), bytes1(0x00), bytes11(keccak256(abi.encode(owner, salt)))
            )
        );
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev Mirrors how CreateX hashes a permissioned salt with its caller, which is this factory.
    function _guardedSalt(bytes32 createXSalt) private view returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(uint160(address(this)))), createXSalt));
    }
}
