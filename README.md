# DAVINCI on-chain census contract

Solidity contracts for append-only, weighted censuses kept on-chain. A
[DAVINCI](https://davinci.vote) voting process can use one as its census (origin 3,
`MERKLE_TREE_ONCHAIN_DYNAMIC_V1`), so members added while the vote is open can take part.
Organizers deploy a census and add members; sequencers and other integrators read its roots,
weights and events.

[![test](https://github.com/vocdoni/davinci-onchain-census-contract/actions/workflows/test.yml/badge.svg?branch=davinci-zkvm)](https://github.com/vocdoni/davinci-onchain-census-contract/actions/workflows/test.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)

## Overview

A member is an address with a weight. The census stores members as leaves of a lean
incremental Merkle tree (zk-kit Lean-IMT, Poseidon), keeps every root the tree has had
together with the total voting power at that root, and implements `ICensusValidator` from
[davinci-contracts](https://github.com/vocdoni/davinci-contracts). A process created with an
on-chain census records the contract address instead of a fixed root. The
[sequencer](https://github.com/vocdoni/davinci-sequencer) rebuilds the tree from the
contract's logs and proves each batch against one of its roots, and the `ProcessRegistry`
accepts any root the census held since the process was created.

Members cannot be removed and weights cannot change. Each member also owns a DAVINCI ballot
slot derived from its address, and a registration whose slot is already taken reverts, so
two members never write to the same ballot.

| Contract | Use |
|---|---|
| `OwnedCensus` | Ready to deploy. The owner adds members. |
| `OnchainCensus` | Abstract base with the tree, weights, root history and slot check. Inherit it to write your own admission rules. |

This is the `davinci-zkvm` line, the one the zkVM sequencer and the `OnchainCensus` class of
the [DAVINCI SDK](https://github.com/vocdoni/davinci-sdk) expect. The `main` branch keeps
the older design; see [docs/design.md](docs/design.md) for the differences.

## Quick start

Requires [Foundry](https://getfoundry.sh) and Docker. Start a local anvil chain with an
`OwnedCensus` deployed:

```sh
git clone --recurse-submodules -b davinci-zkvm https://github.com/vocdoni/davinci-onchain-census-contract
cd davinci-onchain-census-contract
docker compose --profile local up -d
```

The chain listens on `http://localhost:8545` (chain id 31337). The census is at
`0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`, owned by anvil's first dev account. Add a
member and read the new root:

```sh
RPC_URL=http://localhost:8545
OWNER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil account 0
CENSUS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

cast send $CENSUS "addMember(address,uint88)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 1 \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
cast call $CENSUS "getCensusRoot()(uint256)" --rpc-url $RPC_URL
```

`docker compose --profile local down` stops the chain and discards it. `ANVIL_PORT` (default
8545), `ANVIL_BLOCK_TIME` (seconds, default 1) and `FOUNDRY_VERSION` (default `v1.8.3`)
override the port, the block time and the Foundry image.

## Usage

### Deploy a census

Run these from the repository root, with `RPC_URL` pointing at your chain and `OWNER_KEY`
holding the key of the account that deploys, and will own, the census.

The census links the `PoseidonT3` library, which has the same address on every EVM chain
because it is deployed through the deterministic deployment proxy. Check that it exists on
your chain, and deploy it once if it does not:

```sh
POSEIDON=0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93
cast code $POSEIDON --rpc-url $RPC_URL  # prints 0x if missing

data=$(sed -n "s/^ *data: '\(0x[0-9a-fA-F]*\)'.*/\1/p" lib/poseidon-solidity/deploy/PoseidonT3.js)
cast send 0x4e59b44847b379578588920ca78fbf26c0b4956c "$data" --rpc-url $RPC_URL --private-key $OWNER_KEY
```

Then deploy an `OwnedCensus`:

```sh
forge create src/OwnedCensus.sol:OwnedCensus --broadcast \
  --rpc-url $RPC_URL --private-key $OWNER_KEY \
  --libraries lib/poseidon-solidity/contracts/PoseidonT3.sol:PoseidonT3:$POSEIDON
```

Ownership is OpenZeppelin `Ownable`: `transferOwnership` hands the census to another
account and `renounceOwnership` freezes it for good.

### Add members

With `CENSUS` set to the address `forge create` printed as `Deployed to`:

```sh
cast send $CENSUS "addMember(address,uint88)" 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 1 \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
cast send $CENSUS "addMembers(address[],uint88[])" \
  "[0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906]" "[2,3]" \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
```

Weights go from 1 to 2^88 - 1. `addMembers` is all or nothing: one rejected entry reverts
the whole call. A registration reverts with:

| Error | Cause |
|---|---|
| `AlreadyRegisteredAddress()` | The address is already a member, or is the zero address. |
| `InvalidCensusWeight()` | The weight is 0. |
| `SlotTaken(address existing)` | `existing` already holds the ballot slot of this address. |
| `LengthMismatch()` | `addMembers` got arrays of different lengths. |
| `OwnableUnauthorizedAccount(address)` | The caller is not the owner. |

### Use it in a voting process

Pass this census to the `ProcessRegistry` when creating the process:

| `Census` field | Value |
|---|---|
| `censusOrigin` | `3` (`MERKLE_TREE_ONCHAIN_DYNAMIC_V1`) |
| `contractAddress` | The census address. |
| `censusRoot` | Ignored: the registry reads the current root from the contract. |
| `censusURI` | Any non-empty string, for example `onchain://<census address>`. |
| `onchainAllowAnyValidRoot` | `false` |

With the TypeScript SDK, `new OnchainCensus(censusAddress)` builds this configuration.

### Write your own census

Inherit `OnchainCensus` and call `_addToCensus(user, weight)`, which returns the new leaf and
root, from your own admission rule.
For example, a census that admits anyone holding a voucher signed by an issuer:

```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OnchainCensus} from "davinci-onchain-census-contract/src/OnchainCensus.sol";

contract VoucherCensus is OnchainCensus {
    error BadVoucher();

    address public immutable issuer;

    constructor(address issuer_) {
        issuer = issuer_;
    }

    function register(uint88 weight, bytes calldata signature) external {
        bytes32 voucher = keccak256(abi.encode(block.chainid, address(this), msg.sender, weight));
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(voucher), signature) != issuer) {
            revert BadVoucher();
        }
        _addToCensus(msg.sender, weight);
    }
}
```

Install the contracts in your Foundry project and add the remappings the base contract
needs (it compiles with your code, on solc 0.8.28):

```sh
forge install vocdoni/davinci-onchain-census-contract@davinci-zkvm
```

```toml
remappings = [
  "davinci-onchain-census-contract/=lib/davinci-onchain-census-contract/",
  "davinci-contracts/=lib/davinci-onchain-census-contract/lib/davinci-contracts/",
  "zk-kit.solidity/=lib/davinci-onchain-census-contract/lib/zk-kit.solidity/",
  "poseidon-solidity/=lib/davinci-onchain-census-contract/lib/poseidon-solidity/contracts/",
  "@openzeppelin/contracts/=lib/davinci-onchain-census-contract/lib/openzeppelin-contracts/contracts/",
]
```

Deploy it like `OwnedCensus`, linking
`lib/davinci-onchain-census-contract/lib/poseidon-solidity/contracts/PoseidonT3.sol:PoseidonT3`.

### Read the census

| Function | Returns |
|---|---|
| `getCensusRoot()` | The current root; 0 while the census is empty. |
| `getRootBlockNumber(root)` | `block.number` for the current root, the block that replaced an older root; 0 for an unknown root or root 0. |
| `getTotalVotingPowerAtRoot(root)` | The total weight at `root`; 0 for an unknown root or root 0. |
| `weightOf(user)` | The member's weight; 0 for a non-member. |
| `leafOf(user)`, `leafFor(user, weight)` | The tree leaf `(address << 88) \| weight`; `leafOf` is 0 for a non-member. |
| `slotOf(user)`, `slotOwner(slot)` | The ballot slot of any address; the member holding a slot. |
| `treeSize()`, `treeDepth()`, `totalVotingPower()` | Member count, tree depth, sum of weights. |

Every registration emits `WeightChanged(account, 0, weight)` and then
`CensusMemberAdded(user, weight, leaf, newRoot, totalVotingPower)`. The member list is the
sequence of `CensusMemberAdded` logs since the block the census was deployed in:

```sh
cast logs --address $CENSUS --from-block $DEPLOY_BLOCK --rpc-url $RPC_URL \
  "CensusMemberAdded(address indexed,uint88,uint256,uint256,uint256)"
```

## Documentation

- [docs/design.md](docs/design.md): leaf and slot encoding, root history, events, what the
  `ProcessRegistry` checks, and the differences from `main`.

## Development

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test
```

`make build`, `make test` and `make fmt` wrap the forge commands, and
`docker compose --profile test run --rm test` runs the CI checks in the Foundry image.
`test/vectors/slot.json` is a copy of davinci-zkvm's `rust-sdk/testdata/slot.json`; refresh
it when those vectors change.

## License

[GNU Affero General Public License v3.0 or later](LICENSE).
