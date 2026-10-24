# Architecture

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
  partially as a matter of course. Policy changes do not reach those orders.
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
  also revokes every order the old keeper signed. `vaultOf(creator, salt)` remains a creation
  lookup. The factory's `ownedVaultOf(owner)` maps each wallet to its single current vault. Creating
  another or accepting another transfer from the same factory while already owning a vault reverts. After transferring
  a vault away, the wallet may create a replacement with a fresh salt.
  `pendingVaultsOf(recipient, offset, limit)` discovers incoming transfer proposals in pages of
  at most 100 addresses. Proposals do not reserve the recipient's ownership slot or prevent creation.
  Transfers update the ownership mapping and pending set atomically in constant time; there is
  no creator array. Pending set ordering can change after a transfer, so refresh discovery when
  ownership changes. Creation history is available from `VaultCreated` events.

`createVault` accepts a native deposit and forwards it to the new vault in the same transaction.
An application can make Deposit the first interaction: native funds deploy and fund in one
transaction; a first ERC20 or NFT deposit deploys and then transfers directly from the owner's
wallet in two transactions, without a deposit approval. Later deposits are direct transfers.

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

Instead the factory doubles as a subscription registry. The keeper reads it for tier access, and
the vault checks it before direct buys:

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
- **A lapse returns the keeper to the free tier.** The keeper allows three configured listings and
  three configured offers per vault on each chain, and disables snipes. `isValidSignature` still
  verifies the keeper and every owner-set policy, so free-tier orders can be posted and filled.
  `buy` reverts with `SubscriptionInactive` while lapsed. Withdrawals, cancels, `incrementCounter`
  and every policy setter keep working, so a vault is never held hostage. Usage quotas restrict the
  keeper service; owners can choose their own keeper and are not bound to its quotas.
- **Paid time can only grow.** There is no code path that shortens `paidThrough`; raising the price or
  cutting the trial applies to future purchases only. That, plus unconditional custody, is what makes
  the gate safe to depend on.
- `setPriceOverride(vault, enabled, price)` prices individual vaults off-schedule — zero grants
  full-access exceptions for partner, subscriber or in-house vaults, or a discount.
- Shipping default is **free** (`subscriptionPrice = 0`), which makes every vault subscribed
  regardless of the clock and disables keeper tier restrictions. A positive per-vault override
  still follows its own subscription terms.

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
