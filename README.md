# listoor-contracts

EIP-1271 vault contracts for non-custodial Seaport order signing.

`ListoorVault` holds the NFTs and wrapped native tokens. A hot **keeper** key is authorized only to
_sign Seaport orders on the vault's behalf_, never to move anything. The keeper does not have to be
trusted: the vault signs only for sales at or above an owner-set floor and bids at or below an
owner-set ceiling, so the worst a compromised keeper can do is trade at those bounds.

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
- Seaport validates signatures at fulfillment time, so `setKeeper` revokes every outstanding order
  at once. `cancelOrders` (owner or keeper) and `incrementCounter` (owner) are the on-chain equivalents.
- Residual risk: the keeper key can sell at the floor or bid at the ceiling. **Floors are loss bounds,
  not live prices** — repricing below a floor needs an owner transaction.
- Only the owner can move assets, and the only operator ever approved is Seaport's conduit.

Amounts are enforced per unit offered, because partial fills settle pro rata. Bundles sum the floors
(or ceilings) of every item. Variable-amount items are measured pessimistically: vault proceeds at
their lowest point, fees and vault spend at their highest.

## Layout

    src/ListoorVault.sol                     the vault
    src/ListoorVaultFactory.sol              deployment and registry
    src/libraries/SeaportOrderHash.sol       Seaport digest re-derivation
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
`Seaport.getOrderHash`, fill a vault listing and a vault offer end to end through the live Seaport
and OpenSea conduit, and prove that policy failures, keeper rotation and cancels all block fills.

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

# 2. Deploy the factory, per chain
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

## Post-deploy checklist, per chain

Everything below is called on the vault by its owner.

1. `setPaymentTokenAllowed(address(0), true)` for native ETH and `setPaymentTokenAllowed(WETH, true)`.
2. `setListingFloor(collection, floorPerUnit)`, plus `setTokenListingFloor` where a token needs its
   own bound. A collection with no floor cannot be listed at all.
3. `setOfferCeiling(collection, ceilingPerUnit)` for collections the keeper may bid on.
4. `setConduitApprovalForAll(collection, true)` for every collection the vault sells from.
5. `setConduitAllowance(WETH, amount)` if the vault will bid.
6. Adjust `setMaxOrderDuration` (default 30 days) and `setMaxFeeBps` (default 1000 = 10%) if the
   defaults do not fit the marketplace's fee structure.
7. Move the NFTs and WETH in, then point the keeper at the vault and watch it in dry-run mode before
   letting it post orders.

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

Sign orders one at a time. Seaport reads bulk-order proofs out of the signature itself, and a bulk
signature would make the vault re-derive a digest that no longer matches.

Two things about how the orderbook API treats these signatures, established by probing it directly:

- Length is not a constraint. Payloads are ~1.1 KB for a single-item listing and the API validates
  them without complaint (tested up to 1217 bytes).
- OpenSea calls `isValidSignature` on the offerer on-chain when an order is posted and reports the
  verdict as a `Signature invalid` validation error. Policy rejections therefore surface at post
  time, not only at fill time: a listing below the vault's floor never reaches the orderbook. Expect
  that error whenever the payload and the vault's policy disagree.
