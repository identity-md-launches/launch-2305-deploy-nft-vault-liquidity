// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkRenderer} from "../src/InkRenderer.sol";
import {TestSeats} from "../src/testnet/TestSeats.sol";
import {ConfiguredLiquidity} from "./helpers/ConfiguredLiquidity.sol";

/// Review finding 16c7464acc9e: a contract that parks one agent portrait and hands in anyone's swarm
/// portrait at the holder rate, forwarding the INK in the same transaction.
contract DiscountProxy {
    InkVault immutable vault;
    InkPortraits immutable portraits;

    constructor(InkVault v) {
        vault = v;
        portraits = v.portraits();
        portraits.setApprovalForAll(address(v), true);
    }

    function depositFor(uint256 tokenId) external returns (uint256 out) {
        portraits.transferFrom(msg.sender, address(this), tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        out = vault.deposit(ids, 0);
        vault.ink().transfer(msg.sender, out);
    }

    function rerollFor(uint256 tokenId) external returns (uint256 fee) {
        vault.ink().approve(address(vault), type(uint256).max);
        fee = vault.rerollTraits(tokenId, type(uint256).max);
    }
}

/// Regressions for imported findings 7a54cd1bfe87, 8ff058a5ba34 and f6efe85d4b38, and review finding
/// 16c7464acc9e (discount resold through an agent-holding contract) and 68252bb4caa5 (two-step ownership).
contract LaunchSafetyTest is Test {
    uint256 constant P = 400_000e18;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address agent = makeAddr("agent");
    address outsider = makeAddr("outsider");
    InkPortraits portraits;
    InkVault vault;
    MockERC20 ink;
    TestSeats seats;
    ConfiguredLiquidity sink;

    function setUp() public {
        vm.roll(100);
        seats = new TestSeats();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        ink = new MockERC20("INK", "INK", 18);
        sink = new ConfiguredLiquidity(IERC20(address(ink)));
        ink.mint(address(vault), 2000 * P);
        InkPortraits.AgentStats memory stats;
        bytes32 root = keccak256(
            bytes.concat(keccak256(abi.encode(uint256(0), uint32(0), uint16(0), uint32(0), uint32(0), false)))
        );
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        vault.setInk(IERC20(address(ink)));
        vault.setup(root, uint64(block.timestamp), address(sink));
        vm.stopPrank();
        vm.startPrank(agent);
        seats.mint(0);
        vault.claim(0, stats, new bytes32[](0));
        vm.stopPrank();
        vm.warp(vault.claimEnd());
        vault.release();
        vm.roll(101);
    }

    function _pull(address who, uint256 count) internal returns (uint256 id) {
        ink.mint(who, count * P);
        vm.startPrank(who);
        ink.approve(address(vault), type(uint256).max);
        id = vault.pull(count);
        vm.stopPrank();
    }

    function _mature() internal {
        uint256 entropyBlock = block.number + 1;
        vm.roll(block.number + 2);
        vm.setBlockhash(entropyBlock, keccak256(abi.encode("launch audit", entropyBlock)));
    }

    function _swarm(address who) internal returns (uint256 tokenId) {
        uint256 id = _pull(who, 1);
        tokenId = 10_000 + portraits.swarmMinted();
        _mature();
        assertTrue(vault.reveal(id));
    }

    function _requestTraits(address who, uint256 tokenId) internal returns (uint256 fee) {
        ink.mint(who, P / 100);
        vm.startPrank(who);
        ink.approve(address(vault), type(uint256).max);
        fee = vault.rerollTraits(tokenId, P / 100);
        vm.stopPrank();
    }

    function test_expiredTraitRerollConsumesFeeAndRequiresNewPayment() public {
        uint256 tokenId = _swarm(alice);
        bytes32 oldSeed = portraits.swarmSeed(tokenId);
        uint256 before = ink.balanceOf(address(sink));
        uint256 fee = _requestTraits(alice, tokenId);
        uint256 made = block.number;
        _mature();
        bytes32 firstDraw = keccak256(abi.encode(blockhash(made + 1), tokenId, "traits"));
        vm.roll(made + 258);
        vm.expectEmit(address(vault));
        emit InkVault.TraitRerollExpired(tokenId);
        vm.prank(outsider);
        assertFalse(vault.revealTraits(tokenId));
        assertEq(vault.traitRerollBlock(tokenId), 0);
        assertEq(portraits.swarmSeed(tokenId), oldSeed);
        assertEq(ink.balanceOf(address(sink)) - before, fee);
        vm.expectRevert(InkVault.NoRerollPending.selector);
        vault.revealTraits(tokenId);
        _requestTraits(alice, tokenId);
        assertEq(ink.balanceOf(address(sink)) - before, 2 * fee);
        _mature();
        assertTrue(vault.revealTraits(tokenId));
        assertNotEq(portraits.swarmSeed(tokenId), firstDraw);
    }

    function test_traitRerollLastAvailableBlockUsesOriginalHash() public {
        uint256 tokenId = _swarm(alice);
        _requestTraits(alice, tokenId);
        uint256 made = block.number;
        vm.roll(made + 257);
        bytes32 entropy = keccak256("last available trait entropy");
        vm.setBlockhash(made + 1, entropy);
        assertTrue(vault.revealTraits(tokenId));
        assertEq(portraits.swarmSeed(tokenId), keccak256(abi.encode(entropy, tokenId, "traits")));
        assertEq(vault.traitRerollBlock(tokenId), 0);
    }

    function testFuzz_expiredPullChargesPurchaseFeeAndPreservesBacking(
        uint16 base,
        uint16 discounted,
        bool isAgent
    ) public {
        base = uint16(bound(base, 0, 500));
        discounted = uint16(bound(discounted, 0, base));
        vm.prank(owner);
        vault.setFees(base, discounted);
        address buyer = isAgent ? agent : alice;
        uint256 id = _pull(buyer, 1);
        uint256 made = block.number;
        uint256 fee = P * (isAgent ? discounted : base) / 10_000;
        uint256 before = ink.balanceOf(address(sink));
        assertEq(vault.pullExpiryFee(id), fee);
        vm.prank(owner);
        vault.setFees(500, 500); // Must not change an already committed pull's refund.
        vm.roll(made + 258);
        vm.expectEmit(address(vault));
        emit InkVault.PullExpired(id, buyer, P - fee, fee);
        vm.prank(outsider);
        assertFalse(vault.reveal(id));
        assertTrue(vault.pullExpired(id));
        assertEq(vault.pullBlock(id), made);
        assertEq(vault.nextReveal(), id + 1);
        assertEq(ink.balanceOf(buyer), P - fee);
        assertEq(ink.balanceOf(address(sink)) - before, fee);
        assertEq(ink.balanceOf(address(vault)), P, "claimed agent remains fully backed");
        assertEq(portraits.swarmMinted(), 0);
        vm.expectRevert(InkVault.AlreadyRevealed.selector);
        vault.reveal(id);
    }

    function test_pullLastAvailableBlockRevealsWithoutExpiryFee() public {
        uint256 id = _pull(alice, 1);
        uint256 made = block.number;
        uint256 before = ink.balanceOf(address(sink));
        vm.roll(made + 257);
        bytes32 entropy = keccak256("last available pull entropy");
        vm.setBlockhash(made + 1, entropy);
        assertTrue(vault.reveal(id));
        assertFalse(vault.pullExpired(id));
        assertEq(portraits.swarmSeed(10_000), keccak256(abi.encode(entropy, id, "seed")));
        assertEq(ink.balanceOf(address(sink)), before);
    }

    function test_expiredHeadCannotStallLaterLivePull() public {
        uint256 expired = _pull(alice, 1);
        vm.roll(block.number + 255);
        uint256 live = _pull(outsider, 1);
        _mature();
        vm.roll(block.number + 1);
        assertTrue(vault.reveal(live));
        assertTrue(vault.pullExpired(expired));
        assertFalse(vault.pullExpired(live));
        assertEq(portraits.ownerOf(10_000), outsider);
        assertEq(ink.balanceOf(alice), P * 99 / 100);
        assertEq(vault.nextReveal(), live + 1);
        assertEq(ink.balanceOf(address(vault)), 2 * P);
    }

    function test_expiredBatchRespectsProcessingLimit() public {
        uint256 id = _pull(alice, 3);
        vm.roll(block.number + 300);
        assertEq(vault.revealNext(1), 0);
        assertEq(vault.nextReveal(), id + 1);
        assertEq(vault.revealNext(1), 0);
        assertEq(vault.nextReveal(), id + 2);
        assertEq(vault.revealNext(1), 0);
        assertEq(vault.nextReveal(), id + 3);
        assertEq(ink.balanceOf(alice), 3 * P * 99 / 100);
    }

    function testFuzz_directPortraitTransfersCannotBypassDeposit(bool agentPortrait, uint8 mode) public {
        uint256 tokenId = agentPortrait ? 0 : _swarm(alice);
        address holder = agentPortrait ? agent : alice;
        uint256 before = ink.balanceOf(holder);
        vm.prank(holder);
        portraits.approve(outsider, tokenId);
        vm.startPrank(outsider);
        vm.expectRevert(InkPortraits.UseDeposit.selector);
        if (mode % 3 == 0) portraits.transferFrom(holder, address(vault), tokenId);
        else if (mode % 3 == 1) portraits.safeTransferFrom(holder, address(vault), tokenId);
        else portraits.safeTransferFrom(holder, address(vault), tokenId, "bypass");
        vm.stopPrank();
        assertEq(portraits.ownerOf(tokenId), holder);
        assertEq(vault.heldCount(), 0);
        assertEq(ink.balanceOf(holder), before);
        vm.startPrank(holder);
        portraits.approve(address(vault), tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 out = vault.deposit(ids, 0);
        vm.stopPrank();
        assertEq(out, agentPortrait ? P : P * 99 / 100);
        assertEq(vault.heldCount(), 1);
        assertEq(portraits.ownerOf(tokenId), address(vault));
    }

    function test_portraitsCannotBeSentToLiquidity() public {
        uint256 tokenId = _swarm(alice);
        vm.startPrank(alice);
        vm.expectRevert(InkPortraits.InvalidRecipient.selector);
        portraits.transferFrom(alice, address(sink), tokenId);
        vm.expectRevert(InkPortraits.InvalidRecipient.selector);
        portraits.safeTransferFrom(alice, address(sink), tokenId);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(InkPortraits.InvalidRecipient.selector);
        portraits.transferFrom(agent, address(sink), 0);
        assertEq(portraits.ownerOf(tokenId), alice);
        assertEq(portraits.ownerOf(0), agent);
    }

    function test_vaultAndRendererBindingFailuresRemainCorrectable() public {
        InkPortraits fresh = new InkPortraits(owner);
        InkVault correct = new InkVault(fresh, seats, owner);
        InkRenderer renderer = new InkRenderer(fresh, owner);
        InkRenderer wrongRenderer = new InkRenderer(portraits, owner);
        vm.startPrank(owner);
        vm.expectRevert(InkPortraits.InvalidBinding.selector);
        fresh.setVault(outsider);
        vm.expectRevert(InkPortraits.InvalidBinding.selector);
        fresh.setVault(address(vault)); // Same type, wrong collection.
        vm.expectRevert();
        fresh.setVault(address(ink)); // Has code, not a vault.
        vm.expectRevert();
        fresh.setVault(address(renderer)); // Same portraits() reference, wrong application type.
        assertEq(fresh.vault(), address(0));
        fresh.setVault(address(correct));
        vm.expectRevert(InkPortraits.VaultAlreadySet.selector);
        fresh.setVault(address(correct));
        vm.expectRevert(InkPortraits.InvalidBinding.selector);
        fresh.setRenderer(outsider);
        vm.expectRevert(InkPortraits.InvalidBinding.selector);
        fresh.setRenderer(address(wrongRenderer));
        vm.expectRevert();
        fresh.setRenderer(address(correct)); // The bound vault is not a renderer.
        fresh.setRenderer(address(renderer));
        fresh.lockRenderer();
        vm.expectRevert(InkPortraits.Locked.selector);
        fresh.setRenderer(address(renderer));
        vm.stopPrank();
    }

    function test_setInkRequiresCodeAndFullAllocationBeforeItCommits() public {
        InkVault fresh = new InkVault(portraits, seats, owner);
        ink.mint(address(fresh), 2000 * P - 1);
        vm.startPrank(owner);
        vm.expectRevert(InkVault.InvalidInk.selector);
        fresh.setInk(IERC20(outsider));
        vm.expectRevert(InkVault.InvalidInk.selector);
        fresh.setInk(IERC20(address(0)));
        vm.expectRevert(InkVault.NotFunded.selector);
        fresh.setInk(IERC20(address(ink)));
        vm.expectRevert();
        fresh.setInk(IERC20(address(seats)));
        assertEq(address(fresh.ink()), address(0));
        ink.mint(address(fresh), 1);
        fresh.setInk(IERC20(address(ink)));
        vm.expectRevert(InkVault.InkAlreadySet.selector);
        fresh.setInk(IERC20(address(ink)));
        vm.stopPrank();
    }

    function test_setupRejectsWrongTokenLiquidityAndRemainsCorrectable() public {
        InkVault fresh = new InkVault(portraits, seats, owner);
        MockERC20 wrong = new MockERC20("wrong", "wrong", 18);
        ConfiguredLiquidity bad = new ConfiguredLiquidity(IERC20(address(wrong)));
        ink.mint(address(fresh), 2000 * P);
        vm.startPrank(owner);
        fresh.setInk(IERC20(address(ink)));
        vm.expectRevert(InkVault.BadSetup.selector);
        fresh.setup(keccak256("root"), uint64(block.timestamp), address(bad));
        assertEq(fresh.statsRoot(), bytes32(0));
        vm.mockCall(address(sink), abi.encodeWithSignature("poolSet()"), abi.encode(false));
        vm.expectRevert(InkVault.BadSetup.selector);
        fresh.setup(keccak256("root"), uint64(block.timestamp), address(sink));
        vm.clearMockedCalls();
        fresh.setup(keccak256("root"), uint64(block.timestamp), address(sink));
        vm.stopPrank();
        assertEq(fresh.liquidity(), address(sink));
    }

    function _deposit(address who, uint256 tokenId) internal returns (uint256 fee) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 before = ink.balanceOf(address(sink));
        vm.startPrank(who);
        portraits.setApprovalForAll(address(vault), true);
        vault.deposit(ids, 0);
        vm.stopPrank();
        fee = ink.balanceOf(address(sink)) - before;
    }

    // ---------------------------------------------------------------- 16c7464acc9e: discount follows the portrait

    function test_nonHolderPaysFullFeeThroughAgentHoldingContract() public {
        uint256 tokenId = _swarm(alice);
        DiscountProxy proxy = new DiscountProxy(vault);
        vm.prank(agent);
        portraits.transferFrom(agent, address(proxy), 0);
        vm.roll(block.number + 1);
        assertTrue(portraits.isAgentHolder(address(proxy)), "the proxy is an agent holder in its own right");
        assertFalse(portraits.isAgentHolder(alice));
        assertFalse(
            portraits.hasRerollDiscount(address(proxy), tokenId), "but not on a portrait handed to it"
        );

        uint256 before = ink.balanceOf(address(sink));
        vm.startPrank(alice);
        portraits.approve(address(proxy), tokenId);
        uint256 out = proxy.depositFor(tokenId);
        vm.stopPrank();
        assertEq(ink.balanceOf(address(sink)) - before, P * vault.rerollFeeBps() / 10_000, "full fee");
        assertEq(out, P - P * vault.rerollFeeBps() / 10_000);
        assertEq(ink.balanceOf(alice), out);
    }

    function test_traitRerollThroughAgentHoldingContractPaysFullFee() public {
        uint256 tokenId = _swarm(alice);
        DiscountProxy proxy = new DiscountProxy(vault);
        vm.prank(agent);
        portraits.transferFrom(agent, address(proxy), 0);
        vm.prank(alice);
        portraits.transferFrom(alice, address(proxy), tokenId);
        vm.roll(block.number + 1);
        ink.mint(address(proxy), P / 100);
        assertEq(proxy.rerollFor(tokenId), P * vault.rerollFeeBps() / 10_000, "holder rate is not delegable");
    }

    function test_agentHolderDiscountOnlyOnOwnPullsStillHeld() public {
        uint256 pulled = _swarm(agent);
        assertTrue(portraits.heldFromVault(pulled));
        assertTrue(portraits.hasRerollDiscount(agent, pulled));
        ink.mint(agent, P / 200);
        vm.startPrank(agent);
        ink.approve(address(vault), type(uint256).max);
        assertEq(
            vault.rerollTraits(pulled, P / 200), P * vault.agentRerollFeeBps() / 10_000, "own pull: half"
        );
        vm.stopPrank();
        _mature();
        assertTrue(vault.revealTraits(pulled));
        assertTrue(portraits.heldFromVault(pulled), "a repaint is not a transfer");

        // A portrait bought or received from anyone else pays the full fee, even for an agent holder.
        uint256 bought = _swarm(alice);
        vm.prank(alice);
        portraits.transferFrom(alice, agent, bought);
        vm.roll(block.number + 1);
        assertFalse(portraits.heldFromVault(bought));
        assertFalse(portraits.hasRerollDiscount(agent, bought));
        assertEq(_deposit(agent, bought), P * vault.rerollFeeBps() / 10_000, "received portrait: full fee");
        assertEq(_deposit(agent, pulled), P * vault.agentRerollFeeBps() / 10_000, "own pull: half");

        // Moving your own pull away and back loses the discount too.
        uint256 moved = _swarm(agent);
        vm.prank(agent);
        portraits.transferFrom(agent, alice, moved);
        vm.prank(alice);
        portraits.transferFrom(alice, agent, moved);
        assertFalse(portraits.heldFromVault(moved));
        assertEq(_deposit(agent, moved), P * vault.rerollFeeBps() / 10_000);

        // Non-holders pay the full fee on their own pulls, as before.
        uint256 own = _swarm(alice);
        assertTrue(portraits.heldFromVault(own));
        assertFalse(portraits.hasRerollDiscount(alice, own));
        assertEq(_deposit(alice, own), P * vault.rerollFeeBps() / 10_000);
    }

    // ---------------------------------------------------------------- 68252bb4caa5: ownership moves in two steps

    function test_ownershipTransferRequiresAcceptance() public {
        InkRenderer renderer = new InkRenderer(portraits, owner);
        address wrong = makeAddr("wrong");
        address next = makeAddr("next");
        Ownable2Step[3] memory owned = [Ownable2Step(portraits), Ownable2Step(vault), Ownable2Step(renderer)];
        for (uint256 i; i < owned.length; i++) {
            // A transfer to an address nobody controls changes nothing until it is accepted.
            vm.prank(owner);
            owned[i].transferOwnership(wrong);
            assertEq(owned[i].owner(), owner);
            assertEq(owned[i].pendingOwner(), wrong);
            vm.prank(next);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
            owned[i].acceptOwnership();
            // The owner can still correct it.
            vm.prank(owner);
            owned[i].transferOwnership(next);
            vm.prank(next);
            owned[i].acceptOwnership();
            assertEq(owned[i].owner(), next);
            assertEq(owned[i].pendingOwner(), address(0));
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
            owned[i].transferOwnership(owner);
        }
        vm.prank(next);
        vault.setFees(200, 100);
        assertEq(vault.rerollFeeBps(), 200);
    }

    function test_cannotRenounceBeforeRequiredConfiguration() public {
        InkPortraits fresh = new InkPortraits(owner);
        InkVault freshVault = new InkVault(fresh, seats, owner);
        InkRenderer renderer = new InkRenderer(fresh, owner);
        vm.startPrank(owner);
        vm.expectRevert(InkPortraits.SetupIncomplete.selector);
        fresh.renounceOwnership();
        fresh.setVault(address(freshVault));
        vm.expectRevert(InkPortraits.SetupIncomplete.selector);
        fresh.renounceOwnership();
        fresh.setRenderer(address(renderer));
        vm.expectRevert(InkVault.SetupIncomplete.selector);
        freshVault.renounceOwnership();
        vm.expectRevert(InkRenderer.NoScript.selector);
        renderer.renounceOwnership();
        vm.expectRevert(InkRenderer.NoScript.selector);
        renderer.addChunk("");
        renderer.addChunk("const SwarmArt={render(){}};");
        renderer.renounceOwnership();
        fresh.renounceOwnership();
        vault.renounceOwnership(); // Already configured.
        vm.stopPrank();
        assertEq(renderer.owner(), address(0));
        assertEq(fresh.owner(), address(0));
        assertEq(vault.owner(), address(0));
        assertEq(freshVault.owner(), owner);
    }
}
