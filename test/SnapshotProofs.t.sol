// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfiguredLiquidity} from "./helpers/ConfiguredLiquidity.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";

contract FixtureSeats is ERC721("identity.md", "IMD-ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Uses deterministic SYNTHETIC metrics for 2,000 seats and OpenZeppelin
/// StandardMerkleTree proofs. No real snapshot/cutoff is included or validated.
contract SnapshotProofsTest is Test {
    address owner = makeAddr("owner");
    FixtureSeats seats;
    InkPortraits portraits;
    InkVault vault;
    string json;

    function setUp() public {
        json = vm.readFile("test/fixtures/snapshot-sample.json");
        seats = new FixtureSeats();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        MockERC20 ink = new MockERC20("INK", "INK", 18);
        ink.mint(address(vault), 2000 * vault.PORTRAIT());
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        vault.setInk(IERC20(address(ink)));
        vault.setup(
            vm.parseJsonBytes32(json, ".root"),
            uint64(block.timestamp),
            address(new ConfiguredLiquidity(IERC20(address(ink))))
        ); // Configured test double; this test never releases.
        vm.stopPrank();
    }

    function _entry(uint256 i)
        internal
        view
        returns (uint256 seat, InkPortraits.AgentStats memory s, bytes32[] memory proof)
    {
        string memory p = string.concat(".entries[", vm.toString(i), "]");
        seat = vm.parseJsonUint(json, string.concat(p, ".seat"));
        s = InkPortraits.AgentStats({
            accepted: uint32(vm.parseJsonUint(json, string.concat(p, ".accepted"))),
            rateBps: uint16(vm.parseJsonUint(json, string.concat(p, ".rateBps"))),
            turns: uint32(vm.parseJsonUint(json, string.concat(p, ".turns"))),
            hoursTenths: uint32(vm.parseJsonUint(json, string.concat(p, ".hoursTenths"))),
            outdated: vm.parseJsonBool(json, string.concat(p, ".outdated"))
        });
        proof = vm.parseJsonBytes32Array(json, string.concat(p, ".proof"));
    }

    function test_realSnapshotProofsClaim() public {
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".entries[", vm.toString(n), "]"))) n++;
        assertGt(n, 0);
        for (uint256 i; i < n; i++) {
            (uint256 seat, InkPortraits.AgentStats memory s, bytes32[] memory proof) = _entry(i);
            address holder = makeAddr(string.concat("holder", vm.toString(seat)));
            seats.mint(holder, seat);
            vm.prank(holder);
            vault.claim(seat, s, proof);
            assertEq(portraits.ownerOf(seat), holder);
            InkPortraits.AgentStats memory stored = portraits.agentStats(seat);
            assertEq(stored.accepted, s.accepted);
            assertEq(stored.rateBps, s.rateBps);
            assertEq(stored.turns, s.turns);
            assertEq(stored.hoursTenths, s.hoursTenths);
            assertEq(stored.outdated, s.outdated);
        }
    }

    function test_tamperedStatsAreRejected() public {
        (uint256 seat, InkPortraits.AgentStats memory s, bytes32[] memory proof) = _entry(0);
        address holder = makeAddr("holder");
        seats.mint(holder, seat);
        s.accepted += 1; // claim a little more work than the snapshot recorded
        vm.prank(holder);
        vm.expectRevert(InkVault.InvalidProof.selector);
        vault.claim(seat, s, proof);
    }
}
