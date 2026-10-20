// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfiguredLiquidity} from "./helpers/ConfiguredLiquidity.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";

address constant DEAD = 0x000000000000000000000000000000000000dEaD;

contract FuzzSeats is ERC721("identity.md", "IMD-ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// Takes the released INK and does nothing with it; the real InkLiquidity is covered by the fork tests.

/// Drives the vault through random sequences of everything people can do with it.
contract VaultHandler is Test {
    uint256 constant PORTRAIT = 400_000e18;
    uint256 constant SEATS_IN_TREE = 8;

    InkVault public vault;
    InkPortraits public portraits;
    MockERC20 public ink;
    FuzzSeats public seats;
    address public owner;
    address[] public actors;
    bytes32[8] internal leaves;
    InkPortraits.AgentStats[8] internal stats;

    // Ghosts
    /// INK the vault has sent to the liquidity contract in fees, by the handler's own count.
    uint256 public feesToLiquidity;
    uint256 public inkMinted;
    uint256 public calls;
    bool public soldOutReached;
    mapping(bytes32 => uint256) public callCount;

    constructor(InkVault vault_, InkPortraits portraits_, MockERC20 ink_, FuzzSeats seats_, address owner_) {
        vault = vault_;
        portraits = portraits_;
        ink = ink_;
        seats = seats_;
        owner = owner_;
        for (uint256 i; i < 5; i++) {
            address a = makeAddr(string(abi.encode("actor", i)));
            actors.push(a);
            vm.prank(a);
            ink.approve(address(vault), type(uint256).max);
            vm.prank(a);
            portraits.setApprovalForAll(address(vault), true);
        }
        for (uint256 s; s < SEATS_IN_TREE; s++) {
            stats[s] = InkPortraits.AgentStats(
                uint32(s * 37), uint16(5000 + s * 500), uint32(s * 900), uint32(s * 11), s % 3 == 0
            );
            leaves[s] = _leaf(s, stats[s]);
            seats.mint(actors[s % actors.length], s);
        }
    }

    function root() external view returns (bytes32) {
        bytes32[8] memory l = leaves;
        return _rootOf(l);
    }

    // ---------------------------------------------------------------- tree helpers (sorted pairs, 8 leaves)

    function _leaf(uint256 seat, InkPortraits.AgentStats memory s) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(seat, s.accepted, s.rateBps, s.turns, s.hoursTenths, s.outdated))
            )
        );
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _rootOf(bytes32[8] memory l) internal pure returns (bytes32) {
        bytes32[4] memory a = [_pair(l[0], l[1]), _pair(l[2], l[3]), _pair(l[4], l[5]), _pair(l[6], l[7])];
        return _pair(_pair(a[0], a[1]), _pair(a[2], a[3]));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        bytes32[8] memory l = leaves;
        bytes32[4] memory a = [_pair(l[0], l[1]), _pair(l[2], l[3]), _pair(l[4], l[5]), _pair(l[6], l[7])];
        bytes32[2] memory b = [_pair(a[0], a[1]), _pair(a[2], a[3])];
        p = new bytes32[](3);
        p[0] = l[i ^ 1];
        p[1] = a[(i / 2) ^ 1];
        p[2] = b[(i / 4) ^ 1];
    }

    // ---------------------------------------------------------------- helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _fund(address who, uint256 amount) internal {
        uint256 bal = ink.balanceOf(who);
        if (bal < amount) {
            ink.mint(who, amount - bal);
            inkMinted += amount - bal;
        }
    }

    /// A portrait `who` holds, picked by `seed`, or type(uint256).max.
    function _heldBy(address who, uint256 seed) internal view returns (uint256) {
        uint256 swarm = portraits.swarmMinted();
        uint256 total = SEATS_IN_TREE + swarm;
        for (uint256 k; k < total; k++) {
            uint256 j = (seed % total + k) % total;
            uint256 id = j < SEATS_IN_TREE ? j : 10_000 + (j - SEATS_IN_TREE);
            try portraits.ownerOf(id) returns (address o) {
                if (o == who) return id;
            } catch {}
        }
        return type(uint256).max;
    }

    modifier counted(bytes32 name) {
        calls++;
        callCount[name]++;
        _;
    }

    // ---------------------------------------------------------------- actions

    function claim(uint256 seatSeed) external counted("claim") {
        uint256 seat = seatSeed % SEATS_IN_TREE;
        if (!vault.claimOpen()) return;
        if (portraits.agentMinted() > 0) {
            try portraits.ownerOf(seat) returns (address) {
                return;
            } catch {}
        }
        address holder = seats.ownerOf(seat);
        vm.prank(holder);
        vault.claim(seat, stats[seat], _proof(seat));
    }

    function moveSeat(uint256 seatSeed, uint256 toSeed) external counted("moveSeat") {
        uint256 seat = seatSeed % SEATS_IN_TREE;
        address from = seats.ownerOf(seat);
        vm.prank(from);
        seats.transferFrom(from, _actor(toSeed), seat);
    }

    function release(uint256 extraTime) external counted("release") {
        if (vault.released()) return;
        vm.warp(vault.claimEnd() + (extraTime % 2 days));
        vault.release();
    }

    function pull(uint256 actorSeed, uint256 count) external counted("pull") {
        if (!vault.released()) return;
        uint256 room = vault.available() + vault.waitingBefore() - (vault.pullCount() - vault.nextReveal());
        if (room == 0) return;
        count = bound(count, 1, room < 60 ? room : 60);
        address who = _actor(actorSeed);
        _fund(who, count * PORTRAIT);
        vm.prank(who);
        vault.pull(count);
    }

    /// Pulls everything that's left (up to 500), to drive the collection to its 2,000 cap.
    function pullAll(uint256 actorSeed) external counted("pullAll") {
        if (!vault.released()) return;
        uint256 room = vault.available() + vault.waitingBefore() - (vault.pullCount() - vault.nextReveal());
        if (room == 0) return;
        if (room > 500) room = 500;
        address who = _actor(actorSeed);
        _fund(who, room * PORTRAIT);
        vm.prank(who);
        vault.pull(room);
        if (portraits.totalSupply() + vault.pullCount() - vault.nextReveal() >= 2000) soldOutReached = true;
    }

    function pullTooMany(uint256 actorSeed) external counted("pullTooMany") {
        if (!vault.released()) return;
        uint256 room = vault.available() + vault.waitingBefore() - (vault.pullCount() - vault.nextReveal());
        address who = _actor(actorSeed);
        _fund(who, (room + 1) * PORTRAIT);
        vm.prank(who);
        vm.expectRevert(InkVault.NoneAvailable.selector);
        vault.pull(room + 1);
    }

    function roll(uint256 blocks) external counted("roll") {
        blocks = bound(blocks, 1, 320); // sometimes past the 256-block horizon
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
    }

    function reveal(uint256 offset) external counted("reveal") {
        uint256 pending = vault.pullCount() - vault.nextReveal();
        if (pending == 0) return;
        uint256 pullId = vault.nextReveal() + (offset % pending);
        (, uint64 bn,) = vault.pulls(vault.nextReveal());
        if (block.number <= uint256(bn) + 1) {
            vm.expectRevert(InkVault.TooEarly.selector);
            vault.reveal(pullId);
            return;
        }
        uint256 head = vault.nextReveal();
        vault.reveal(pullId);
        _accountExpiries(head);
    }

    function revealNext(uint256 max) external counted("revealNext") {
        uint256 head = vault.nextReveal();
        vault.revealNext(bound(max, 1, 80));
        _accountExpiries(head);
    }

    function _accountExpiries(uint256 head) internal {
        for (uint256 i = head; i < vault.nextReveal(); i++) {
            if (vault.pullExpired(i)) feesToLiquidity += vault.pullExpiryFee(i);
        }
    }

    function deposit(uint256 actorSeed, uint256 pick) external counted("deposit") {
        if (!vault.released()) return;
        address who = _actor(actorSeed);
        uint256 id = _heldBy(who, pick);
        if (id == type(uint256).max || vault.traitRerollBlock(id) != 0) return;
        bool agentToken = id < 10_000;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        uint256 out = vault.deposit(ids, 0);
        feesToLiquidity += PORTRAIT - out;
        if (agentToken) {
            assertEq(out, PORTRAIT, "an agent hand-in pays exactly its backing");
        } else {
            assertLe(out, PORTRAIT, "a swarm hand-in never pays more than its backing");
            assertGe(out, PORTRAIT * 95 / 100, "fees are capped at 5%");
        }
    }

    uint256[] internal _rerolled;

    function rerollTraits(uint256 actorSeed, uint256 pick) external counted("rerollTraits") {
        if (!vault.released()) return;
        address who = _actor(actorSeed);
        uint256 id = _heldBy(who, pick);
        if (id == type(uint256).max || id < 10_000 || vault.traitRerollBlock(id) != 0) return;
        _fund(who, PORTRAIT * 5 / 100);
        uint256 liqBefore = ink.balanceOf(vault.liquidity());
        vm.prank(who);
        uint256 fee = vault.rerollTraits(id, type(uint256).max);
        assertEq(ink.balanceOf(vault.liquidity()) - liqBefore, fee, "the trait reroll fee goes to liquidity");
        feesToLiquidity += fee;
        assertLe(fee, PORTRAIT * 5 / 100, "fees are capped at 5%");
        _rerolled.push(id);
    }

    function revealTraits(uint256 pick) external counted("revealTraits") {
        if (_rerolled.length == 0) return;
        uint256 id = _rerolled[pick % _rerolled.length];
        uint64 b = vault.traitRerollBlock(id);
        if (b == 0 || block.number <= uint256(b) + 1) return;
        bytes32 before = portraits.swarmSeed(id);
        address holder = portraits.ownerOf(id);
        if (vault.revealTraits(id)) assertTrue(portraits.swarmSeed(id) != before, "repainted");
        assertEq(portraits.ownerOf(id), holder, "a trait reroll never moves the portrait");
    }

    function transferPortrait(uint256 fromSeed, uint256 toSeed, uint256 pick) external counted("transfer") {
        address from = _actor(fromSeed);
        uint256 id = _heldBy(from, pick);
        if (id == type(uint256).max) return;
        bool pending = vault.traitRerollBlock(id) != 0;
        vm.prank(from);
        // Audit 5574e8bc: the holder's pending repaint prevents selling stale traits.
        if (pending) vm.expectRevert(InkPortraits.RerollPending.selector);
        portraits.transferFrom(from, _actor(toSeed), id);
    }

    function setFees(uint16 base, uint16 agent) external counted("setFees") {
        base = uint16(bound(base, 0, 500));
        agent = uint16(bound(agent, 0, base));
        vm.prank(owner);
        vault.setFees(base, agent);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// Invariants that must hold after any sequence of claims, releases, pulls, reveals, hand-ins and transfers.
contract VaultInvariantsTest is Test {
    uint256 constant PORTRAIT = 400_000e18;

    InkVault vault;
    InkPortraits portraits;
    MockERC20 ink;
    FuzzSeats seats;
    ConfiguredLiquidity sink;
    VaultHandler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.roll(20_000_000);
        seats = new FuzzSeats();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        ink = new MockERC20("INK", "INK", 18);
        sink = new ConfiguredLiquidity(IERC20(address(ink)));
        vm.prank(owner);
        portraits.setVault(address(vault));
        ink.mint(address(vault), 2000 * PORTRAIT);

        handler = new VaultHandler(vault, portraits, ink, seats, owner);
        vm.startPrank(owner);
        vault.setInk(IERC20(address(ink)));
        vault.setup(handler.root(), uint64(block.timestamp), address(sink));
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// Every portrait outside the vault, and every queued pull, is backed by 400,000 INK; the pot is extra.
    function invariant_fullyBacked() public view {
        uint256 bal = ink.balanceOf(address(vault));
        if (!vault.released()) {
            assertEq(bal, 2000 * PORTRAIT, "before release the vault holds every seat's INK");
            return;
        }
        uint256 outside = portraits.totalSupply() - vault.heldCount();
        uint256 queued = vault.pullCount() - vault.nextReveal();
        assertEq(bal, (outside + queued) * PORTRAIT, "backing");
    }

    /// No INK appears or disappears: vault + liquidity + actors + burned = what was minted.
    function invariant_inkConserved() public view {
        uint256 sum = ink.balanceOf(address(vault)) + ink.balanceOf(address(sink)) + ink.balanceOf(DEAD);
        for (uint256 i; i < handler.actorCount(); i++) {
            sum += ink.balanceOf(handler.actors(i));
        }
        assertEq(sum, 2000 * PORTRAIT + handler.inkMinted());
    }

    function invariant_capAndSlots() public view {
        assertLe(portraits.totalSupply(), 2000);
        assertLe(
            portraits.swarmMinted(), vault.swarmSlots(), "never more swarm portraits than unclaimed seats"
        );
        if (vault.released()) assertEq(portraits.agentMinted() + vault.swarmSlots(), 2000);
    }

    function invariant_custody() public view {
        assertEq(portraits.balanceOf(address(vault)), vault.heldCount(), "vault holds exactly its inventory");
    }

    /// Every queued pull has a portrait waiting for it, so no pull can be stuck for want of one.
    function invariant_queueCovered() public view {
        uint256 queued = vault.pullCount() - vault.nextReveal();
        // Audit 4ca49345: hand-ins from this block never count, so a fixed admission cutoff always has a portrait.
        assertLe(queued, vault.available() + vault.waitingBefore());
        assertLe(vault.waitingBefore(), vault.waitingCount());
        if (vault.nextReveal() > 0) {
            (,, bool done) = vault.pulls(vault.nextReveal() - 1);
            assertTrue(done);
        }
        if (queued > 0) {
            (,, bool done) = vault.pulls(vault.nextReveal());
            assertFalse(done);
        }
    }

    /// The liquidity contract holds exactly the released INK plus every fee the vault took; nothing is burned.
    function invariant_feesToLiquidity() public view {
        uint256 released = vault.released() ? (2000 - portraits.agentMinted()) * PORTRAIT : 0;
        assertEq(ink.balanceOf(address(sink)), released + handler.feesToLiquidity());
        assertEq(ink.balanceOf(DEAD), 0, "nothing is burned");
    }

    function invariant_agentBalancesMatch() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); i++) {
            sum += portraits.agentBalanceOf(handler.actors(i));
        }
        sum += portraits.agentBalanceOf(address(vault));
        assertEq(sum, portraits.agentMinted());
    }

    function afterInvariant() external view {
        // Make sure the runs actually got past release and exercised the queue.
        assertGt(handler.calls(), 0);
    }
}
