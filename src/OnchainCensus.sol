// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// zk-kit Lean-IMT
import {InternalLeanIMT, LeanIMTData} from "zk-kit.solidity/packages/lean-imt/contracts/InternalLeanIMT.sol";

import {ICensusValidator} from "davinci-contracts/src/interfaces/ICensusValidator.sol";

/// @notice Base contract for on-chain census implementations backed by a Lean-IMT.
/// @dev Implementations should run their own admission guards and call {_addToCensus}.
abstract contract OnchainCensus is ICensusValidator, Ownable {
    using InternalLeanIMT for LeanIMTData;

    // ====================================================
    // Census / weights
    // ====================================================
    LeanIMTData private _tree;

    mapping(address => uint88) public weightOf;
    uint256 private _totalVotingPower;

    // ====================================================
    // Root history (circular buffer of last 100 replaced roots)
    // ====================================================
    uint256 private constant ROOT_HISTORY_SIZE = 100;

    uint256 private _currentRoot;

    uint256[ROOT_HISTORY_SIZE] private _historyRoots;
    uint256[ROOT_HISTORY_SIZE] private _historyLastValidBlock;
    uint256 private _historyIndex;

    mapping(uint256 root => uint256 lastValidBlock) private _rootLastValidBlock;
    mapping(uint256 root => uint256 totalVotingPower) private _rootTotalVotingPower;

    // ====================================================
    // Events / Errors
    // ====================================================
    event CensusMemberAdded(
        address indexed user, uint88 weight, uint256 leaf, uint256 newRoot, uint256 totalVotingPower
    );

    error AlreadyRegisteredAddress();
    error InvalidCensusWeight();

    constructor() Ownable(_msgSender()) {
        _currentRoot = _tree._root();
    }

    // ====================================================
    // ICensusValidator
    // ====================================================

    function getRootBlockNumber(uint256 root) external view override returns (uint256 blockNumber) {
        if (root == 0) return 0;
        if (root == _currentRoot) return block.number;
        return _rootLastValidBlock[root];
    }

    function getCensusRoot() external view override returns (uint256 root) {
        return _currentRoot;
    }

    function getTotalVotingPowerAtRoot(uint256 root) external view override returns (uint256 votingPower) {
        if (root == 0) return 0;
        if (root == _currentRoot) return _totalVotingPower;
        return _rootTotalVotingPower[root];
    }

    // ====================================================
    // Internal: census insertion
    // ====================================================

    function _addToCensus(address user, uint88 weight) internal returns (uint256 leaf, uint256 newRoot) {
        if (user == address(0)) revert AlreadyRegisteredAddress();
        if (weight == 0) revert InvalidCensusWeight();
        if (weightOf[user] != 0) revert AlreadyRegisteredAddress();

        leaf = _packLeaf(user, weight);
        newRoot = _insertAndRotateRoot(leaf, weight);

        uint88 prev = weightOf[user];
        weightOf[user] = weight;
        emit WeightChanged(user, prev, weight);

        emit CensusMemberAdded(user, weight, leaf, newRoot, _totalVotingPower);
    }

    function _insertAndRotateRoot(uint256 leaf, uint88 weight) internal returns (uint256 newRoot) {
        newRoot = _tree._insert(leaf);
        _totalVotingPower += weight;
        _rootTotalVotingPower[newRoot] = _totalVotingPower;

        uint256 oldRoot = _currentRoot;
        if (oldRoot != 0 && oldRoot != newRoot) {
            uint256 lastValidBlock = block.number;

            uint256 evictedRoot = _historyRoots[_historyIndex];
            if (evictedRoot != 0) {
                delete _rootLastValidBlock[evictedRoot];
                delete _rootTotalVotingPower[evictedRoot];
            }

            _historyRoots[_historyIndex] = oldRoot;
            _historyLastValidBlock[_historyIndex] = lastValidBlock;
            _rootLastValidBlock[oldRoot] = lastValidBlock;

            _historyIndex = (_historyIndex + 1) % ROOT_HISTORY_SIZE;
        }

        _currentRoot = newRoot;
    }

    // Convenience getters
    function treeSize() external view returns (uint256) {
        return _tree.size;
    }

    function treeDepth() external view returns (uint256) {
        return _tree.depth;
    }

    function totalVotingPower() external view returns (uint256) {
        return _totalVotingPower;
    }

    function leafOf(address user) external view returns (uint256) {
        uint88 weight = weightOf[user];
        if (weight == 0) return 0;
        return _packLeaf(user, weight);
    }

    function leafFor(address user, uint88 weight) external pure returns (uint256) {
        return _packLeaf(user, weight);
    }

    function _packLeaf(address account, uint88 weight) internal pure returns (uint256) {
        return (uint256(uint160(account)) << 88) | uint256(weight);
    }
}
