# Census contract design

What `OnchainCensus` stores and guarantees, and what DAVINCI sequencers and the
`ProcessRegistry` rely on. Read it before writing your own census on top of the base
contract.

## Members and leaves

A member is an address with a weight in `[1, 2^88 - 1]`. Its leaf is

```
leaf = (uint160(address) << 88) | weight
```

and leaves go into a zk-kit Lean-IMT hashed with PoseidonT3 over BN254, the same tree as
davinci-node's lean-imt-go (the tests replay lean-imt-go and davinci-node vectors). The
root is 0 until the first member joins.

The census is append-only with fixed weights. The tree, the weights, the slot owners and
the insert path are `private`, so a derived contract can only add members through
`_addToCensus`. It cannot remove a member, change a weight, or register an address twice.

## Ballot slots

Every member owns one slot of the DAVINCI state tree, derived from its address the same
way the davinci-zkvm guest does for a Merkle census:

```
slot = 0x10 + (be64(sha256("davinci-slot-v1" || address)[0..8]) mod (2^63 - 16))
```

`slotOf(address)` computes it. `_addToCensus` reverts with `SlotTaken(existing)` when
another member already holds the slot, because two members on one slot would overwrite
each other's ballots. Grinding a collision against a census of N members costs about
2^63/N key generations. `test/vectors/slot.json` is a copy of davinci-zkvm's
`rust-sdk/testdata/slot.json`, and the tests check `slotOf` against every entry.

## Root history

Every root the census has had stays queryable:

| Call | Current root | Replaced root | Unknown root, or root 0 |
|---|---|---|---|
| `getRootBlockNumber(root)` | `block.number` | the block in which it was replaced | 0 |
| `getTotalVotingPowerAtRoot(root)` | the current total weight | the total weight at that root | 0 |

Roots replaced within one block all report that block. Nothing is evicted: in an
append-only census an old root is a subset of the current one, so keeping it costs no
soundness, and a batch proved against it can still settle after a burst of registrations.

## Events

Each registration emits, in this order:

- `WeightChanged(account, 0, weight)`, from `ICensusValidator`;
- `CensusMemberAdded(user, weight, leaf, newRoot, totalVotingPower)`.

A davinci-sequencer node rebuilds the tree from the `CensusMemberAdded` logs and checks
each `newRoot`. It marks the census unusable, and refuses its votes, if it sees a
`WeightChanged` with a non-zero previous weight or two members on one slot.

## Use by a voting process

For census origin 3 (`MERKLE_TREE_ONCHAIN_DYNAMIC_V1`), the `ProcessRegistry` of the
davinci-contracts zkVM line (the `lib/davinci-contracts` submodule here is the upstream npm
line, used only for `ICensusValidator`; its registry checks differ):

- at process creation, requires code at `contractAddress` that answers `getCensusRoot()`,
  records that root for information, requires a non-empty `censusURI` and rejects
  `onchainAllowAnyValidRoot = true`;
- at each state transition, accepts the batch's census root only if
  `getRootBlockNumber(root)` is non-zero, not in the future and not before the process's
  creation block.

Members added while the process runs can vote. A root that was replaced before the
process was created cannot be used.

## Compared with `main`

The `main` branch keeps a ring of the last 100 roots and has no slot check. This line
(`davinci-zkvm`) checks slot uniqueness, keeps every root and makes all census storage
private. The storage layouts differ, so a census deployed from `main` cannot be upgraded
to this one: deploy a new contract.
