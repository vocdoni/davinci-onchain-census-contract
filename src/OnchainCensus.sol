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

    // Private (with explicit getters) so a derived contract cannot clear a member and
    // register it again, or free a slot for a colliding address.
    mapping(address => uint88) private _weightOf;
    uint256 private _totalVotingPower;

    // ====================================================
    // DAVINCI ballot slots
    // ====================================================
    // slot = 0x10 + be64(sha256("davinci-slot-v1" || address)[0..8]) mod (2^63 - 16),
    // the Merkle-census ballot key the davinci-zkvm guest derives from the voter address.
    bytes15 private constant SLOT_DOMAIN = "davinci-slot-v1";
    uint64 private constant SLOT_MIN = 0x10;
    uint64 private constant SLOT_MODULUS = uint64((1 << 63) - 16);

    mapping(uint64 slot => address owner) private _slotOwner;

    // ====================================================
    // Root history (every replaced root, never evicted)
    // ====================================================
    // The census is append-only with fixed weights, so an old root is a subset of the
    // current one and dropping it buys no soundness; it would only make settlement of a
    // batch proved against it revert after a burst of registrations.
    uint256 private _currentRoot;

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
    error SlotTaken(address existing);

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
        if (_weightOf[user] != 0) revert AlreadyRegisteredAddress();

        // Two members on one slot would overwrite each other's ballots.
        uint64 slot = slotOf(user);
        address existing = _slotOwner[slot];
        if (existing != address(0)) revert SlotTaken(existing);
        _slotOwner[slot] = user;

        leaf = _packLeaf(user, weight);
        newRoot = _insertAndRotateRoot(leaf, weight);

        uint88 prev = _weightOf[user];
        _weightOf[user] = weight;
        emit WeightChanged(user, prev, weight);

        emit CensusMemberAdded(user, weight, leaf, newRoot, _totalVotingPower);
    }

    // Private so every insert goes through {_addToCensus} and its events.
    function _insertAndRotateRoot(uint256 leaf, uint88 weight) private returns (uint256 newRoot) {
        newRoot = _tree._insert(leaf);
        _totalVotingPower += weight;
        _rootTotalVotingPower[newRoot] = _totalVotingPower;

        uint256 oldRoot = _currentRoot;
        if (oldRoot != 0 && oldRoot != newRoot) {
            _rootLastValidBlock[oldRoot] = block.number;
        }

        _currentRoot = newRoot;
    }

    // Convenience getters
    function weightOf(address user) external view returns (uint88) {
        return _weightOf[user];
    }

    function slotOwner(uint64 slot) external view returns (address owner) {
        return _slotOwner[slot];
    }

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
        uint88 weight = _weightOf[user];
        if (weight == 0) return 0;
        return _packLeaf(user, weight);
    }

    function leafFor(address user, uint88 weight) external pure returns (uint256) {
        return _packLeaf(user, weight);
    }

    /// @notice DAVINCI ballot slot of `user`, in [0x10, 2^63 - 1].
    function slotOf(address user) public pure returns (uint64) {
        bytes32 digest = sha256(abi.encodePacked(SLOT_DOMAIN, user));
        // forge-lint: disable-next-line(unsafe-typecast) first 8 digest bytes, big-endian
        return SLOT_MIN + uint64(bytes8(digest)) % SLOT_MODULUS;
    }

    function _packLeaf(address account, uint88 weight) internal pure returns (uint256) {
        return (uint256(uint160(account)) << 88) | uint256(weight);
    }
}
