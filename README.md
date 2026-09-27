# Onchain Census Contract

Reusable Solidity base contract for address-weighted on-chain censuses backed by a Lean Incremental Merkle Tree.

`OnchainCensus` owns the shared census mechanics:

- Lean-IMT insertion and root rotation
- address-to-weight storage
- duplicate address prevention
- zero address and zero weight guards
- `ICensusValidator` root validation
- total voting power snapshots per root
- leaf packing as `(address << 88) | weight`

Concrete applications only implement their own admission rules, then call `_addToCensus(user, weight)`.

## davinci-zkvm branch

This branch adapts the contract to DAVINCI's address-derived ballot slots (origin 3,
`MERKLE_TREE_ONCHAIN_DYNAMIC_V1`):

- **Slot uniqueness.** Every member gets the ballot slot
  `0x10 + (be64(sha256("davinci-slot-v1" ‖ address)[0..8]) mod (2^63 - 16))`, the same
  key the davinci-zkvm guest derives. `_addToCensus` reverts with `SlotTaken(existing)`
  when the slot already belongs to another member, since two members on one slot would
  overwrite each other's ballots. `slotOf(address)` and `slotOwner(uint64)` expose it.
- **No root-history eviction.** Every replaced root keeps its last-valid block and total
  voting power forever. The upstream ring of 100 roots made settlement revert after a
  burst of more than 100 registrations while a batch was being proved, and bought no
  soundness for an append-only, fixed-weight census.
- **Private insert and storage.** `_insertAndRotateRoot` is `private`, so the only way to
  insert is `_addToCensus`, which always emits `WeightChanged` and `CensusMemberAdded`.
  Member weights and slot owners are private too (read them through `weightOf` and
  `slotOwner`), so a derived contract cannot clear a member to register it again or free
  a slot for a colliding address.
- **`OwnedCensus`.** A concrete census where the owner calls `addMember(user, weight)` or
  `addMembers(users, weights)` (reverts `LengthMismatch()`; one bad entry reverts the
  batch). Used by the davinci-sequencer tests and e2e.

`test/vectors/slot.json` is a copy of davinci-zkvm's shared slot vectors
(`rust-sdk/testdata/slot.json`); the forge tests check `slotOf` against every entry.

Events and the `ICensusValidator` interface are unchanged. The storage layout is not
(the history ring is gone), so this is for new deployments only.

## Contract

The main contract is:

```solidity
src/OnchainCensus.sol
```

It is abstract and should be inherited by a concrete contract:

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {OnchainCensus} from "onchain-census-contract/src/OnchainCensus.sol";

contract MyCensus is OnchainCensus {
    error NotAllowed();

    function register() external {
        if (!_canRegister(msg.sender)) revert NotAllowed();

        _addToCensus(msg.sender, 1);
    }

    function _canRegister(address user) internal view returns (bool) {
        // Add application-specific guards here.
        return user != address(0);
    }
}
```

## Public API

`OnchainCensus` implements `ICensusValidator`:

```solidity
function getRootBlockNumber(uint256 root) external view returns (uint256 blockNumber);
function getCensusRoot() external view returns (uint256 root);
function getTotalVotingPowerAtRoot(uint256 root) external view returns (uint256 totalVotingPower);
```

It also exposes convenience getters:

```solidity
function weightOf(address user) external view returns (uint88);
function treeSize() external view returns (uint256);
function treeDepth() external view returns (uint256);
function totalVotingPower() external view returns (uint256);
function leafOf(address user) external view returns (uint256);
function leafFor(address user, uint88 weight) external pure returns (uint256);
function slotOf(address user) external pure returns (uint64);
function slotOwner(uint64 slot) external view returns (address);
```

## Internal API

Concrete contracts should call:

```solidity
function _addToCensus(address user, uint88 weight)
    internal
    returns (uint256 leaf, uint256 newRoot);
```

This function reverts when:

- `user == address(0)`
- `weight == 0`
- the address already has a recorded weight
- the address's ballot slot belongs to another member (`SlotTaken(existing)`)

The function records the slot owner, inserts the packed leaf into the Lean-IMT, records the replaced root's last-valid block, stores the account weight, snapshots total voting power, emits `WeightChanged`, and emits `CensusMemberAdded`.

## Using From Another Foundry Project

Install or vendor this repository as a dependency, then add remappings for this package and its transitive Solidity dependencies.

Example for a sibling checkout:

```toml
[profile.default]
allow_paths = ["../onchain-census-contract"]
remappings = [
  "onchain-census-contract/=../onchain-census-contract/",
  "davinci-contracts/=../onchain-census-contract/lib/davinci-contracts/",
  "zk-kit.solidity/=../onchain-census-contract/lib/zk-kit.solidity/",
  "poseidon-solidity/=../onchain-census-contract/lib/poseidon-solidity/contracts/",
  "@openzeppelin/contracts/=../onchain-census-contract/lib/openzeppelin-contracts/contracts/"
]
```

Then import the base contract:

```solidity
import {OnchainCensus} from "onchain-census-contract/src/OnchainCensus.sol";
```

If the dependency is installed under your project `lib/`, use paths like:

```toml
remappings = [
  "onchain-census-contract/=lib/onchain-census-contract/",
  "davinci-contracts/=lib/onchain-census-contract/lib/davinci-contracts/",
  "zk-kit.solidity/=lib/onchain-census-contract/lib/zk-kit.solidity/",
  "poseidon-solidity/=lib/onchain-census-contract/lib/poseidon-solidity/contracts/",
  "@openzeppelin/contracts/=lib/onchain-census-contract/lib/openzeppelin-contracts/contracts/"
]
```

Foundry must know these transitive remappings because inheritance compiles the imported base contract together with your concrete contract.

## Development

Clone dependencies if they are not already present:

```sh
git submodule update --init --recursive
```

Install Foundry, then run:

```sh
forge build
forge test
forge fmt --check
```

The Makefile also exposes:

```sh
make build
make test
```

`OnchainCensus` is abstract, so it cannot be deployed directly. Deploy a concrete contract that inherits it, such as `OwnedCensus`. The bytecode links the `PoseidonT3` library from `lib/poseidon-solidity`, which deploys through a deterministic proxy to `0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93` on any EVM chain (see its README). On a fresh chain, deploy it there first, then link the census against that address.

## License

AGPL-3.0-or-later
