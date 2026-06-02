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

The function inserts the packed leaf into the Lean-IMT, updates root history, stores the account weight, snapshots total voting power, emits `WeightChanged`, and emits `CensusMemberAdded`.

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

`OnchainCensus` is abstract, so it cannot be deployed directly. Deploy a concrete contract that inherits it.

## License

AGPL-3.0-or-later
