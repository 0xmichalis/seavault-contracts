# listoor-contracts

EIP-1271 vault contracts for non-custodial Seaport order signing.

`ListoorVault` holds the NFTs and wrapped native tokens. A hot **keeper** key is authorized only to
_sign Seaport orders on the vault's behalf_ and to _buy listings for its owner_, never to move
anything itself. The keeper does not have to be trusted: the vault signs only for sales at or above
an owner-set floor and bids at or below an owner-set ceiling, and buys only within that ceiling and
owner-set allowances, so the worst a compromised keeper can do is trade at those bounds.

`ListoorVaultFactory` deploys vaults and registers them, so an owner gets a vault in one transaction
and off-chain infrastructure resolves it on-chain instead of carrying an address per chain. Every
vault is a separate contract with its own owner, policy and keeper — assets are segregated by
construction.

## Security model

- `isValidSignature` receives only a digest, so the signature blob carries the order components next
  to the ECDSA signature. The digest is re-derived from those components and must equal the one
  Seaport passed in; after that the components are known to be what Seaport is about to execute.
- Policy is then enforced on them: per-collection (optionally per-token) **listing floors**,
  per-collection **offer ceilings**, a payment-token allowlist, a cap on the share of a sale that may
  go to non-vault recipients, and a maximum order duration.
- A collection never sells below its ceiling: floors under it are raised to it. Otherwise a
  compromised keeper could buy at the ceiling and sell back at the floor on repeat. Bidding needs no
  floor.
- **Seaport stops asking the vault once an order is validated on-chain or partially filled.** Anyone
  can validate a posted order with its signature, and collection offers with a quantity fill
  partially as a matter of course. Policy changes and subscription lapses do not reach those orders.
- `setKeeper` bumps the vault's Seaport counter, so it revokes every outstanding order at once,
  validated or not. `incrementCounter` (owner) does the same without rotating, and `cancelOrders`
  (owner or keeper) retracts single orders. Cancel or bump after tightening policy if live orders
  have to obey it.
- **Gasless cancels.** OpenSea cancels an order offchain once its offerer signs
  `OrderHash(bytes32 orderHash)` under Seaport's domain, and the vault vouches for that signature
  when its keeper made it. That digest types an `OrderHash`, never an order, so it cannot approve a
  fill, and it keeps working through a lapse. OpenSea does not document verifying it through
  EIP-1271, but accepts it for orders under its signed zone (checked live on Base). It refuses orders
  younger than about five minutes and orders without a zone, which includes OpenSea listings; use
  `cancelOrders` for those.
- **Buys.** `buy(order, conduitKey)` (owner or keeper) fills someone else's listing through Seaport,
  with the vault paying and the owner receiving the NFTs in the same transaction. Everything paid,
  fees and tips included and counted at their highest, must fit within the offer ceilings of the
  NFTs bought, counted at their lowest. ETH spent comes out of `nativeBuyAllowance` and ERC20 out of
  the conduit allowance; those two are the hard cap on what a compromised keeper can spend. The
  vault's own listings are refused.
- Residual risk: the keeper key can sell at the floor, or bid or buy at the ceiling until the
  allowances run out. **Floors are loss bounds, not live prices** — repricing below a floor needs an
  owner transaction.
- Only the owner can withdraw assets; the keeper only spends through Seaport, within the bounds
  above. The only operator ever approved is Seaport's conduit.
- **Ownership moves in two steps**: `transferOwnership`, then `acceptOwnership` from the new wallet,
  and the vault's assets move with it. Moving a vault between your own wallets keeps the keeper and
  every order live. When it changes hands, the new owner calls `setKeeper` for their own key, which
  also revokes every order the old keeper signed. The factory's `vaultOf`, `vaultsOf` and
  `vaultCount` stay keyed by the wallet that created the vault, so read `owner()` on the vault to
  know who holds it.

Amounts are enforced per unit offered, because partial fills settle pro rata. Bundles sum the floors
(or ceilings) of every item. Variable-amount items are measured pessimistically: vault proceeds
and the NFTs it receives at their lowest point; fees, the NFTs it sells and its spend at their
highest.

## Subscription

Charging happens off the order entirely, because OpenSea's orderbook will not carry a fee: it rejects
any order with a consideration item it cannot attribute to itself or the collection
(`You have provided fees that we cannot attribute to OpenSea or the collection`), refuses one whose
first consideration item pays anyone but the offerer, and only accepts its own two zones. So there is
no room in a posted order for a protocol cut.

Instead the factory doubles as a subscription registry, and the vault checks it before signing:

- Vaults are created with a **trial window** (`trialPeriod`, 30 days by default), so a fresh vault
  trades immediately.
- After that, `extendSubscription(vault, periods)` buys 30-day periods at `subscriptionPrice` wei
  each. Anyone may pay for any vault; payment must be exact and is forwarded to
  `subscriptionRecipient` on the spot. Paying early stacks onto the current expiry rather than
  discarding it; paying after a lapse starts from the moment of payment.
- `renewSubscription(periods, maxCost)` on the vault does the same out of the vault's own balance,
  and reverts if a price change has pushed the cost above `maxCost`. Owner only:
  letting the keeper spend vault funds — even on the service — hands a compromised key a way to burn
  them. Keepers should watch `paidThrough` and raise the alarm instead.
- **A lapse stops signing, nothing else.** `isValidSignature` reverts with `SubscriptionInactive`, so
  new orders cannot be made and outstanding ones stop filling, except orders Seaport has already
  validated or partially filled. Withdrawals, cancels,
  `incrementCounter` and every policy setter keep working, so a vault is never held hostage. Paying
  revives outstanding orders without resigning them.
- **Paid time can only grow.** There is no code path that shortens `paidThrough`; raising the price or
  cutting the trial applies to future purchases only. That, plus unconditional custody, is what makes
  the gate safe to depend on.
- `setPriceOverride(vault, enabled, price)` prices individual vaults off-schedule — zero for partner,
  subscriber or in-house vaults, or a discount.
- Shipping default is **free** (`subscriptionPrice = 0`), which makes every vault subscribed
  regardless of the clock, so a fresh deployment is usable before any pricing decision is made.

A per-fill cut is still possible on the **buy path** (`buy`), where the vault fulfills someone else's
order and the transaction is ours to build rather than the orderbook's to validate. `buy` does not
take one yet.

## Layout

    src/ListoorVault.sol                     the vault
    src/ListoorVaultFactory.sol              deployment, registry and subscriptions
    src/libraries/SeaportOrderHash.sol       Seaport digest re-derivation
    src/libraries/CodeStore.sol              vault creation code, kept outside the factory
    script/DeployListoorVaultFactory.s.sol   CREATE3 deployment of the factory
    script/CreateVault.s.sol                 vault creation through the factory
    test/*.t.sol                             policy, admin, signature-encoding tests
    test/*.fork.t.sol                        real Seaport, conduit and CreateX

## Testing

Dependencies are managed with [soldeer](https://soldeer.xyz), which Foundry ships natively; they are
pinned in `[dependencies]` and `soldeer.lock` and land in `dependencies/` (git-ignored).

```sh
forge soldeer install                             # fetch dependencies
forge test                                        # unit tests; fork tests self-skip
BASE_RPC_URL=https://mainnet.base.org forge test  # plus fork tests
forge fmt --check && forge lint
```

Remappings in `foundry.toml` are maintained by hand so imports stay free of version numbers; bump a
dependency with `forge soldeer install <name>~<version>` and update its remapping path to match.

The fork tests are the ones that matter for interop: they pin the digest derivation against
`Seaport.getOrderHash`, fill a vault listing and a vault offer and buy a listing for the owner end
to end through the live Seaport and OpenSea conduit, and prove that policy failures, keeper rotation
and cancels all block fills.

## Deployment

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
vault salt gives the same owner an additional vault.

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
9. Before the trial runs out, `extendSubscription` from any wallet or `renewSubscription` from the
   vault's own balance.

## Signature blob

The keeper signs Seaport's order digest and submits `abi.encode(OrderComponents, ecdsaSignature)` as
the order's signature. In ethers:

```ts
const ORDER_COMPONENTS_TYPE =
    '(address offerer,address zone,(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount)[] offer,(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount,address recipient)[] consideration,uint8 orderType,uint256 startTime,uint256 endTime,bytes32 zoneHash,uint256 salt,bytes32 conduitKey,uint256 counter)';

const signature = AbiCoder.defaultAbiCoder().encode(
    [ORDER_COMPONENTS_TYPE, 'bytes'],
    [orderComponents, ecdsaSignature]
);
```

Sign orders one at a time. Seaport hands the vault the single-order digest, so a signature over a
bulk-order root never verifies.

For a gasless cancel, the keeper signs OpenSea's `OrderHash` message instead and sends
`abi.encode(orderHash, ecdsaSignature)` as the `offererSignature`. `cancellationDigest(orderHash)`
on the vault returns what it has to sign.

Two things about how the orderbook API treats these signatures, established by probing it directly:

- Length is not a constraint. Payloads are ~1.1 KB for a single-item listing and the API validates
  them without complaint (tested up to 1217 bytes).
- OpenSea calls `isValidSignature` on the offerer on-chain when an order is posted and reports the
  verdict as a `Signature invalid` validation error. Policy rejections therefore surface at post
  time, not only at fill time: a listing below the vault's floor never reaches the orderbook. Expect
  that error whenever the payload and the vault's policy disagree.
