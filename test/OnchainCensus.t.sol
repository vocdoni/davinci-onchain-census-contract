// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";

import {ICensusValidator} from "davinci-contracts/src/interfaces/ICensusValidator.sol";

import {OnchainCensus} from "../src/OnchainCensus.sol";
import {KeccakLeanIMTHarness} from "./KeccakLeanIMT.t.sol";

contract OnchainCensusHarness is OnchainCensus {
    function addToCensus(address user, uint88 weight) external returns (uint256 leaf, uint256 root) {
        return _addToCensus(user, weight);
    }
}

contract OnchainCensusTest is Test {
    using stdStorage for StdStorage;

    OnchainCensusHarness internal census;

    event CensusMemberAdded(
        address indexed user, uint88 weight, uint256 leaf, uint256 newRoot, uint256 totalVotingPower
    );

    uint64 internal constant SLOT_MIN = 0x10;
    uint64 internal constant SLOT_MAX = uint64(type(uint64).max >> 1); // 2^63 - 1

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
        assertEq(census.slotOwner(census.slotOf(user)), user);
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

    // ------------------------------------------------------------------
    // lean-imt-go vectors (go-sdk KeccakHasher)
    // ------------------------------------------------------------------

    // Vector A: member i is address 0x1000+i with weight i+1. Roots 1..5 are above the
    // BN254 modulus.
    function testRootsMatchLeanImtGoVectorA() public {
        uint256[6] memory want = [
            uint256(1267650600228229401496703205377),
            105792291677795102622622719249240717138379594905581414561624949922989669084701,
            40440525674650805399022830324082008292857011586528737744254297238571467994890,
            47816645326343429212834647734977538926977696183042526155951616149923679937003,
            89441866141586882830905230501830576803437259706165543977322595200906102220797,
            78853546982023441117728848780497158261952210388852847806633614818970076149765
        ];
        for (uint256 i = 0; i < want.length; i++) {
            (, uint256 root) = census.addToCensus(address(uint160(0x1000 + i)), uint88(i + 1));
            assertEq(root, want[i]);
            assertEq(census.getCensusRoot(), want[i]);
        }
        assertEq(census.treeDepth(), 3);
    }

    // Vector B: davinci-node solidity_compatibility_test.go.
    function testRootMatchesDavinciNodeVectorB() public {
        address[5] memory users = [
            0x11311A2D24a77b6722D7F149B1D9C07C9Bdea16c,
            0xdeb8699659bE5d41a0e57E179d6cB42E00B9200C,
            0xB1F05B11Ba3d892EdD00f2e7689779E2B8841827,
            0xf3B06b503652a5E075D423F97056DFde0C4b066F,
            0x74D8967e812de34702eCD3D453a44bf37440b10b
        ];
        uint88[5] memory weights = [uint88(3), 5, 10, 1, 3];
        for (uint256 i = 0; i < users.length; i++) {
            census.addToCensus(users[i], weights[i]);
        }
        assertEq(census.leafOf(users[0]), 30375291384970416511893979679789548485304528155904142667949947072733511683);
        assertEq(census.getCensusRoot(), 67734935619498903356943765458459728301261057922995153565775884106586481773780);
    }

    // Vector C: raw leaves 1..5. They are not packed (address, weight) leaves (address 0),
    // so they go through the bare Keccak tree the census wraps.
    function testRawLeavesMatchLeanImtGoVectorC() public {
        KeccakLeanIMTHarness tree = new KeccakLeanIMTHarness();
        uint256[5] memory want = [
            uint256(1),
            105409183525425523237923285454331214386340807945685310246717412709691342439136,
            41284475257234908792700626306985277197652811982708732094152184811704779637787,
            76772239757923229513585688451142950403869359304189514133944008798130633149750,
            82250816769484612374681573293034782788002610942745044852337906653714271241558
        ];
        for (uint256 i = 0; i < want.length; i++) {
            assertEq(tree.insert(i + 1), want[i]);
        }
    }

    // ------------------------------------------------------------------
    // Address-derived ballot slots
    // ------------------------------------------------------------------

    // Shared vectors: a copy of davinci-zkvm rust-sdk/testdata/slot.json, which the Go and
    // Rust SDKs check too.
    function testSlotOfSharedVectors() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/slot.json"));
        assertEq(vm.parseJsonString(json, ".tag"), "davinci-slot-v1");

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".slots[", vm.toString(n), "]"))) {
            string memory entry = string.concat(".slots[", vm.toString(n), "]");
            address user =
                vm.parseAddress(string.concat("0x", vm.parseJsonString(json, string.concat(entry, ".address"))));
            assertEq(uint256(census.slotOf(user)), vm.parseJsonUint(json, string.concat(entry, ".slot")));
            n++;
        }
        assertGt(n, 0, "no slot vectors");
    }

    function testFuzzSlotOfInBallotRange(address user) public view {
        uint64 slot = census.slotOf(user);
        assertGe(slot, SLOT_MIN);
        assertLe(slot, SLOT_MAX);
        uint256 prefix = uint256(sha256(bytes.concat(bytes15("davinci-slot-v1"), bytes20(user)))) >> 192;
        assertEq(uint256(slot), 0x10 + prefix % ((uint256(1) << 63) - 16));
    }

    function testRecordsSlotOwnerPerMember() public {
        address a = address(0x1000);
        address b = address(0x1001);
        census.addToCensus(a, 1);
        census.addToCensus(b, 2);
        assertEq(census.slotOwner(census.slotOf(a)), a);
        assertEq(census.slotOwner(census.slotOf(b)), b);
        assertEq(census.slotOwner(census.slotOf(address(0x1002))), address(0));
    }

    function testRejectsTakenSlot() public {
        address victim = address(0x1000);
        address attacker = address(0x1001);
        (, uint256 root) = census.addToCensus(victim, 4);

        // Real collisions cost ~2^63/N keygens, so plant the victim as the attacker's slot owner.
        stdstore.target(address(census))
            .sig(census.slotOwner.selector)
            .with_key(uint256(census.slotOf(attacker)))
            .checked_write(victim);

        vm.expectRevert(abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, victim));
        census.addToCensus(attacker, 1);

        assertEq(census.weightOf(attacker), 0);
        assertEq(census.treeSize(), 1);
        assertEq(census.getCensusRoot(), root);
        assertEq(census.totalVotingPower(), 4);
    }

    // ------------------------------------------------------------------
    // Root history: no eviction
    // ------------------------------------------------------------------

    function testKeepsEveryReplacedRootAfter150Inserts() public {
        uint256 n = 150;
        uint256 start = 1000;
        uint256[] memory roots = new uint256[](n);
        uint256[] memory power = new uint256[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            vm.roll(start + i);
            (, roots[i]) = census.addToCensus(address(uint160(0x1000 + i)), uint88(i + 1));
            total += i + 1;
            power[i] = total;
        }

        vm.roll(start + n + 10);
        uint256 head = vm.getBlockNumber();

        // Root i was replaced by insert i+1, in block start+i+1.
        for (uint256 i = 0; i + 1 < n; i++) {
            assertEq(census.getRootBlockNumber(roots[i]), start + i + 1);
            assertEq(census.getTotalVotingPowerAtRoot(roots[i]), power[i]);
        }
        assertEq(census.getRootBlockNumber(roots[0]), start + 1, "oldest root evicted");
        assertEq(census.getRootBlockNumber(roots[n - 1]), head);
        assertEq(census.getTotalVotingPowerAtRoot(roots[n - 1]), total);
        assertEq(census.getRootBlockNumber(0xdead), 0);
        assertEq(census.getTotalVotingPowerAtRoot(0xdead), 0);
    }

    function testSameBlockInsertsShareLastValidBlock() public {
        vm.roll(50);
        (, uint256 r0) = census.addToCensus(address(0x1000), 1);
        (, uint256 r1) = census.addToCensus(address(0x1001), 1);
        (, uint256 r2) = census.addToCensus(address(0x1002), 1);
        vm.roll(60);
        assertEq(census.getRootBlockNumber(r0), 50);
        assertEq(census.getRootBlockNumber(r1), 50);
        assertEq(census.getRootBlockNumber(r2), 60);
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    function testEmitsWeightChangedThenMemberAdded() public {
        address a = address(0x1000);
        address b = address(0x1001);
        uint256 rootA = 1267650600228229401496703205377;
        uint256 rootB = 105792291677795102622622719249240717138379594905581414561624949922989669084701;

        vm.expectEmit(true, false, false, true, address(census));
        emit ICensusValidator.WeightChanged(a, 0, 1);
        vm.expectEmit(true, false, false, true, address(census));
        emit CensusMemberAdded(a, 1, census.leafFor(a, 1), rootA, 1);
        census.addToCensus(a, 1);

        vm.expectEmit(true, false, false, true, address(census));
        emit ICensusValidator.WeightChanged(b, 0, 2);
        vm.expectEmit(true, false, false, true, address(census));
        emit CensusMemberAdded(b, 2, census.leafFor(b, 2), rootB, 3);
        census.addToCensus(b, 2);
    }
}
