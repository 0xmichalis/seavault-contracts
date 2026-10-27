# seavault-contracts

Non-custodial Seaport trading accounts.
Owners deposit assets and set trading limits; a keeper signs orders and buys within those limits.
Owners can always withdraw assets. Unblocked subscribers can opt into keeper-triggered ETH/ERC20
withdrawals that send funds only to the current owner.

- EIP-1271 order validation with listing floors, offer ceilings and spending allowances.
- Deterministic factory and vault deployment through CreateX.
- Automatic account discovery, two-step ownership transfers and subscriptions.
- First ETH deposit and account creation in one transaction.

## Development

Requires [Foundry](https://getfoundry.sh). Dependencies are pinned with Soldeer.

```sh
forge soldeer install
forge build
forge test
forge fmt --check
forge lint
```

Run the full suite against a Base fork before shipping changes:

```sh
BASE_RPC_URL=https://mainnet.base.org forge test
```

Fork tests skip without `BASE_RPC_URL`. They exercise the actual Seaport, conduit and CreateX
contracts. Dependency changes must update both `[dependencies]` and the manual remappings in
`foundry.toml`.

The adversarial suite in `test/ListoorVaultInvariant.fork.t.sol` runs stateful sequences against real
Seaport, conduit and WETH deployments with test ERC721/ERC1155 collections. It checks portfolio value,
asset conservation, spending caps and custody while a hostile keeper/taker trades, reenters during
settlement and replays orders across policy changes, cancellation and keeper rotation. Every sequence
ends by withdrawing the remaining assets as the owner, including blocked and lapsed states.
The portfolio oracle assigns each NFT unit a fixed test value of 1 ETH; generated owner policies
keep effective floors at least that value and ceilings at most that value. It does not model market
prices or compromise of the external settlement contracts. Campaign settings live in `foundry.toml`.

## Documentation

- [Architecture](docs/ARCHITECTURE.md): contracts, security model, deposits, discovery and signatures.
- [Deployment](docs/DEPLOYMENT.md): prediction, deployment and account configuration.

Keeper limits bound what a compromised key can trade. Tightening policy cannot revoke orders
Seaport already validated; cancel those orders or increment the counter. Free-tier listing and
offer quotas are enforced by the keeper; direct buys require an active subscription.
The factory owner can block order validation, direct buys and automatic withdrawals for individual
vaults, including paid ones. Manual owner withdrawals and cancellations remain available.
See the architecture document for the full security model.
