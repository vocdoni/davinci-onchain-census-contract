// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICensusValidator} from "davinci-contracts/src/interfaces/ICensusValidator.sol";

import {OnchainCensus} from "../src/OnchainCensus.sol";
import {OwnedCensus} from "../src/OwnedCensus.sol";
import {LeanIMTRef} from "./AttackKeccakLeanIMT.t.sol";

/// @dev What the census emits and stores, rebuilt by a reader that only has the logs.
library CensusEvents {
    bytes32 internal constant WEIGHT_CHANGED = keccak256("WeightChanged(address,uint88,uint88)");
    bytes32 internal constant MEMBER_ADDED = keccak256("CensusMemberAdded(address,uint88,uint256,uint256,uint256)");
}

/// @dev Random owner and stranger registrations (single and batched, with repeated, zero
///      and colliding entries) and block moves, checked call by call against a model: the
///      member list, the slot owners, every root the census ever had with its last valid
///      block and voting power, and the exact events. The model's root is the reference
///      lean IMT rebuilt from the member leaves.
contract CensusHandler is Test {
    using stdStorage for StdStorage;

    address internal constant STRANGER = address(0xB0B);
    uint256 internal constant POOL = 48;

    OwnedCensus public immutable census;

    // Members in insertion order.
    address[] public members;
    uint256[] public leaves;
    mapping(address => uint88) public weightOf;
    mapping(uint64 => address) public slotOwner;
    uint256 public total;

    // Every root, oldest first; lastValid is 0 while the root is current.
    uint256[] public roots;
    mapping(uint256 => uint256) public lastValid;
    mapping(uint256 => uint256) public powerAt;

    uint256 public violations;
    string public firstViolation;
    mapping(string => uint256) public successes;

    constructor() {
        census = new OwnedCensus();
    }

    function rootCount() external view returns (uint256) {
        return roots.length;
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function modelRoot() public view returns (uint256) {
        return LeanIMTRef.root(leaves, leaves.length);
    }

    function _fail(string memory what) internal {
        if (violations == 0) firstViolation = what;
        violations++;
    }

    /// @dev A small address pool so repeats are frequent, plus the zero address and the
    ///      two extreme addresses.
    function _user(uint256 seed) internal pure returns (address) {
        uint256 k = seed % (POOL + 3);
        if (k == POOL) return address(0);
        if (k == POOL + 1) return address(1);
        if (k == POOL + 2) return address(type(uint160).max);
        return address(uint160(uint256(keccak256(abi.encode("member", k)))));
    }

    function _weight(uint256 seed) internal pure returns (uint88) {
        uint256 k = seed % 13;
        if (k == 0) return 0;
        if (k == 1) return 1;
        if (k == 2) return type(uint88).max;
        return uint88(uint256(keccak256(abi.encode("weight", seed))));
    }

    /// @dev The error the census must raise for (user, weight) given the model, or empty.
    function _expectedError(address user, uint88 weight) internal view returns (bytes memory) {
        if (user == address(0)) return abi.encodeWithSelector(OnchainCensus.AlreadyRegisteredAddress.selector);
        if (weight == 0) return abi.encodeWithSelector(OnchainCensus.InvalidCensusWeight.selector);
        if (weightOf[user] != 0) return abi.encodeWithSelector(OnchainCensus.AlreadyRegisteredAddress.selector);
        address existing = slotOwner[census.slotOf(user)];
        if (existing != address(0)) return abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, existing);
        return "";
    }

    /// @dev Applies one accepted registration to the model and checks its two logs.
    function _apply(address user, uint88 weight, Vm.Log[] memory logs, uint256 at) internal {
        uint256 leaf = (uint256(uint160(user)) << 88) | weight;
        members.push(user);
        leaves.push(leaf);
        weightOf[user] = weight;
        slotOwner[census.slotOf(user)] = user;
        total += weight;
        uint256 newRoot = LeanIMTRef.root(leaves, leaves.length);
        if (roots.length > 0) lastValid[roots[roots.length - 1]] = vm.getBlockNumber();
        roots.push(newRoot);
        powerAt[newRoot] = total;

        if (logs.length < at + 2) return _fail("missing logs");
        Vm.Log memory w = logs[at];
        Vm.Log memory a = logs[at + 1];
        if (w.emitter != address(census) || a.emitter != address(census)) return _fail("log emitter");
        if (w.topics[0] != CensusEvents.WEIGHT_CHANGED || a.topics[0] != CensusEvents.MEMBER_ADDED) {
            return _fail("log order: WeightChanged then CensusMemberAdded");
        }
        if (w.topics[1] != bytes32(uint256(uint160(user))) || a.topics[1] != bytes32(uint256(uint160(user)))) {
            return _fail("log user");
        }
        (uint88 prev, uint88 next) = abi.decode(w.data, (uint88, uint88));
        if (prev != 0 || next != weight) return _fail("WeightChanged values");
        (uint88 lw, uint256 lleaf, uint256 lroot, uint256 ltotal) =
            abi.decode(a.data, (uint88, uint256, uint256, uint256));
        if (lw != weight || lleaf != leaf || lroot != newRoot || ltotal != total) {
            return _fail("CensusMemberAdded values");
        }
    }

    // --- actions ---------------------------------------------------------------------

    function addMember(uint256 us, uint256 ws, bool stranger) external {
        address user = _user(us);
        uint88 weight = _weight(ws);
        bytes memory want = stranger
            ? abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER)
            : _expectedError(user, weight);
        vm.recordLogs();
        if (stranger) vm.prank(STRANGER);
        (bool ok, bytes memory ret) = address(census).call(abi.encodeCall(census.addMember, (user, weight)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (want.length == 0) {
            if (!ok) return _fail("addMember refused, model accepts");
            successes["addMember"]++;
            if (logs.length != 2) return _fail("addMember log count");
            _apply(user, weight, logs, 0);
        } else {
            if (ok) return _fail("addMember accepted, model refuses");
            // Logs of a reverted call are recorded by forge but dropped by the EVM.
            if (keccak256(ret) != keccak256(want)) _fail("addMember revert reason");
        }
    }

    /// A batch of up to 6 entries: all accepted in order or the whole call reverts with the
    /// first bad entry's error.
    function addMembers(uint256 seed, uint256 len, bool stranger, bool mismatch) external {
        len = bound(len, 0, 6);
        address[] memory users = new address[](len);
        uint88[] memory weights = new uint88[](mismatch ? len + 1 : len);
        for (uint256 i = 0; i < len; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // Repeat an earlier entry of the same batch now and then.
            users[i] = (i > 0 && r % 7 == 0) ? users[r % i] : _user(r);
            weights[i] = _weight(r >> 128);
        }

        // Predict sequentially on a scratch copy of the model.
        bytes memory want;
        if (stranger) {
            want = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER);
        } else if (mismatch) {
            want = abi.encodeWithSelector(OwnedCensus.LengthMismatch.selector);
        } else {
            for (uint256 i = 0; i < len && want.length == 0; ++i) {
                want = _expectedErrorInBatch(users, weights, i);
            }
        }

        vm.recordLogs();
        if (stranger) vm.prank(STRANGER);
        (bool ok, bytes memory ret) = address(census).call(abi.encodeCall(census.addMembers, (users, weights)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (want.length == 0) {
            if (!ok) return _fail("addMembers refused, model accepts");
            successes["addMembers"]++;
            if (logs.length != 2 * len) return _fail("addMembers log count");
            for (uint256 i = 0; i < len; ++i) {
                _apply(users[i], weights[i], logs, 2 * i);
            }
        } else {
            if (ok) return _fail("addMembers accepted, model refuses");
            if (keccak256(ret) != keccak256(want)) _fail("addMembers revert reason");
        }
    }

    /// @dev _expectedError for entry i, as if entries 0..i-1 of the batch had been applied.
    function _expectedErrorInBatch(address[] memory users, uint88[] memory weights, uint256 i)
        internal
        view
        returns (bytes memory)
    {
        address user = users[i];
        if (user != address(0) && weights[i] != 0) {
            uint64 slot = census.slotOf(user);
            for (uint256 j = 0; j < i; ++j) {
                if (users[j] == user) return abi.encodeWithSelector(OnchainCensus.AlreadyRegisteredAddress.selector);
                if (census.slotOf(users[j]) == slot) {
                    return abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, users[j]);
                }
            }
        }
        return _expectedError(user, weights[i]);
    }

    /// Simulates a ballot-slot collision (2^63/N key generations in reality): the slot of a
    /// pool address that is not a member is given to an existing member, or to an address
    /// that is no member at all.
    function plantCollision(uint256 us, uint256 os, bool garbage) external {
        address user = _user(us);
        if (user == address(0) || weightOf[user] != 0) return;
        uint64 slot = census.slotOf(user);
        if (slotOwner[slot] != address(0)) return;
        address owner;
        if (garbage) {
            owner = address(uint160(uint256(keccak256(abi.encode("garbage", os)))));
        } else {
            if (members.length == 0) return;
            owner = members[os % members.length];
        }
        stdstore.target(address(census)).sig(census.slotOwner.selector).with_key(uint256(slot)).checked_write(owner);
        slotOwner[slot] = owner;
    }

    function roll(uint256 n) external {
        vm.roll(vm.getBlockNumber() + bound(n, 0, 4));
    }
}

contract AttackOnchainCensusInvariantTest is Test {
    uint256 internal constant BN254_R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    CensusHandler internal handler;
    OwnedCensus internal census;

    function setUp() public {
        handler = new CensusHandler();
        census = handler.census();
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = CensusHandler.addMember.selector;
        sel[1] = CensusHandler.addMember.selector;
        sel[2] = CensusHandler.addMembers.selector;
        sel[3] = CensusHandler.plantCollision.selector;
        sel[4] = CensusHandler.roll.selector;
        sel[5] = CensusHandler.roll.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// The handler is not vacuous: every run lands registrations.
    function afterInvariant() public view {
        assertGt(handler.successes("addMember") + handler.successes("addMembers"), 0, "no registration landed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_EveryCallMatchesTheModel() public view {
        assertEq(handler.violations(), 0, handler.firstViolation());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TreeMatchesTheReference() public view {
        uint256 n = handler.memberCount();
        assertEq(census.treeSize(), n, "size");
        assertEq(census.treeDepth(), LeanIMTRef.depth(n), "depth");
        assertEq(census.getCensusRoot(), handler.modelRoot(), "root");
        assertEq(census.totalVotingPower(), handler.total(), "total voting power");
        for (uint256 i = 0; i < n; ++i) {
            address m = handler.members(i);
            uint88 w = handler.weightOf(m);
            assertEq(census.weightOf(m), w, "weight");
            assertEq(census.leafOf(m), handler.leaves(i), "leaf");
            assertEq(census.leafOf(m), census.leafFor(m, w), "leafOf vs leafFor");
            assertEq(census.slotOwner(census.slotOf(m)), m, "slot owner");
        }
    }

    /// Every root the census ever had answers the ICensusValidator semantics the registry
    /// relies on, and no root aliases modulo the BN254 field.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_RootHistory() public view {
        uint256 k = handler.rootCount();
        for (uint256 i = 0; i < k; ++i) {
            uint256 root = handler.roots(i);
            bool current = i + 1 == k;
            assertEq(
                census.getRootBlockNumber(root), current ? vm.getBlockNumber() : handler.lastValid(root), "root block"
            );
            assertTrue(census.getRootBlockNumber(root) != 0, "a held root reads 0");
            assertEq(census.getTotalVotingPowerAtRoot(root), handler.powerAt(root), "power at root");
            if (root >= BN254_R) {
                assertEq(census.getRootBlockNumber(root - BN254_R), 0, "root aliased mod r");
            } else {
                assertEq(census.getRootBlockNumber(root + BN254_R), 0, "root aliased mod r");
            }
            assertEq(census.getRootBlockNumber(root ^ 1), 0, "neighbour root known");
        }
        assertEq(census.getRootBlockNumber(0), 0);
        assertEq(census.getTotalVotingPowerAtRoot(0), 0);
    }
}

/// @dev A derived census whose admission hook calls an arbitrary contract before and after
///      _addToCensus, the way a voucher or token-gated census might. The hook re-enters.
contract HookedCensus is OnchainCensus {
    address public hook;

    function setHook(address h) external {
        hook = h;
    }

    function register(address user, uint88 weight) external {
        if (hook != address(0)) ReentrantHook(hook).before(user);
        _addToCensus(user, weight);
        if (hook != address(0)) ReentrantHook(hook).afterAdd(user);
    }
}

contract ReentrantHook {
    HookedCensus internal immutable census;
    uint256 internal depth;

    constructor(HookedCensus c) {
        census = c;
    }

    /// Re-enters once before the outer insert and once after it, each time adding a
    /// different member, and tries to add the outer user a second time after its insert.
    function before(address user) external {
        if (depth > 0) return;
        depth++;
        census.register(address(uint160(user) ^ 0x1111), 2);
        depth--;
    }

    function afterAdd(address user) external {
        if (depth > 0) return;
        depth++;
        census.register(address(uint160(user) ^ 0x2222), 3);
        try census.register(user, 9) {
            revert("outer user added twice");
        } catch {}
        depth--;
    }
}

/// @dev Focused attacks on the census: weight packing and the uint88 bound at the ABI
///      edge, duplicates, the zero address, slot collisions, voting-power arithmetic, the
///      log replay a sequencer does, and the registry's gas cap on the root getters.
contract AttackOnchainCensusTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant MASK88 = (uint256(1) << 88) - 1;

    OwnedCensus internal census;

    function setUp() public {
        census = new OwnedCensus();
    }

    function _plantSlotOwner(address user, address owner) internal {
        stdstore.target(address(census))
            .sig(census.slotOwner.selector)
            .with_key(uint256(census.slotOf(user)))
            .checked_write(owner);
    }

    // --- packing ---------------------------------------------------------------------

    /// leaf = address << 88 | weight is injective, below 2^248 and unpacks to its parts,
    /// so no (address, weight) pair can masquerade as another.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_LeafPacking(address a, uint88 w, address b, uint88 v) public view {
        uint256 leaf = census.leafFor(a, w);
        assertEq(leaf >> 248, 0, "leaf below 2^248");
        assertEq(address(uint160(leaf >> 88)), a);
        assertEq(leaf & MASK88, w);
        if (a != b || w != v) assertTrue(census.leafFor(b, v) != leaf, "packing collision");
    }

    /// A weight word with bits above 88 set, or an address word above 160 bits, is refused
    /// by the ABI decoder instead of being truncated into a different leaf.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_DirtyAbiWordsRefused(address user, uint88 w, uint8 bit, uint8 mode) public {
        vm.assume(user != address(0));
        w = uint88(bound(w, 1, type(uint88).max));
        mode = uint8(bound(mode, 0, 2));
        uint256 weightWord = w;
        uint256 userWord = uint160(user);
        if (mode != 1) weightWord |= uint256(1) << bound(bit, 88, 255);
        if (mode != 0) userWord |= uint256(1) << bound(bit, 160, 255);
        (bool ok,) = address(census).call(abi.encodeWithSelector(OwnedCensus.addMember.selector, userWord, weightWord));
        assertFalse(ok, "dirty word accepted");
        assertEq(census.treeSize(), 0);

        address[] memory one = new address[](1);
        uint88[] memory ws = new uint88[](1);
        bytes memory batch = abi.encodeCall(census.addMembers, (one, ws));
        // Words: selector, two offsets, users length, users[0], weights length, weights[0].
        assembly {
            mstore(add(batch, sub(mload(batch), 64)), userWord)
            mstore(add(batch, mload(batch)), weightWord)
        }
        (ok,) = address(census).call(batch);
        assertFalse(ok, "dirty batch word accepted");
        assertEq(census.treeSize(), 0);

        // The clean words register exactly (user, w).
        census.addMember(user, w);
        assertEq(census.leafOf(user), (uint256(uint160(user)) << 88) | w);
    }

    /// The largest weight is accepted and many of them add up exactly: the total and the
    /// per-root power leave uint88 without wrapping.
    function test_MaxWeightsSumPastUint88() public {
        uint256 n = 300;
        uint256 total;
        uint256[] memory roots = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            census.addMember(address(uint160(0x1000 + i)), type(uint88).max);
            total += type(uint88).max;
            roots[i] = census.getCensusRoot();
        }
        assertGt(total, type(uint88).max);
        assertEq(census.totalVotingPower(), total);
        for (uint256 i = 0; i < n; ++i) {
            assertEq(census.getTotalVotingPowerAtRoot(roots[i]), (i + 1) * uint256(type(uint88).max));
        }
    }

    // --- refusals --------------------------------------------------------------------

    /// The zero address is refused whatever the weight, alone and inside a batch.
    function testFuzz_ZeroAddressRefused(uint88 w, uint8 pos) public {
        // The address check comes first: a zero weight still reports the address.
        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addMember(address(0), w);

        uint256 len = 4;
        pos = uint8(bound(pos, 0, len - 1));
        address[] memory users = new address[](len);
        uint88[] memory weights = new uint88[](len);
        for (uint256 i = 0; i < len; ++i) {
            users[i] = i == pos ? address(0) : address(uint160(0x2000 + i));
            weights[i] = 1;
        }
        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addMembers(users, weights);
        assertEq(census.treeSize(), 0);
        assertEq(census.slotOwner(census.slotOf(address(0))), address(0), "zero address took a slot");
    }

    /// A member cannot be added twice with any weight, in one call or across calls, and the
    /// refused call changes nothing (weight, total, root, slot owner).
    function testFuzz_DuplicateRefused(address user, uint88 w1, uint88 w2, bool sameBatch) public {
        vm.assume(user != address(0));
        w1 = uint88(bound(w1, 1, type(uint88).max));
        w2 = uint88(bound(w2, 1, type(uint88).max));
        if (sameBatch) {
            address[] memory users = new address[](2);
            uint88[] memory weights = new uint88[](2);
            (users[0], users[1], weights[0], weights[1]) = (user, user, w1, w2);
            vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
            census.addMembers(users, weights);
            assertEq(census.treeSize(), 0);
            return;
        }
        census.addMember(user, w1);
        uint256 root = census.getCensusRoot();
        vm.expectRevert(OnchainCensus.AlreadyRegisteredAddress.selector);
        census.addMember(user, w2);
        assertEq(census.weightOf(user), w1);
        assertEq(census.totalVotingPower(), w1);
        assertEq(census.getCensusRoot(), root);
        assertEq(census.treeSize(), 1);
    }

    /// A taken slot refuses the newcomer whoever holds it (a member, or a stale address that
    /// is not one), reports the holder, and the holder keeps the slot.
    function testFuzz_SlotTakenReportsHolder(address newcomer, address holder, bool holderIsMember) public {
        vm.assume(newcomer != address(0) && holder != address(0) && newcomer != holder);
        if (holderIsMember) census.addMember(holder, 3);
        _plantSlotOwner(newcomer, holder);
        uint256 root = census.getCensusRoot();
        vm.expectRevert(abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, holder));
        census.addMember(newcomer, 1);
        assertEq(census.slotOwner(census.slotOf(newcomer)), holder);
        assertEq(census.weightOf(newcomer), 0);
        assertEq(census.getCensusRoot(), root);
    }

    /// Two members of one batch on the same slot: the second reverts the whole batch with
    /// SlotTaken(first).
    function test_SlotCollisionInsideOneBatch() public {
        address a = address(0xA1);
        address b = address(0xB2);
        // Plant b's slot to a before a is added: from the census's view a took it first.
        _plantSlotOwner(b, a);
        address[] memory users = new address[](2);
        uint88[] memory weights = new uint88[](2);
        (users[0], users[1], weights[0], weights[1]) = (a, b, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(OnchainCensus.SlotTaken.selector, a));
        census.addMembers(users, weights);
        assertEq(census.treeSize(), 0);
    }

    // --- logs and readers ----------------------------------------------------------------

    /// A reader that only has the logs of the accepted transactions rebuilds the same tree:
    /// each CensusMemberAdded's newRoot is the reference root of the leaves logged so far,
    /// WeightChanged(user, 0, weight) comes right before it, and the totals add up.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_LogReplayRebuildsTheTree(uint256 seed) public {
        uint256[] memory leaves = new uint256[](200);
        uint256 n;
        uint256 total;
        for (uint256 i = 0; i < 60; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bytes memory data;
            if (r % 5 == 0) {
                address[] memory users = new address[](3);
                uint88[] memory ws = new uint88[](3);
                for (uint256 j = 0; j < 3; ++j) {
                    users[j] = address(uint160((r >> (8 * j)) % 40)); // includes 0 and repeats
                    ws[j] = uint88(1 + j);
                }
                data = abi.encodeCall(census.addMembers, (users, ws));
            } else {
                uint88 w = uint88(r >> 160) % 4 == 0 ? 0 : uint88(r >> 160);
                data = abi.encodeCall(census.addMember, (address(uint160(r % 40)), w));
            }
            vm.recordLogs();
            (bool ok,) = address(census).call(data);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (r % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            // forge records the logs of a reverted call; a chain reader never sees them.
            if (!ok) continue;
            assertEq(logs.length % 2, 0, "log pairs");
            for (uint256 k = 0; k < logs.length; k += 2) {
                (uint256 leaf, uint88 w, uint256 newRoot, uint256 tvp) = _decodePair(logs[k], logs[k + 1]);
                leaves[n++] = leaf;
                total += w;
                assertEq(newRoot, LeanIMTRef.root(leaves, n), "logged root");
                assertEq(tvp, total, "logged total");
            }
        }
        assertGt(n, 0);
        assertEq(n, census.treeSize());
        assertEq(LeanIMTRef.root(leaves, n), census.getCensusRoot());
        assertEq(total, census.totalVotingPower());
    }

    /// @dev Checks one WeightChanged + CensusMemberAdded pair and returns what a reader keeps.
    function _decodePair(Vm.Log memory wc, Vm.Log memory ma)
        internal
        pure
        returns (uint256 leaf, uint88 w, uint256 newRoot, uint256 tvp)
    {
        assertEq(wc.topics[0], CensusEvents.WEIGHT_CHANGED, "WeightChanged first");
        assertEq(ma.topics[0], CensusEvents.MEMBER_ADDED, "then CensusMemberAdded");
        assertEq(wc.topics[1], ma.topics[1], "same user");
        (uint88 prev, uint88 next) = abi.decode(wc.data, (uint88, uint88));
        (w, leaf, newRoot, tvp) = abi.decode(ma.data, (uint88, uint256, uint256, uint256));
        assertEq(prev, 0, "previous weight");
        assertEq(next, w, "new weight");
        assertEq(leaf, (uint256(ma.topics[1]) << 88) | w, "logged leaf");
    }

    /// The registry STATICCALLs the root getters with 100k gas and needs a 32-byte answer:
    /// they fit for the current root, a replaced root and an unknown one, after a long
    /// history.
    function test_GettersFitTheRegistryGasCap() public {
        uint256 first;
        for (uint256 i = 0; i < 200; ++i) {
            census.addMember(address(uint160(0x3000 + i)), 1);
            if (i == 0) first = census.getCensusRoot();
            vm.roll(vm.getBlockNumber() + 1);
        }
        uint256 current = census.getCensusRoot();
        uint256[3] memory qs = [current, first, uint256(0xdead)];
        for (uint256 i = 0; i < 3; ++i) {
            bytes[3] memory calls = [
                abi.encodeCall(ICensusValidator.getRootBlockNumber, (qs[i])),
                abi.encodeCall(ICensusValidator.getTotalVotingPowerAtRoot, (qs[i])),
                abi.encodeCall(ICensusValidator.getCensusRoot, ())
            ];
            for (uint256 j = 0; j < 3; ++j) {
                uint256 g = gasleft();
                (bool ok, bytes memory ret) = address(census).staticcall{gas: 100_000}(calls[j]);
                uint256 used = g - gasleft();
                assertTrue(ok && ret.length == 32, "getter failed under the cap");
                assertLt(used, 25_000, "getter close to the registry cap");
            }
        }
    }

    /// Roots replaced in one block share that block; the current root always reads the
    /// current block, also in a later block with no insert; a root re-queried after more
    /// inserts keeps its block.
    function testFuzz_RootBlocksAcrossBlocks(uint8[12] memory gaps) public {
        uint256[] memory roots = new uint256[](12);
        uint256[] memory replaced = new uint256[](12);
        for (uint256 i = 0; i < 12; ++i) {
            vm.roll(vm.getBlockNumber() + (gaps[i] % 3));
            if (i > 0) replaced[i - 1] = vm.getBlockNumber();
            census.addMember(address(uint160(0x4000 + i)), uint88(i + 1));
            roots[i] = census.getCensusRoot();
        }
        vm.roll(vm.getBlockNumber() + 5);
        for (uint256 i = 0; i + 1 < 12; ++i) {
            assertEq(census.getRootBlockNumber(roots[i]), replaced[i]);
        }
        assertEq(census.getRootBlockNumber(roots[11]), vm.getBlockNumber());
    }

    /// A derived census that re-enters itself around _addToCensus: every insert is atomic,
    /// so the tree, the totals, the root history and the log order still follow insertion
    /// order (inner before, outer, inner after) and the outer user cannot land twice.
    function test_ReentrantDerivedCensusStaysConsistent() public {
        HookedCensus hooked = new HookedCensus();
        hooked.setHook(address(new ReentrantHook(hooked)));
        address user = address(0x6000);
        vm.recordLogs();
        hooked.register(user, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address[3] memory order = [address(uint160(user) ^ 0x1111), user, address(uint160(user) ^ 0x2222)];
        uint88[3] memory ws = [uint88(2), 1, 3];
        uint256[] memory leaves = new uint256[](3);
        uint256 k;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != CensusEvents.MEMBER_ADDED) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), order[k], "log order");
            (uint88 w, uint256 leaf, uint256 newRoot,) = abi.decode(logs[i].data, (uint88, uint256, uint256, uint256));
            assertEq(w, ws[k]);
            leaves[k] = leaf;
            ++k;
            assertEq(newRoot, LeanIMTRef.root(leaves, k), "root follows insertion order");
        }
        assertEq(k, 3);
        assertEq(hooked.treeSize(), 3);
        assertEq(hooked.totalVotingPower(), 6);
        assertEq(hooked.weightOf(user), 1);
        assertEq(hooked.getCensusRoot(), LeanIMTRef.root(leaves, 3));
    }

    /// renounceOwnership freezes the census: nobody can add, and every root stays readable.
    function test_RenouncedCensusIsFrozen() public {
        census.addMember(address(0x5000), 1);
        uint256 root = census.getCensusRoot();
        census.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        census.addMember(address(0x5001), 1);
        vm.roll(vm.getBlockNumber() + 100);
        assertEq(census.getRootBlockNumber(root), vm.getBlockNumber());
        assertEq(census.getCensusRoot(), root);
    }
}
