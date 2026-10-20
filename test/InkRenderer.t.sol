// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfiguredLiquidity} from "./helpers/ConfiguredLiquidity.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkRenderer} from "../src/InkRenderer.sol";

contract RendererSeats is ERC721("identity.md", "IMD-ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice The renderer's on-chain traits must match the owner's script exactly. traits.json holds labels
/// computed by deriveTraits() in original-art.js (regenerate with the scripts package:
/// traits-fixture), including every threshold boundary.
contract InkRendererTest is Test {
    address owner = makeAddr("owner");
    InkPortraits portraits;
    InkRenderer renderer;
    string json;

    function setUp() public {
        portraits = new InkPortraits(owner);
        renderer = new InkRenderer(portraits, owner);
        json = vm.readFile("test/fixtures/traits.json");
    }

    function _eq(string memory a, string memory b, string memory what) internal pure {
        assertEq(keccak256(bytes(a)), keccak256(bytes(b)), what);
    }

    function _labels(string memory group) internal view returns (string[][6] memory out) {
        string[6] memory keys = ["scene", "palette", "glitch", "density", "depth", "paper"];
        for (uint256 k; k < 6; k++) {
            out[k] = vm.parseJsonStringArray(json, string.concat(".flat.", group, ".", keys[k]));
        }
    }

    function _check(InkRenderer.Labels memory got, string[][6] memory e, uint256 i, string memory what)
        internal
        pure
    {
        _eq(got.scene, e[0][i], string.concat(what, " scene"));
        _eq(got.palette, e[1][i], string.concat(what, " palette"));
        _eq(got.glitch, e[2][i], string.concat(what, " glitch"));
        _eq(got.density, e[3][i], string.concat(what, " density"));
        _eq(got.depth, e[4][i], string.concat(what, " depth"));
        _eq(got.paper, e[5][i], string.concat(what, " paper"));
    }

    function test_agentTraitsMatchTheScript() public view {
        uint256[] memory seat = vm.parseJsonUintArray(json, ".flat.agent.seat");
        uint256[] memory accepted = vm.parseJsonUintArray(json, ".flat.agent.accepted");
        uint256[] memory rateBps = vm.parseJsonUintArray(json, ".flat.agent.rateBps");
        uint256[] memory turns = vm.parseJsonUintArray(json, ".flat.agent.turns");
        uint256[] memory hoursTenths = vm.parseJsonUintArray(json, ".flat.agent.hoursTenths");
        bool[] memory outdated = vm.parseJsonBoolArray(json, ".flat.agent.outdated");
        string[][6] memory e = _labels("agent");
        assertEq(seat.length, 500);
        for (uint256 i; i < seat.length; i++) {
            InkPortraits.AgentStats memory s = InkPortraits.AgentStats(
                uint32(accepted[i]), uint16(rateBps[i]), uint32(turns[i]), uint32(hoursTenths[i]), outdated[i]
            );
            _check(renderer.agentLabels(seat[i], s), e, i, string.concat("agent case ", vm.toString(i)));
        }
    }

    function test_poolTraitsMatchTheScript() public view {
        bytes32[] memory seeds = vm.parseJsonBytes32Array(json, ".flat.pool.seed");
        string[][6] memory e = _labels("pool");
        assertEq(seeds.length, 500);
        for (uint256 i; i < seeds.length; i++) {
            _check(
                renderer.swarmLabels(vm.toString(seeds[i])), e, i, string.concat("pool case ", vm.toString(i))
            );
        }
    }

    function test_scriptStoredInChunksAndLocked() public {
        bytes memory art = bytes(vm.readFile("art/original-art.js"));
        uint256 chunk = renderer.MAX_CHUNK();
        vm.startPrank(owner);
        for (uint256 off; off < art.length; off += chunk) {
            uint256 end = off + chunk > art.length ? art.length : off + chunk;
            bytes memory part = new bytes(end - off);
            for (uint256 i; i < part.length; i++) {
                part[i] = art[off + i];
            }
            renderer.addChunk(part);
        }
        renderer.lock();
        vm.expectRevert(InkRenderer.IsLocked.selector);
        renderer.addChunk("x");
        vm.stopPrank();
        assertEq(renderer.chunkCount(), (art.length + chunk - 1) / chunk);
        assertEq(keccak256(renderer.script()), keccak256(art), "script reads back byte for byte");
    }

    function test_tokenURIForAnAgentPortrait() public {
        RendererSeats seats = new RendererSeats();
        InkVault vault = new InkVault(portraits, seats, owner);
        MockERC20 ink = new MockERC20("INK", "INK", 18);
        ink.mint(address(vault), 2000 * vault.PORTRAIT());
        InkPortraits.AgentStats memory s = InkPortraits.AgentStats(3351, 9859, 10634, 467, false);
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(uint256(280), s.accepted, s.rateBps, s.turns, s.hoursTenths, s.outdated))
            )
        );
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        portraits.setRenderer(address(renderer));
        vault.setInk(IERC20(address(ink)));
        vault.setup(leaf, uint64(block.timestamp), address(new ConfiguredLiquidity(IERC20(address(ink))))); // Configured test double; this test never releases.
        renderer.addChunk("const SwarmArt={render(){}};");
        renderer.setPreviewBase("ipfs://previews/");
        vm.stopPrank();
        address holder = makeAddr("holder");
        seats.mint(holder, 280);
        vm.prank(holder);
        vault.claim(280, s, new bytes32[](0));

        string memory uri = portraits.tokenURI(280);
        assertEq(bytes(uri)[0], bytes1("d"));
        InkRenderer.Labels memory l = renderer.agentLabels(280, s);
        _eq(l.scene, "Vortex", "3,351 accepted is a Vortex");
        _eq(l.glitch, "Clean", "98.59% is clean");
        _eq(l.density, "Teeming", "10,634 turns");
        _eq(l.depth, "Abyssal", "46.7 hours");

        string memory meta = renderer.tokenJSON(280);
        _eq(vm.parseJsonString(meta, ".name"), "Agent Portrait #0280", "agent name");
        _eq(vm.parseJsonString(meta, ".portrait_type"), "agent", "agent type");
        _eq(vm.parseJsonString(meta, ".attributes[0].value"), "Agent Portrait", "agent Type trait");
        assertTrue(
            vm.contains(vm.parseJsonString(meta, ".description"), "seat #280"), "description names the seat"
        );
        assertEq(
            uri, string.concat("data:application/json;base64,", vm.toBase64(meta)), "tokenURI wraps tokenJSON"
        );

        vm.prank(address(vault));
        uint256 first = portraits.mintSwarm(holder, keccak256("first"));
        vm.prank(address(vault));
        uint256 second = portraits.mintSwarm(holder, keccak256("second"));
        meta = renderer.tokenJSON(second);
        assertEq(first, portraits.SWARM_ID_OFFSET());
        // Only seat 280 was claimed, so the swarm fills seats 0 and 1 first.
        _eq(
            vm.parseJsonString(renderer.tokenJSON(first), ".name"), "Swarm Portrait #0000", "first swarm name"
        );
        _eq(vm.parseJsonString(meta, ".name"), "Swarm Portrait #0001", "second swarm name");
        assertTrue(
            vm.contains(vm.parseJsonString(meta, ".description"), "unclaimed seat #1,"),
            "description names the seat it fills"
        );
        _eq(vm.parseJsonString(meta, ".portrait_type"), "swarm", "swarm type");
        _eq(vm.parseJsonString(meta, ".attributes[0].value"), "Swarm Portrait", "swarm Type trait");
    }

    /// Swarm portraits take the unclaimed seats' numbers, lowest first, across all eight bitmap words.
    function test_swarmNumbersFillUnclaimedSeats() public {
        InkVault vault = new InkVault(portraits, new RendererSeats(), owner);
        vm.prank(owner);
        portraits.setVault(address(vault));
        vm.startPrank(address(vault));
        InkPortraits.AgentStats memory s;
        // Claim every seat except 1, 3, 255, 256, 1791, 1792 and 1999.
        for (uint256 seat; seat < 2000; seat++) {
            if (
                seat == 1 || seat == 3 || seat == 255 || seat == 256 || seat == 1791 || seat == 1792
                    || seat == 1999
            ) continue;
            portraits.mintAgent(seat, address(this), s);
        }
        uint256[7] memory expected = [uint256(1), 3, 255, 256, 1791, 1792, 1999];
        for (uint256 i; i < 7; i++) {
            uint256 id = portraits.mintSwarm(address(this), bytes32(i));
            assertEq(portraits.swarmNumber(id), expected[i], "fills the next unclaimed seat");
        }
        assertEq(portraits.totalSupply(), 2000, "every number used once");
        vm.expectRevert(InkPortraits.SoldOut.selector);
        portraits.mintSwarm(address(this), bytes32(0));
        vm.expectRevert(InkPortraits.NotASwarmPortrait.selector);
        portraits.swarmNumber(5);
    }

    function test_noClaimsAfterTheFirstSwarmPortrait() public {
        InkVault vault = new InkVault(portraits, new RendererSeats(), owner);
        vm.prank(owner);
        portraits.setVault(address(vault));
        vm.startPrank(address(vault));
        InkPortraits.AgentStats memory s;
        portraits.mintAgent(0, address(this), s);
        uint256 id = portraits.mintSwarm(address(this), bytes32(0));
        assertEq(portraits.swarmNumber(id), 1);
        vm.expectRevert(InkPortraits.SwarmStarted.selector);
        portraits.mintAgent(1, address(this), s);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
