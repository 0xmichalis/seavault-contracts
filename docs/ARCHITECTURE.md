# Architecture

EIP-1271 vault contracts for non-custodial Seaport order signing.

`Seavault` holds NFTs and funds. A hot **keeper** key can _sign Seaport orders
on the vault's behalf_ and _buy listings for its owner_. Owners can also opt into automatic
ETH/ERC20 withdrawals that send funds only to the current owner. The vault signs only for sales at
or above an owner-set floor and bids at or below an owner-set ceiling, and buys only within that
ceiling and owner-set allowances. A compromised keeper can trade at those bounds and, when opted
in, return funds to the owner.

`SeavaultFactory` deploys vaults and registers them, so an owner gets a vault in one transaction
and off-chain infrastructure resolves it on-chain instead of carrying an address per chain. Each
vault exposes its immutable `factory()` address and updates that factory's ownership index when
ownership changes. Every vault is a separate contract with its own assets, owner, policy and keeper.

## Security model

- `isValidSignature` receives only a digest, so the signature blob carries the order components,
  the keeper's ECDSA signature, and the collection witnesses. The vault re-derives the digest
  from the supplied components and checks it matches the one Seaport is about to execute.
- The vault verifies the witnesses against the owner's active `policyRoot` and applies the proven
  collection **listing floors** and **offer ceilings** to the order items. Native per-token floor
  overrides, the sale fee cap and the maximum order duration are read from storage.
- The fixed payment currencies are the native asset and the factory's `wNative` and `usdc`.
  The native asset and its wrapper use the same price units. A USDC order uses USDC for
  every payment item covered by the vault's policy, including fees and direct-buy tips.
- Within a denomination, a collection's listing floor is raised to its offer ceiling to prevent
  repeat buy-and-sell losses within the configured bounds. Bidding needs no floor. When enabling
  both denominations, the owner sets bounds in each currency and accounts for changes in their
  relative value.
- **Seaport stops asking the vault once an order is validated on-chain or partially filled.** Anyone
  can validate a posted order with its signature, and collection offers with a quantity fill
  partially as a matter of course. Updating the collection policy root also bumps the vault's
  Seaport counter in the same transaction. That revokes outstanding orders even if Seaport has
  validated or partially filled them.
  Their reach is bounded, though: an order may neither span nor start more than `maxOrderDuration`
  ahead of the moment the vault vouches for it, so none of them outlives twice the value in force
  at that moment. Lowering `maxOrderDuration` later reaches only orders not yet vouched for.
- `setKeeper` also bumps the vault's Seaport counter, so it revokes every outstanding order at once,
  validated or not. `incrementCounter` (owner) does the same without rotating, and `cancelOrders`
  (owner or keeper) retracts single orders. Cancel or bump after tightening the other policy settings
  if validated orders have to obey them.
- **Gasless cancels.** OpenSea cancels an order offchain once its offerer signs
  `OrderHash(bytes32 orderHash)` under Seaport's domain, and the vault vouches for that signature
  when its keeper made it. That digest types an `OrderHash`, never an order, so it cannot approve a
  fill, and it keeps working through a lapse. OpenSea does not document verifying it through
  EIP-1271, but accepts it for orders under its signed zone (checked live on Base). It refuses orders
  younger than about five minutes and orders without a zone, which includes OpenSea listings; use
  `cancelOrders` for those.
- **Buys.** `buy(order, conduitKey, witnesses)` (owner or keeper) fills someone else's listing through
  Seaport, with the vault paying and the owner receiving the NFTs in the same transaction. Everything paid,
  fees and tips included and counted at their highest, must fit within the offer ceilings of the
  NFTs bought, counted at their lowest. ETH spent comes out of `nativeBuyAllowance` and ERC20 out of
  the conduit allowance; those two are the hard cap on what a compromised keeper can spend. The
  vault's own listings are refused.
- Residual risk: the keeper key can sell at the floor, or bid or buy at the ceiling until the
  allowances run out. **Floors are loss bounds, not live prices** — repricing below a floor needs an
  owner transaction.
- Only the owner can choose a withdrawal recipient. Owners can opt into keeper-triggered
  ETH/ERC20 withdrawals to the current owner; NFTs remain owner-only. The only operator ever
  approved is Seaport's conduit.
- **Ownership moves in two steps**: `transferOwnership`, then `acceptOwnership` from the new wallet,
  and the vault's assets move with it. Moving a vault between your own wallets keeps the keeper and
  every order live, but clears the automatic-withdrawal opt-in. When it changes hands, the new owner
  calls `setKeeper` for their own key, which
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

## Collection policy snapshots

The vault stores one active root for collection price rules. Keep the matching snapshot off-chain so
the owner and their keepers can rebuild proofs independently. Use the following canonical encoding.

1. Record up to 1,024 rows of `(collection, floor, ceiling, salt)`. Assign each row to the native
   denomination or to USDC. Use a nonzero collection address, at most one row per collection
   and denomination, and decimal uint256 strings for amounts in that currency's smallest units.
   Generate an independent, cryptographically random nonzero `bytes32` salt when adding a row or
   changing its amounts. Sort native rows first, then USDC rows, each by numeric collection address.
2. For each row, compute `inner = keccak256(abi.encode(collection, floor, ceiling, salt))`
   using the Solidity types `(address, uint256, uint256, bytes32)`. The native leaf is
   `keccak256(bytes.concat(inner))`. The USDC leaf is `keccak256(bytes.concat(inner, hex"01"))`.
3. Pair adjacent hashes at each level and hash the two hashes in ascending byte order. Promote an
   unpaired last hash unchanged. Repeat to obtain the root. The empty snapshot has root zero.
4. Keep the snapshot before calling `setPolicyRoot(expectedRoot, newRoot)`. The contract requires
   `expectedRoot` to match the active root. A different root retires live orders, so the keeper
   uses the new proofs and Seaport counter when reposting. A zero root disables listings, bids and buys.

A witness contains the collection, amounts, salt and up to ten sibling hashes from leaf to root.
Send one witness in the order's denomination per distinct NFT collection, in ascending address
order. Use the NFT offers when listing or buying, and the NFT consideration when bidding.
For native orders, a collection with token floors only needs an explicit native row with a zero
default floor and its configured ceiling, even when that ceiling is zero. The vault applies a
nonzero token override before raising the resulting floor to the proven ceiling. USDC listings
use their collection's USDC floor and ceiling.
The salts protect unrevealed collection rows against guessing from a root or sibling hash.
Token-level overrides and global vault limits are readable on-chain.

### On-chain proof disclosure

- **The owner saves a policy.** The owner's wallet submits `setPolicyRoot` with the expected and
  new roots.
- **A buyer takes our listing or a seller accepts our offer.** The taker's wallet submits the
  Seaport fill and pays gas. If the order has yet to be validated, the fill carries the signature.
  Seaport calls the vault's `isValidSignature` to check the witnesses before settlement.
- **A signed order can be prevalidated on-chain.** Anyone holding the signed order can pay to
  submit it to Seaport's `validate`, which checks the signature and saves the validation result.
  This is optional. Normal Listoor posting leaves the on-chain check to the taker's fill. After
  successful prevalidation or a partial fill, later fills can omit the previously checked signature.
  [Seaport 1.6 order validation](https://github.com/ProjectOpenSea/seaport/blob/1.6/docs/SeaportDocumentation.md).
- **The keeper buys directly.** The keeper submits `vault.buy` with the purchased collections'
  witnesses and the seller's signed order, and pays the gas. In the same transaction, the vault
  checks the witnesses and pays Seaport to deliver the NFTs to the owner.

Any included transaction carrying a witness reveals the collection, floor, ceiling, salt and
sibling hashes in its input, even if execution reverts.

## Subscription

Charging happens off the order entirely, because OpenSea's orderbook will not carry a fee: it rejects
any order with a consideration item it cannot attribute to itself or the collection
(`You have provided fees that we cannot attribute to OpenSea or the collection`), refuses one whose
first consideration item pays anyone but the offerer, and only accepts its own two zones. So there is
no room in a posted order for a protocol cut.

The factory handles subscription payments and records entitlements. The managed keeper reads them
to apply service tiers:

- Vaults are created with a **trial window** (`trialPeriod`, 30 days by default), so a fresh vault
  trades immediately.
- After that, `extendSubscription(vault, periods)` buys 30-day periods at `subscriptionPrice` wei
  each. Anyone may pay for any vault; payment must be exact and is forwarded to
  `subscriptionRecipient` on the spot. Paying early stacks onto the current expiry rather than
  discarding it; paying after a lapse starts from the moment of payment.
- **A lapse returns the keeper to the free tier.** The keeper allows three configured listings and
  three configured offers per vault on each chain, and disables snipes. On-chain, `isValidSignature`
  and `buy` enforce the designated keeper and the owner's trading policy regardless of expiry.
  Automatic withdrawals continue to require owner opt-in.
- **Paid time can only grow.** There is no code path that shortens `paidThrough`; raising the price or
  cutting the trial applies to future purchases only. The factory block flag controls managed
  keeper access independently of paid time.
- `setPriceOverride(vault, enabled, price)` prices individual vaults off-schedule — zero grants
  full-access exceptions for partner, subscriber or in-house vaults, or a discount.
- Shipping default is **free** (`subscriptionPrice = 0`), which makes every vault subscribed
  regardless of the clock and disables keeper tier restrictions. A positive per-vault override
  still follows its own subscription terms.

A per-fill cut is still possible on the **buy path** (`buy`), where the vault fulfills someone else's
order and the transaction is ours to build rather than the orderbook's to validate. `buy` does not
take one yet.

## Automatic withdrawals

Automatic withdrawals start disabled. The owner calls
`setAutoWithdrawEnabled(true)` to let the keeper call `autoWithdrawETH(amount)` or
`autoWithdrawERC20(token, amount)`. The owner may also call these methods. Both send only to
`owner()`; neither accepts a recipient. The keeper submits each transaction and pays its gas.
These methods do not run automatically on deposits or sale fills;
the keeper service must watch balances and submit withdrawals. They return funds held by the vault,
including deposits, so enabling them can reduce funds available for bids and buys.

The owner can disable automatic withdrawals at any time. Accepting ownership from another wallet
clears the opt-in. The new owner must enable it again.

Manual `withdrawETH`, `withdrawERC20`, `withdrawERC721` and `withdrawERC1155` are owner-only and
accept an owner-chosen recipient.

## Vault blocklist

The factory owner can call `setBlocked(vault, blocked)` to suspend or restore managed keeper service
for a registered vault. The keeper reads `isBlocked(vault)` before taking new trading work, and
`VaultBlockStatusUpdated` records changes. The flag applies independently of subscription entitlement.

Seavault authorizes trades and withdrawals under the owner's policy. To revoke outstanding orders,
cancel them, increment the Seaport counter or rotate the keeper.

## OpenSea sign-in

The owner can sign in to opensea.io as the vault, for example to set up notification emails for the
vault's offers and sales. OpenSea signs wallets in with Sign-In with Ethereum and verifies contract
accounts through EIP-1271 on chain 1, so signing in needs the vault deployed on Ethereum.

The owner never signs the sign-in message itself. They sign EIP-712 typed data
`OpenSeaLogin(string message, uint256 deadline)` under the domain
`{name: "Seavault", version: "1", chainId, verifyingContract: vault}`, and the vault vouches for
the message while `block.timestamp <= deadline` and that signature comes from the current `owner()`
(an EOA or an EIP-1271 wallet). Approvals are bound to one vault, chain, message and deadline, and
only validate while their signer owns the vault, including again if it regains ownership before the
deadline. The keeper cannot sign in.

The vault writes the opening of the message itself: OpenSea's preamble
`opensea.io wants you to sign in with your Ethereum account:` and its own EIP-55 address. An
approval therefore only ever signs the vault in to OpenSea, never an arbitrary message. OpenSea
validates the rest, including its single-use nonce and issue time. The sign-in digest is an
EIP-191 hash, so it can never approve a Seaport order or cancellation, and an order signature can
never approve a sign-in, even when the owner and keeper share a key. Like other owner actions, it
works while the vault is lapsed or blocked.

OpenSea controls the expiration and revocation of signed-in sessions. A vault ownership change
leaves existing sessions active until they expire or OpenSea revokes them.

## Layout

    src/Seavault.sol                        shared vault implementation
    src/SeavaultFactory.sol                 deployment, registry and keeper access
    src/libraries/SeaportOrderHash.sol       Seaport digest re-derivation
    src/libraries/SeavaultClone.sol          fixed-target clone creation code
    script/DeploySeavaultFactory.s.sol      CREATE3 deployment of the factory
    script/CreateVault.s.sol                vault creation through the factory
    test/*.t.sol                            policy, admin, signature-encoding tests
    test/*.fork.t.sol                       real Seaport, conduit and CreateX

## Signature blob

The keeper signs Seaport's order digest and attaches the collection witnesses. In ethers:

```ts
const ORDER_COMPONENTS_TYPE =
    '(address offerer,address zone,(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount)[] offer,(uint8 itemType,address token,uint256 identifierOrCriteria,uint256 startAmount,uint256 endAmount,address recipient)[] consideration,uint8 orderType,uint256 startTime,uint256 endTime,bytes32 zoneHash,uint256 salt,bytes32 conduitKey,uint256 counter)';
const COLLECTION_WITNESSES_TYPE = '(address collection,uint256 floor,uint256 ceiling,bytes32 salt,bytes32[] siblings)[]';

const signature = AbiCoder.defaultAbiCoder().encode(
    [ORDER_COMPONENTS_TYPE, 'bytes', COLLECTION_WITNESSES_TYPE],
    [orderComponents, ecdsaSignature, witnesses]
);
```

Sign orders one at a time. Seaport hands the vault the single-order digest, so a signature over a
bulk-order root never verifies.

Each collection witness increases the signature size. Verify acceptance at the intended
signature sizes before activating a new factory on a live integration.

For a gasless cancel, the keeper signs OpenSea's `OrderHash` message instead and sends
`abi.encode(orderHash, ecdsaSignature)` as the `offererSignature`. `cancellationDigest(orderHash)`
on the vault returns what it has to sign.

For an OpenSea sign-in, the wallet answering OpenSea's `personal_sign` request returns
`abi.encode(OPENSEA_LOGIN_TAG, messageBody, deadline, ownerSignature)`, where `messageBody` is the
message minus its first two lines (the preamble and the address) and the newline after each, and
`ownerSignature` is the owner's signature over the `OpenSeaLogin` typed data for the full message. Calling
`isValidSignature` with the message's EIP-191 hash checks the result before it is handed back.
