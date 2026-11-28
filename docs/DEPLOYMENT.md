# Deployment

Both the factory and the vaults it creates go through [CreateX](https://github.com/pcaversaccio/createx)
at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`, which is deployed on every chain these contracts
target (ethereum, base, arbitrum, optimism, matic, zora, shape). With CREATE3 the address depends on the salt
alone, never on the init code, so **the same address is used on every chain even though constructor
arguments differ**. The factory deploys one implementation with each chain's Seaport, conduit,
wrapped native token and USDC address fixed in its code. It creates fixed-target clones and sets
each vault's owner and keeper in the creation transaction. Each clone holds its own assets and
policy and accepts ETH with empty calldata, including stipend-limited transfers.

Both salts are `bytes20(sender) ++ 0x00 ++ bytes11(digest)`, which asks CreateX for a permissioned,
chain-independent deploy: only that sender can use the salt (nobody can squat an address on a chain
you have not deployed to yet), and `block.chainid` is kept out of it. For the factory the sender is
the deployer key and the digest comes from the salt seed; for a vault the sender is the factory and
the digest covers `(owner, salt)`.

Because vault addresses derive from the factory's address, **deploy the factory with the same key and
salt seed on every chain** — the script aborts if the broadcaster does not match the salt.

```sh
# 1. Predict the factory address; no key needed, and any chain gives the same answer
forge script script/DeploySeavaultFactory.s.sol --sig "predict(address,string)" \
  0xDEPLOYER seavault-factory-v3 --rpc-url base

# 2. Deploy the factory, per chain. FACTORY_OWNER (default: the deployer) becomes the fee
#    admin and initial fee recipient
FACTORY_SALT_SEED=seavault-factory-v3 \
  W_NATIVE=0x4200000000000000000000000000000000000006 \
  USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  forge script script/DeploySeavaultFactory.s.sol --rpc-url base --account deployer \
    --broadcast --verify

# 3. Create a vault, per chain. Owner is the broadcasting key
FACTORY=0xFACTORY KEEPER=0xKEEPER VAULT_SALT=primary \
  forge script script/CreateVault.s.sol --rpc-url base --account cold --broadcast

# Look up an existing vault at any time
cast call 0xFACTORY "vaultOf(address,bytes32)(address)" 0xOWNER $(cast keccak primary) \
  --rpc-url base
```

`SEAPORT` and `CONDUIT` default to Seaport 1.6 (`0x0000…eB395`) and OpenSea's conduit
(`0x1E00…3c71`). Override them per chain if OpenSea points elsewhere. Set `W_NATIVE` to
the chain's canonical wrapped native token. Set `USDC` to the chain's
[Circle-issued USDC address](https://developers.circle.com/stablecoins/usdc-contract-addresses)
where one exists. On a chain without Circle-issued USDC, leave `USDC` unset so it defaults to
zero.

Set `FACTORY_SALT_SEED` explicitly for deployment. Use `seavault-factory-v3` for the clone factory.
The script rejects the reserved `seavault-factory-v1` seed.
A new factory seed yields a fresh factory and a fresh set of vault addresses, which is how you
roll out a new vault version. A new vault salt can create a replacement after the owner
transfers their current vault away.
A wallet can own only one vault per factory per chain, including vaults received through ownership transfers.

`--verify` uses the `[etherscan]` config and a single `ETHERSCAN_API_KEY`. Zora and Shape are not on
Etherscan; verify those with `--verifier blockscout --verifier-url <explorer>/api`.

`--account` reads an encrypted keystore from disk. To keep keys off the filesystem altogether, use
a hardware wallet (`--ledger`, `--trezor`) or `--browser`: forge serves a page on
`localhost:9545`, you connect a browser wallet, and each transaction waits there for your
signature. Forge connects before it simulates and takes the wallet's address as the sender, so the
salt is built for that wallet. The page does not switch networks for you: switch the wallet to the
target chain before pressing "Confirm Connection", because forge records the chain at that point
and refuses to send if it differs from the `--rpc-url` chain.

For a throwaway deployment, such as an end-to-end keeper test, give the factory a salt seed of its
own. Reusing the production seed with the production deployer would occupy the production address
on that chain for good.

```sh
FACTORY_SALT_SEED=seavault-factory-e2e-1 \
  W_NATIVE=0x4200000000000000000000000000000000000006 \
  USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  forge script script/DeploySeavaultFactory.s.sol --rpc-url base --browser --broadcast
```

## Deployment records

After the deployment confirms, generate its public record with the same contract build and
`FACTORY_SALT_SEED` used to deploy:

```sh
FACTORY_SALT_SEED=seavault-factory-v3 \
  forge script --root . script/DeploySeavaultFactory.s.sol --sig "record()" --rpc-url base
```

This read-only RPC step needs no wallet. It reads the latest broadcast file, requires a successful
receipt, compares its transaction input with this build, and checks the deployed factory's wiring and
vault implementation runtime. Recent deployment block hashes are also checked against the chain.
Recording runs separately because the deployment script executes before transactions are mined.
Pending or failed transactions produce no record.

Commit the resulting `deployments/<chain-id>/<factory-address>.json`. It includes the transaction,
block, source commit, constructor addresses (including `wNative` and `usdc`), salt seed and both
runtime code hashes. The factory runtime hash can be used for Listoor's `VAULT_FACTORY_CODEHASHES`.
Clone factories require Listoor to verify `vaultImplementation` and its runtime hash. Records
describe deployment-time values, including the initial owner.
The ignored broadcast and cache directories remain local.

For an earlier saved broadcast, use the `record(string)` entry point with its file path instead of
`record()`. Keep that broadcast file's original contracts revision and specify its original salt
seed when recording. Address prediction still accepts any seed, including the historical one.

## Post-deploy checklist, per chain

Payment support is fixed at deployment. The native asset and the factory's `wNative` share
native-denominated price bounds. The factory's `usdc`, when configured, uses separate
USDC-denominated bounds in the same policy root.

The vault owner sets the parameters below.

1. Build and save the [collection policy snapshot](ARCHITECTURE.md#collection-policy-snapshots)
   with the listing floors and bid or buy ceilings. Activate its root with
   `setPolicyRoot(expectedRoot, newRoot)`. Use the root of zero as `expectedRoot` for a new vault.
2. For token-specific floors, include a row with a zero floor in the desired denomination and
   [sign and share listing permits](ARCHITECTURE.md#listing-permits) with the keeper for the
   individual tokens it can list.
3. Call `setConduitApprovalForAll(collection, true)` for every collection the vault sells from.
4. Call `setConduitAllowance` with a finite amount for each of wrapped native and USDC the vault
   will bid or buy in. The allowance caps spending in the approved token. The keeper can wrap
   the vault's native balance to fund wrapped-token orders.
5. Call `setNativeBuyAllowance` with a finite amount if the vault will buy listings priced in the
   native asset. Each buy draws the allowance down, so top it up as needed.
6. Adjust `setMaxOrderDuration` (default 30 days) and `setMaxFeeBps` (default 1000 = 10%) if the
   defaults do not fit the marketplace's fee structure. The duration caps both how long an order
   may run and how far ahead it may start, so an order Seaport has validated never carries old
   policy for more than twice the duration it was validated under; lowering it later does not
   shorten those orders. The keeper should read `maxFeeBps` before posting: a listing whose
   marketplace fee plus creator earnings exceed it fails validation.
7. Move the NFTs and the funds for bids and buys into the vault, then point the keeper at it and
   watch it in dry-run mode before letting it post orders. Give the keeper the snapshot whose root
   matches `policyRoot()` and keep a private copy for recovery.
8. To retain full managed keeper access after the trial, pay `extendSubscription` on the factory
   from any wallet. After expiry, the keeper serves free-tier listings and offers and pauses snipes.
   A zero effective subscription price grants full access.
9. Call `setAutoWithdrawEnabled(true)` if the keeper should return ETH and ERC20 balances to the
   current owner. Configure the keeper to submit `autoWithdrawETH(amount)` and
   `autoWithdrawERC20(token, amount)` transactions. The owner can opt out at any time, and
   ownership changes clear the opt-in.

## Factory versions

The factory and vault code are immutable. Changes to the contract logic or a factory's
constructor addresses require a new deployment with a fresh `FACTORY_SALT_SEED`, used
consistently across chains. Use each vault's `factory()` address to verify its membership.
Clients that use the token-floor getter and setter on earlier vaults need version-specific
handling and listing permit support before adding a permit-enabled factory.

