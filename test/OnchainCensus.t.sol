// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {OnchainCensus} from "../src/OnchainCensus.sol";

contract OnchainCensusHarness is OnchainCensus {
    function addToCensus(address user, uint88 weight) external returns (uint256 leaf, uint256 root) {
        return _addToCensus(user, weight);
    }
}

contract OnchainCensusTest is Test {
    OnchainCensusHarness internal census;

    function setUp() public {
        census = new OnchainCensusHarness();
    }

    function testInitialState() public view {
        assertEq(census.getCensusRoot(), 0);
        assertEq(census.getRootBlockNumber(0), 0);
        assertEq(census.getTotalVotingPowerAtRoot(0), 0);
        assertEq(census.totalVotingPower(), 0);
        assertEq(census.treeSize(), 0);
    }

    function testAddsAddressWithWeight() public {
        address user = address(0x1234);
        uint88 weight = 7;

        (uint256 leaf, uint256 root) = census.addToCensus(user, weight);

        assertEq(leaf, census.leafFor(user, weight));
        assertEq(census.leafOf(user), leaf);
        assertEq(census.weightOf(user), weight);
        assertEq(census.getCensusRoot(), root);
        assertEq(census.getRootBlockNumber(root), block.number);
        assertEq(census.getTotalVotingPowerAtRoot(root), weight);
        assertEq(census.totalVotingPower(), weight);
        assertEq(census.treeSize(), 1);
    }

    function testRejectsZeroAddress() public {
        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addToCensus(address(0), 1);
    }

    function testRejectsZeroWeight() public {
        vm.expectRevert(OnchainCensus.InvalidCensusWeight.selector);
        census.addToCensus(address(0x1234), 0);
    }

    function testRejectsDuplicateAddress() public {
        address user = address(0x1234);

        census.addToCensus(user, 1);

        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addToCensus(user, 2);
    }

    function testTracksHistoricalRootBlockAndTotalPower() public {
        (, uint256 firstRoot) = census.addToCensus(address(0x1234), 2);

        vm.roll(block.number + 3);
        (, uint256 secondRoot) = census.addToCensus(address(0x5678), 5);

        assertEq(census.getCensusRoot(), secondRoot);
        assertEq(census.getRootBlockNumber(firstRoot), block.number);
        assertEq(census.getTotalVotingPowerAtRoot(firstRoot), 2);
        assertEq(census.getRootBlockNumber(secondRoot), block.number);
        assertEq(census.getTotalVotingPowerAtRoot(secondRoot), 7);
        assertEq(census.totalVotingPower(), 7);
    }
}
