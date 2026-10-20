// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ListoorVault} from "./ListoorVault.sol";
import {ICreateX} from "./interfaces/ICreateX.sol";
import {ISubscriptionRegistry} from "./interfaces/ISubscriptionRegistry.sol";

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
///
///      The factory doubles as the subscription registry its vaults check before signing. Vaults are
///      created with a trial period; after that, someone has to buy periods for them or the vault
///      stops signing. Paid time can only be extended, never revoked, so a paid window is guaranteed
///      by code even if the factory owner turns hostile — and a lapse never touches custody, since
///      the vault owner keeps withdrawals, cancels and policy throughout.
///
///      A per-vault price override prices individual vaults off-schedule, zero making one free.
contract ListoorVaultFactory is Ownable2Step, ISubscriptionRegistry {
    ICreateX public constant CREATE_X = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @notice Length of one subscription period.
    uint256 public constant SUBSCRIPTION_PERIOD = 30 days;

    uint256 private constant DEFAULT_TRIAL_PERIOD = 30 days;

    /// @notice Seaport deployment every vault from this factory signs orders for.
    address public immutable seaport;

    /// @notice Conduit every vault from this factory approves for settlement.
    address public immutable conduit;

    /// @notice Vault deployed for an owner under a given salt, zero if not created yet.
    mapping(address owner => mapping(bytes32 salt => address vault)) public vaultOf;

    /// @notice Whether an address is a vault this factory deployed.
    mapping(address vault => bool) public isVault;

    /// @notice Where subscription payments are forwarded.
    address public subscriptionRecipient;

    /// @notice Price of one subscription period, in wei. Zero makes every vault free.
    uint256 public subscriptionPrice;

    /// @notice Paid-for time granted to a vault when it is created.
    uint256 public trialPeriod;

    /// @notice Timestamp each vault's paid time runs out at.
    mapping(address vault => uint256 expiry) public paidThrough;

    /// @notice Off-schedule prices for individual vaults, e.g. zero for partner vaults.
    mapping(address vault => PriceOverride) public priceOverrides;

    mapping(address owner => address[] vaults) private _vaults;

    struct PriceOverride {
        bool enabled;
        uint256 price;
    }

    event VaultCreated(
        address indexed owner, address indexed vault, bytes32 indexed salt, address keeper
    );
    event SubscriptionUpdated(address recipient, uint256 price);
    event PriceOverrideUpdated(address indexed vault, bool enabled, uint256 price);
    event TrialPeriodUpdated(uint256 trialPeriod);
    event SubscriptionExtended(
        address indexed vault, address indexed payer, uint256 periods, uint256 paidThrough
    );

    error ZeroAddress();
    error VaultAlreadyExists(bytes32 salt);
    error NotAVault(address vault);
    error SubscriptionNotRequired(address vault);
    error NoPeriods();
    error IncorrectPayment(uint256 expected, uint256 provided);
    error OwnershipCannotBeRenounced();

    /// @dev The subscription ships free, so the factory is usable the moment it is deployed; the
    ///      owner sets a price when the service starts charging.
    constructor(address seaport_, address conduit_, address owner_) Ownable(owner_) {
        if (seaport_ == address(0) || conduit_ == address(0)) revert ZeroAddress();
        seaport = seaport_;
        conduit = conduit_;
        subscriptionRecipient = owner_;
        trialPeriod = DEFAULT_TRIAL_PERIOD;
        emit SubscriptionUpdated(owner_, 0);
        emit TrialPeriodUpdated(DEFAULT_TRIAL_PERIOD);
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
                        abi.encode(seaport, conduit, msg.sender, keeper, address(this))
                    )
                ))
        );

        vaultOf[msg.sender][salt] = address(vault);
        isVault[address(vault)] = true;
        _vaults[msg.sender].push(address(vault));
        paidThrough[address(vault)] = block.timestamp + trialPeriod;

        emit VaultCreated(msg.sender, address(vault), salt, keeper);
        emit SubscriptionExtended(address(vault), msg.sender, 0, block.timestamp + trialPeriod);
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

    /*//////////////////////////////////////////////////////////////
                              SUBSCRIPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISubscriptionRegistry
    function isSubscribed(address vault) public view returns (bool) {
        return priceFor(vault) == 0 || paidThrough[vault] >= block.timestamp;
    }

    /// @inheritdoc ISubscriptionRegistry
    function priceFor(address vault) public view returns (uint256) {
        PriceOverride memory priceOverride = priceOverrides[vault];
        return priceOverride.enabled ? priceOverride.price : subscriptionPrice;
    }

    /// @inheritdoc ISubscriptionRegistry
    /// @dev Extends from the later of the current expiry and now, so a lapsed vault buys time from
    ///      the moment it pays rather than backdating it. Anyone may pay for any vault.
    function extendSubscription(address vault, uint256 periods) external payable {
        if (!isVault[vault]) revert NotAVault(vault);
        if (periods == 0) revert NoPeriods();

        uint256 price = priceFor(vault);
        if (price == 0) revert SubscriptionNotRequired(vault);

        uint256 expected = price * periods;
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);

        uint256 expiry =
            Math.max(paidThrough[vault], block.timestamp) + periods * SUBSCRIPTION_PERIOD;
        paidThrough[vault] = expiry;

        Address.sendValue(payable(subscriptionRecipient), msg.value);
        emit SubscriptionExtended(vault, msg.sender, periods, expiry);
    }

    /// @notice Sets where payments go and what a period costs. Zero price makes every vault free.
    /// @dev Cannot shorten anything already paid for; a new price only applies to future purchases.
    function setSubscription(address recipient, uint256 price) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        subscriptionRecipient = recipient;
        subscriptionPrice = price;
        emit SubscriptionUpdated(recipient, price);
    }

    /// @notice Prices a vault off-schedule, or puts it back on the default price.
    function setPriceOverride(address vault, bool enabled, uint256 price) external onlyOwner {
        priceOverrides[vault] = PriceOverride(enabled, price);
        emit PriceOverrideUpdated(vault, enabled, price);
    }

    /// @notice Sets the paid-for time new vaults are created with.
    function setTrialPeriod(uint256 newTrialPeriod) external onlyOwner {
        trialPeriod = newTrialPeriod;
        emit TrialPeriodUpdated(newTrialPeriod);
    }

    /// @dev Disabled: renouncing would freeze the price and the recipient for good, so a recipient
    ///      that stops accepting payments would lapse every priced vault permanently.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
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
