# Deployment

Both the factory and the vaults it creates go through [CreateX](https://github.com/pcaversaccio/createx)
at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`, which is deployed on every chain these contracts
target (ethereum, base, arbitrum, optimism, matic, zora, shape). With CREATE3 the address depends on the salt
alone, never on the init code, so **the same address is used on every chain even though constructor
arguments differ** — the factory bakes in each chain's own Seaport and conduit, and each vault its own
owner and keeper.

Both salts are `bytes20(sender) ++ 0x00 ++ bytes11(digest)`, which asks CreateX for a permissioned,
chain-independent deploy: only that sender can use the salt (nobody can squat an address on a chain
you have not deployed to yet), and `block.chainid` is kept out of it. For the factory the sender is
the deployer key and the digest comes from the salt seed; for a vault the sender is the factory and
the digest covers `(owner, salt)`.

Because vault addresses derive from the factory's address, **deploy the factory with the same key and
salt seed on every chain** — the script aborts if the broadcaster does not match the salt.

```sh
# 1. Predict the factory address; no key needed, and any chain gives the same answer
forge script script/DeployListoorVaultFactory.s.sol --sig "predict(address,string)" \
  0xDEPLOYER listoor-vault-factory-v1 --rpc-url base

# 2. Deploy the factory, per chain. FACTORY_OWNER (default: the deployer) becomes the fee
#    admin and initial fee recipient
forge script script/DeployListoorVaultFactory.s.sol --rpc-url base --account deployer \
  --broadcast --verify

# 3. Create a vault, per chain. Owner is the broadcasting key
FACTORY=0xFACTORY KEEPER=0xKEEPER VAULT_SALT=primary \
  forge script script/CreateVault.s.sol --rpc-url base --account cold --broadcast

# Look up an existing vault at any time
cast call 0xFACTORY "vaultOf(address,bytes32)(address)" 0xOWNER $(cast keccak primary) \
  --rpc-url base
```

`SEAPORT` and `CONDUIT` default to Seaport 1.6 (`0x0000…eB395`) and OpenSea's conduit
(`0x1E00…3c71`); override them per chain if OpenSea points elsewhere. A new factory salt seed yields a
fresh factory and a fresh set of vault addresses, which is how you roll out a new vault version; a new
vault salt can create a replacement after the owner transfers their current vault away.
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
own. Under the default seed, a test factory from the production deployer takes the production
address on that chain for good.

```sh
FACTORY_SALT_SEED=listoor-vault-factory-e2e-1 \
  forge script script/DeployListoorVaultFactory.s.sol --rpc-url base --browser --broadcast
```

## Post-deploy checklist, per chain

Everything below is called on the vault by its owner.

1. `setPaymentTokenAllowed(address(0), true)` for native ETH and `setPaymentTokenAllowed(WETH, true)`.
2. `setListingFloor(collection, floorPerUnit)`, plus `setTokenListingFloor` where a token needs its
   own bound. A collection with no floor cannot be listed at all.
3. `setOfferCeiling(collection, ceilingPerUnit)` for collections the keeper may bid on or buy from.
   Listings in that collection then have to clear the ceiling as well as the floor.
4. `setConduitApprovalForAll(collection, true)` for every collection the vault sells from.
5. `setConduitAllowance(WETH, amount)` if the vault will bid, or buy listings priced in WETH. Keep it
   finite: it caps what a compromised keeper can spend in WETH, and the keeper can wrap the vault's
   native balance into WETH.
6. `setNativeBuyAllowance(amount)` if the vault will buy listings priced in ETH. Keep it finite too:
   it caps what buys spend in ETH. Each buy draws it down, so top it up as needed.
7. Adjust `setMaxOrderDuration` (default 30 days) and `setMaxFeeBps` (default 1000 = 10%) if the
   defaults do not fit the marketplace's fee structure. The keeper should read `maxFeeBps` before
   posting: a listing whose marketplace fee plus creator earnings exceed it fails validation.
8. Move the NFTs, the WETH and the ETH buys spend in, then point the keeper at the vault and watch it
   in dry-run mode before letting it post orders.
9. To retain full keeper access after the trial, `extendSubscription` from any wallet or
   `renewSubscription` from the vault's own balance. Lapsed accounts retain the keeper's free-tier
   listings and offers, but cannot snipe. A zero effective subscription price grants full access.
10. Optionally, while subscribed, call `setAutoWithdrawEnabled(true)` to let the keeper return ETH
    and ERC20 balances to the current owner. It starts disabled; `setAutoWithdrawEnabled(false)` is
    always available. Configure the keeper service to submit `autoWithdrawETH(amount)` and
    `autoWithdrawERC20(token, amount)` transactions. Expiry pauses them and ownership changes clear
    the opt-in. Manual owner withdrawals remain available throughout.

## New versions and migration

The factory and vaults are immutable, with no proxy or code replacement mechanism. Owner and
factory-admin setters change policies, keepers, block status and subscription terms within their existing
permissions. Changing contract logic or the Seaport/conduit wiring requires a new factory version.
Deploy it with a new `FACTORY_SALT_SEED`, consistently across chains. The old factory cannot start
creating the new bytecode, and existing vaults keep their original subscription registry.

Migration is opt-in and signed by each vault owner:

1. Call `setKeeper(oldVault)` on the old vault. Using the vault itself as keeper prevents ECDSA
   signatures and increments its Seaport counter, invalidating even validated or partially filled
   orders. Using the owner's address would not stop the keeper if they share a wallet.
2. Create a vault through the new factory, unless one is already owned there. To keep the new
   vault inactive during setup, pass its predicted address as keeper.
3. Move assets directly to the new vault through `withdrawETH`, `withdrawERC20`, `withdrawERC721`
   and `withdrawERC1155`. Each asset transfer is a separate owner transaction; interrupted
   migrations can resume without sending assets back through the wallet.
4. Configure the new vault's policies and conduit permissions, update the trading client's
   account assignments, then set its keeper to the desired signing wallet.

One-vault ownership is enforced per factory, so old and new versions can coexist during migration.
Approvals, policy state and paid subscription time stay in the original deployment. Clients must
retain earlier factory addresses for discovery and management, and use each vault's original
registry for subscriptions and ownership acceptance. Incompatible ABIs need explicit client support.

A new deployment cannot repair the old code. If an immutable bug prevents withdrawals, deploying
a replacement does not recover the affected assets.

