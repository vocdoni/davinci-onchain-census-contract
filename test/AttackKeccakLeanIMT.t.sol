// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {KeccakLeanIMT} from "../src/KeccakLeanIMT.sol";
import {KeccakLeanIMTHarness} from "./KeccakLeanIMT.t.sol";

/// @dev Off-chain lean IMT, rebuilt from all leaves: pair nodes level by level from the left,
///      an odd last node moves up unhashed, node = keccak256(be32 l || be32 r), root of the
///      empty tree 0. Written independently of the incremental side-node algorithm.
library LeanIMTRef {
    function hash(uint256 l, uint256 r) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(l, r)));
    }

    /// @dev Root over leaves[0..n).
    function root(uint256[] memory leaves, uint256 n) internal pure returns (uint256) {
        if (n == 0) return 0;
        uint256[] memory level = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            level[i] = leaves[i];
        }
        uint256 len = n;
        while (len > 1) {
            // In place: level[i] is written after level[2i], level[2i+1] are read.
            for (uint256 i = 0; i < len / 2; ++i) {
                level[i] = hash(level[2 * i], level[2 * i + 1]);
            }
            if (len % 2 == 1) level[len / 2] = level[len - 1];
            len = (len + 1) / 2;
        }
        return level[0];
    }

    /// @dev ceil(log2(n)), 0 for n <= 1.
    function depth(uint256 n) internal pure returns (uint256 d) {
        while ((uint256(1) << d) < n) ++d;
    }
}

/// @dev Adversarial tests of the bare KeccakLeanIMT: the incremental root against the
///      reference rebuilt from every leaf, the leaf bounds the guest mirrors, and insert gas
///      at depths far beyond any census the tests can build.
contract AttackKeccakLeanIMTTest is Test {
    uint256 internal constant BN254_R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant MAX_LEAF = (uint256(1) << 248) - 1;

    KeccakLeanIMTHarness internal tree;

    function setUp() public {
        tree = new KeccakLeanIMTHarness();
    }

    // --- the reference itself --------------------------------------------------------

    /// The reference reproduces every root of the shared lean-imt-go vectors, so it is a
    /// valid oracle for the fuzz tests below.
    function test_ReferenceMatchesSharedVectors() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/leanimt.json"));
        uint256[] memory leaves = vm.parseJsonUintArray(json, ".leaves");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".trees[", vm.toString(n), "]"))) {
            string memory key = string.concat(".trees[", vm.toString(n), "]");
            uint256 size = vm.parseJsonUint(json, string.concat(key, ".size"));
            assertEq(LeanIMTRef.root(leaves, size), vm.parseJsonUint(json, string.concat(key, ".root")), key);
            n++;
        }
        assertEq(n, 44);
    }

    // --- incremental tree against the reference --------------------------------------

    /// @dev Pseudo-random leaves with the edge values mixed in: 1, 2, the largest census
    ///      leaf and its neighbours, and a repeat of an earlier leaf (the bare tree accepts
    ///      repeats). Every leaf is below 2^248 < r, so leaves are field elements; nodes and
    ///      roots are not.
    function _leaf(uint256 seed, uint256 i, uint256[] memory prev) internal pure returns (uint256) {
        uint256 r = uint256(keccak256(abi.encode(seed, i)));
        uint256 kind = r % 11;
        if (kind == 0) return 1;
        if (kind == 1) return MAX_LEAF;
        if (kind == 2 && i > 0) return prev[(r >> 8) % i];
        if (kind == 3) return 2;
        if (kind == 4) return MAX_LEAF - 1;
        if (kind == 5) return uint256(1) << 247;
        return (r >> 8) == 0 ? 1 : r >> 8; // below 2^248
    }

    /// The root returned by every insert equals the reference root of the prefix, and size and
    /// depth follow ceil(log2(size)).
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_EveryPrefixMatchesReference(uint256 seed, uint256 n) public {
        n = bound(n, 1, 96);
        uint256[] memory leaves = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = _leaf(seed, i, leaves);
            uint256 got = tree.insert(leaves[i]);
            assertEq(got, LeanIMTRef.root(leaves, i + 1), "insert root");
            assertEq(tree.root(), got, "stored root");
            assertEq(tree.size(), i + 1, "size");
            assertEq(tree.depth(), LeanIMTRef.depth(i + 1), "depth");
        }
    }

    /// Larger trees, checked at the power-of-two boundaries where the depth grows.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_LargeTreeAtDepthBoundaries(uint256 seed, uint256 n) public {
        n = bound(n, 257, 1100);
        uint256[] memory leaves = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = _leaf(seed, i, leaves);
            uint256 got = tree.insert(leaves[i]);
            uint256 size = i + 1;
            bool boundary = _pow2(size) || _pow2(size + 1) || (size > 1 && _pow2(size - 1));
            if (boundary || size == n) {
                assertEq(got, LeanIMTRef.root(leaves, size), "root at boundary");
                assertEq(tree.depth(), LeanIMTRef.depth(size), "depth at boundary");
            }
        }
    }

    function _pow2(uint256 x) internal pure returns (bool) {
        return x != 0 && (x & (x - 1)) == 0;
    }

    /// A one-leaf tree's root is the leaf itself, for every leaf value.
    function testFuzz_SingleLeafRootIsTheLeaf(uint256 leaf) public {
        leaf = bound(leaf, 1, MAX_LEAF);
        assertEq(tree.insert(leaf), leaf);
        assertEq(tree.depth(), 0);
    }

    /// Insertion order matters: swapping two distinct leaves changes the root (the tree is
    /// positional, so a member cannot be proven at another index).
    function testFuzz_OrderMatters(uint256 a, uint256 b) public {
        a = bound(a, 1, MAX_LEAF);
        b = bound(b, 1, MAX_LEAF);
        vm.assume(a != b);
        tree.insert(a);
        uint256 ab = tree.insert(b);
        KeccakLeanIMTHarness other = new KeccakLeanIMTHarness();
        other.insert(b);
        assertTrue(other.insert(a) != ab);
    }

    // --- leaf bounds -----------------------------------------------------------------

    /// Exactly [1, 2^248 - 1] is accepted; a refused leaf leaves size, depth and root as
    /// they were.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_LeafBounds(uint256 leaf, uint8 before) public {
        before = uint8(bound(before, 0, 9));
        for (uint256 i = 0; i < before; ++i) {
            tree.insert(i + 1);
        }
        uint256 size = tree.size();
        uint256 depth = tree.depth();
        uint256 root = tree.root();
        if (leaf == 0) {
            vm.expectRevert(KeccakLeanIMT.LeafCannotBeZero.selector);
            tree.insert(leaf);
        } else if (leaf > MAX_LEAF) {
            vm.expectRevert(KeccakLeanIMT.LeafTooLarge.selector);
            tree.insert(leaf);
        } else {
            tree.insert(leaf);
            assertEq(tree.size(), size + 1);
            return;
        }
        assertEq(tree.size(), size);
        assertEq(tree.depth(), depth);
        assertEq(tree.root(), root);
    }

    function test_LeafEdgeValues() public {
        // BN254_R is above 2^248: no leaf reaches the field modulus.
        uint256[6] memory refused =
            [uint256(0), uint256(1) << 248, (uint256(1) << 248) + 1, BN254_R, type(uint256).max, uint256(1) << 255];
        for (uint256 i = 0; i < refused.length; ++i) {
            (bool ok,) = address(tree).call(abi.encodeCall(tree.insert, (refused[i])));
            assertFalse(ok, vm.toString(refused[i]));
        }
        assertEq(tree.size(), 0);
        uint256[] memory leaves = new uint256[](3);
        (leaves[0], leaves[1], leaves[2]) = (1, MAX_LEAF, MAX_LEAF);
        for (uint256 i = 0; i < 3; ++i) {
            tree.insert(leaves[i]);
        }
        assertEq(tree.root(), LeanIMTRef.root(leaves, 3));
        // The root is a full 256-bit value, not reduced modulo the BN254 field.
        assertGt(tree.root(), BN254_R);
    }

    // --- insert gas at large sizes ---------------------------------------------------

    // Harness storage: _tree.size at slot 0, _tree.depth at slot 1, _tree.sideNodes at 2.
    function _plant(uint256 size, uint256 depth) internal {
        vm.store(address(tree), bytes32(uint256(0)), bytes32(size));
        vm.store(address(tree), bytes32(uint256(1)), bytes32(depth));
        for (uint256 l = 0; l <= depth; ++l) {
            vm.store(address(tree), keccak256(abi.encode(l, uint256(2))), bytes32(uint256(keccak256(abi.encode(l)))));
        }
        assertEq(tree.size(), size, "size slot moved");
        assertEq(tree.depth(), depth, "depth slot moved");
    }

    function _insertGas(uint256 leaf) internal returns (uint256 gas) {
        uint256 g = gasleft();
        tree.insert(leaf);
        gas = g - gasleft();
    }

    /// Insert gas grows linearly with the depth and stays far below any block limit, both
    /// in the all-hash case (index 2^k - 1) and the all-store case (index 2^k, depth grows).
    function test_InsertGasAtPlantedDepths() public {
        uint8[6] memory ks = [8, 16, 24, 32, 48, 63];
        for (uint256 i = 0; i < ks.length; ++i) {
            uint256 k = ks[i];
            tree = new KeccakLeanIMTHarness();
            _plant((uint256(1) << k) - 1, k);
            uint256 hashGas = _insertGas(7);
            assertEq(tree.depth(), k);
            uint256 storeGas = _insertGas(9);
            assertEq(tree.depth(), k + 1, "depth grows at a power of two");
            assertEq(tree.size(), (uint256(1) << k) + 1);
            console.log("depth", k, hashGas, storeGas);
            assertLt(hashGas, 40_000 + 3_000 * k, "all-hash insert");
            assertLt(storeGas, 60_000 + 8_000 * k, "all-store insert");
        }
    }

    /// The node at a power-of-two boundary is the old root hashed with the new leaf, also at
    /// planted depths.
    function test_PlantedBoundaryRoot() public {
        _plant((uint256(1) << 40), 40);
        uint256 oldRoot = tree.root();
        // Index 2^40: bits 0..39 are zero, bit 40 is one, so the new leaf moves up to level 40
        // unhashed and is hashed with the old root there.
        assertEq(tree.insert(5), LeanIMTRef.hash(oldRoot, 5));
        assertEq(tree.depth(), 41);
    }
}
