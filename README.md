# listoor-contracts

Non-custodial Seaport trading accounts.
Owners deposit assets and set trading limits; a keeper signs orders and buys within those limits.
Only the owner can withdraw assets.

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

## Documentation

- [Architecture](docs/ARCHITECTURE.md): contracts, security model, deposits, discovery and signatures.
- [Deployment](docs/DEPLOYMENT.md): prediction, deployment and account configuration.

Keeper limits bound what a compromised key can trade. Tightening policy or a subscription lapse
cannot revoke orders Seaport already validated; cancel those orders or increment the counter.
See the architecture document for the full security model.
