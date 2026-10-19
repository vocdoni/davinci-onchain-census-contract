// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Storage of an insert-only Keccak lean incremental Merkle tree.
struct KeccakLeanIMTData {
    // Number of leaves.
    uint256 size;
    // ceil(log2(size)); grows by at most one per insert.
    uint256 depth;
    // Per level, the last node that is a left child; sideNodes[depth] is the root.
    mapping(uint256 => uint256) sideNodes;
}

/// @title Insert-only lean incremental Merkle tree with Keccak-256 nodes.
/// @notice Derived from zk-kit's InternalLeanIMT v2.0.1 (MIT). Same shape: a node
/// without a right sibling moves up unhashed and the root of an empty tree is 0.
/// The node hash is keccak256(abi.encode(left, right)) instead of Poseidon, so nodes
/// and roots are full 256-bit values. Insert only: no batch insert, update or removal,
/// and no leaf-to-index map; OnchainCensus refuses repeated addresses and taken slots.
library KeccakLeanIMT {
    error LeafCannotBeZero();
    error LeafTooLarge();

    /// @dev Inserts `leaf`. It must be non-zero and below 2^248, the shape of a census
    /// leaf `(address << 88) | weight`; the DAVINCI guest enforces the same bound.
    /// @return node The new root.
    function _insert(KeccakLeanIMTData storage self, uint256 leaf) internal returns (uint256 node) {
        if (leaf == 0) revert LeafCannotBeZero();
        if (leaf >> 248 != 0) revert LeafTooLarge();

        uint256 index = self.size;
        uint256 treeDepth = self.depth;
        if ((1 << treeDepth) < index + 1) {
            ++treeDepth;
            self.depth = treeDepth;
        }

        node = leaf;
        for (uint256 level = 0; level < treeDepth;) {
            if ((index >> level) & 1 == 1) {
                node = _hash(self.sideNodes[level], node);
            } else {
                self.sideNodes[level] = node;
            }
            unchecked {
                ++level;
            }
        }

        self.size = index + 1;
        self.sideNodes[treeDepth] = node;
    }

    /// @dev The current root; 0 for an empty tree.
    function _root(KeccakLeanIMTData storage self) internal view returns (uint256) {
        return self.sideNodes[self.depth];
    }

    /// @dev keccak256(abi.encode(left, right)), hashed in scratch space.
    function _hash(uint256 left, uint256 right) private pure returns (uint256 h) {
        assembly ("memory-safe") {
            mstore(0x00, left)
            mstore(0x20, right)
            h := keccak256(0x00, 0x40)
        }
    }
}
