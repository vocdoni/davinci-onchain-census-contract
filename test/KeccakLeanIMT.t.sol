// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {KeccakLeanIMT, KeccakLeanIMTData} from "../src/KeccakLeanIMT.sol";

contract KeccakLeanIMTHarness {
    using KeccakLeanIMT for KeccakLeanIMTData;

    KeccakLeanIMTData private _tree;

    function insert(uint256 leaf) external returns (uint256) {
        return _tree._insert(leaf);
    }

    function root() external view returns (uint256) {
        return _tree._root();
    }

    function size() external view returns (uint256) {
        return _tree.size;
    }

    function depth() external view returns (uint256) {
        return _tree.depth;
    }
}

contract KeccakLeanIMTTest is Test {
    // BN254 scalar field modulus: Keccak roots are not reduced by it.
    uint256 internal constant BN254_R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    KeccakLeanIMTHarness internal tree;

    function setUp() public {
        tree = new KeccakLeanIMTHarness();
    }

    function testEmptyTree() public view {
        assertEq(tree.root(), 0);
        assertEq(tree.size(), 0);
        assertEq(tree.depth(), 0);
    }

    // keccak256(abi.encode(1, 2)), as the SDKs and the guest compute it.
    function testNodeHash() public {
        tree.insert(1);
        assertEq(tree.insert(2), 0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0);
        assertEq(tree.root(), uint256(keccak256(abi.encode(uint256(1), uint256(2)))));
    }

    function testRejectsZeroLeaf() public {
        vm.expectRevert(KeccakLeanIMT.LeafCannotBeZero.selector);
        tree.insert(0);
    }

    function testRejectsLeafFromTwoTo248() public {
        vm.expectRevert(KeccakLeanIMT.LeafTooLarge.selector);
        tree.insert(1 << 248);
        vm.expectRevert(KeccakLeanIMT.LeafTooLarge.selector);
        tree.insert(type(uint256).max);
        // The largest census leaf fits.
        tree.insert((1 << 248) - 1);
        assertEq(tree.size(), 1);
    }

    // davinci-zkvm rust-sdk/testdata/leanimt.json (lean-imt-go with the go-sdk Keccak
    // hasher): the root after every vector size, 1..40, 64, 100, 1000 and 1024 leaves.
    function testRootsMatchSharedVectors() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/leanimt.json"));
        uint256[] memory leaves = vm.parseJsonUintArray(json, ".leaves");
        uint256 inserted;
        uint256 aboveModulus;
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".trees[", vm.toString(n), "]"))) {
            string memory key = string.concat(".trees[", vm.toString(n), "]");
            uint256 size = vm.parseJsonUint(json, string.concat(key, ".size"));
            uint256 want = vm.parseJsonUint(json, string.concat(key, ".root"));
            uint256 got;
            while (inserted < size) {
                got = tree.insert(leaves[inserted++]);
            }
            assertEq(got, want, string.concat("size ", vm.toString(size)));
            assertEq(tree.root(), want);
            if (size == 1) assertEq(want, leaves[0], "single-member root is the leaf");
            if (want >= BN254_R) aboveModulus++;
            n++;
        }
        assertEq(n, 44);
        assertEq(tree.size(), 1024);
        assertEq(tree.depth(), 10);
        assertGt(aboveModulus, 20, "roots above the BN254 modulus");
    }
}
