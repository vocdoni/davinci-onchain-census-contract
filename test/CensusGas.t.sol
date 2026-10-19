// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {OwnedCensus} from "../src/OwnedCensus.sol";

/// Gas of the addMember call that brings the tree to a given size.
/// `forge test --mc CensusGasTest -vv` prints the table README.md records.
contract CensusGasTest is Test {
    function _gasOfInsert(uint256 size) internal returns (uint256) {
        OwnedCensus census = new OwnedCensus();
        for (uint256 i = 1; i < size; i++) {
            census.addMember(address(uint160(0x10000 + i)), 1);
        }
        census.addMember(address(uint160(0x10000 + size)), 1);
        return vm.lastCallGas().gasTotalUsed;
    }

    function testGasAddMemberBySize() public {
        // With the Poseidon tree (4eb302e) these were 212775, 228787, 259570 and 395034.
        uint256[4] memory sizes = [uint256(1), 2, 16, 1024];
        uint256[4] memory poseidon = [uint256(212775), 228787, 259570, 395034];
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 gas = _gasOfInsert(sizes[i]);
            console.log("addMember gas, tree size", sizes[i], gas);
            assertLt(gas, poseidon[i], "insert no cheaper than with the Poseidon tree");
        }
    }
}
