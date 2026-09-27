// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OnchainCensus} from "../src/OnchainCensus.sol";
import {OwnedCensus} from "../src/OwnedCensus.sol";

contract OwnedCensusTest is Test {
    using stdStorage for StdStorage;

    OwnedCensus internal census;

    address internal constant OWNER = address(0xA11CE);
    address internal constant STRANGER = address(0xB0B);

    event CensusMemberAdded(
        address indexed user, uint88 weight, uint256 leaf, uint256 newRoot, uint256 totalVotingPower
    );

    function setUp() public {
        vm.prank(OWNER);
        census = new OwnedCensus();
    }

    function testDeployerIsOwner() public view {
        assertEq(census.owner(), OWNER);
    }

    function testAddMember() public {
        vm.prank(OWNER);
        census.addMember(address(0x1000), 1);

        assertEq(census.weightOf(address(0x1000)), 1);
        assertEq(census.getCensusRoot(), 1267650600228229401496703205377);
        assertEq(census.slotOwner(census.slotOf(address(0x1000))), address(0x1000));
    }

    function testAddMemberOnlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        census.addMember(address(0x1000), 1);
    }

    function testAddMembersOnlyOwner() public {
        address[] memory users = new address[](1);
        uint88[] memory weights = new uint88[](1);
        users[0] = address(0x1000);
        weights[0] = 1;

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        census.addMembers(users, weights);
    }

    // Vector A of the lean-imt-go vectors, inserted in one call; each insert still emits.
    function testAddMembersMatchesVectorA() public {
        address[] memory users = new address[](6);
        uint88[] memory weights = new uint88[](6);
        for (uint256 i = 0; i < 6; i++) {
            users[i] = address(uint160(0x1000 + i));
            weights[i] = uint88(i + 1);
        }

        vm.expectEmit(true, false, false, true, address(census));
        emit CensusMemberAdded(
            users[5],
            6,
            census.leafFor(users[5], 6),
            21654116119424204881355884684087328525315229191070999362500940276414941399884,
            21
        );
        vm.prank(OWNER);
        census.addMembers(users, weights);

        assertEq(census.treeSize(), 6);
        assertEq(census.totalVotingPower(), 21);
        assertEq(census.getCensusRoot(), 21654116119424204881355884684087328525315229191070999362500940276414941399884);
    }

    function testAddMembersLengthMismatch() public {
        address[] memory users = new address[](2);
        uint88[] memory weights = new uint88[](1);

        vm.prank(OWNER);
        vm.expectRevert(OwnedCensus.LengthMismatch.selector);
        census.addMembers(users, weights);
    }

    // One bad entry reverts the whole batch.
    function testAddMembersIsAtomic() public {
        address[] memory users = new address[](3);
        uint88[] memory weights = new uint88[](3);
        users[0] = address(0x1000);
        users[1] = address(0x1001);
        users[2] = address(0x1000);
        weights[0] = 1;
        weights[1] = 1;
        weights[2] = 1;

        vm.prank(OWNER);
        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addMembers(users, weights);

        assertEq(census.treeSize(), 0);
        assertEq(census.getCensusRoot(), 0);
    }

    // Real collisions cost ~2^63/N keygens, so plant `owner` as the owner of `user`'s slot.
    function _plantSlotOwner(address user, address owner) internal {
        stdstore.target(address(census))
            .sig(census.slotOwner.selector)
            .with_key(uint256(census.slotOf(user)))
            .checked_write(owner);
    }

    function testAddMemberRejectsTakenSlot() public {
        address victim = address(0x1000);
        address attacker = address(0x1001);
        vm.prank(OWNER);
        census.addMember(victim, 4);
        uint256 root = census.getCensusRoot();
        _plantSlotOwner(attacker, victim);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, victim));
        census.addMember(attacker, 1);

        assertEq(census.weightOf(attacker), 0);
        assertEq(census.treeSize(), 1);
        assertEq(census.getCensusRoot(), root);
    }

    // A taken slot anywhere in the batch reverts the members before it too.
    function testAddMembersRejectsTakenSlotAtomically() public {
        address victim = address(0x1000);
        address attacker = address(0x1002);
        vm.prank(OWNER);
        census.addMember(victim, 4);
        uint256 root = census.getCensusRoot();
        _plantSlotOwner(attacker, victim);

        address[] memory users = new address[](2);
        uint88[] memory weights = new uint88[](2);
        users[0] = address(0x1001);
        users[1] = attacker;
        weights[0] = 1;
        weights[1] = 1;

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, victim));
        census.addMembers(users, weights);

        assertEq(census.weightOf(users[0]), 0);
        assertEq(census.slotOwner(census.slotOf(users[0])), address(0));
        assertEq(census.treeSize(), 1);
        assertEq(census.getCensusRoot(), root);
        assertEq(census.totalVotingPower(), 4);
    }

    function testAddMemberRejectsZeroWeightAndZeroAddress() public {
        vm.startPrank(OWNER);
        vm.expectRevert(OnchainCensus.InvalidCensusWeight.selector);
        census.addMember(address(0x1000), 0);
        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addMember(address(0), 1);
        vm.stopPrank();
    }

    function testOwnershipTransfer() public {
        vm.prank(OWNER);
        census.transferOwnership(STRANGER);

        vm.prank(STRANGER);
        census.addMember(address(0x1000), 1);
        assertEq(census.treeSize(), 1);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        census.addMember(address(0x1001), 1);
    }
}
