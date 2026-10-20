// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfiguredLiquidity} from "./helpers/ConfiguredLiquidity.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";

contract AllSeats is ERC721("identity.md", "IMD-ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Every one of the 2,000 seats claims with its proof from a full snapshot tree, as written by
/// scripts/src/snapshot.ts (OpenZeppelin StandardMerkleTree dump). Proofs are rebuilt here from the tree array
/// the way OpenZeppelin's library does, so the whole published tree, not a sample, is checked against
/// InkVault.claim(). Point SNAPSHOT_TREE at the production tree.json before claims open.
contract SnapshotAllSeatsTest is Test {
    string constant DEFAULT_TREE = "../research/snapshot/2026-10-14T02-23-59-394Z/tree.json";

    AllSeats seats;
    InkPortraits portraits;
    InkVault vault;
    bool[2000] seen;

    /// Skips when the real tree isn't readable here (e.g. the public package, which leaves the snapshot out).
    modifier onlySnapshot() {
        try vm.readFile(vm.envOr("SNAPSHOT_TREE", string(DEFAULT_TREE))) returns (string memory) {}
        catch {
            vm.skip(true);
            return;
        }
        _;
    }

    /// Every seat 0–1999 appears exactly once.
    function test_treeHasEverySeatOnce() public onlySnapshot {
        string memory json = vm.readFile(vm.envOr("SNAPSHOT_TREE", string(DEFAULT_TREE)));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".values[", vm.toString(n), "]"))) {
            uint256 seat = vm.parseJsonUint(json, string.concat(".values[", vm.toString(n), "].value[0]"));
            assertLt(seat, 2000);
            assertFalse(seen[seat], "each seat appears once");
            seen[seat] = true;
            n++;
        }
        assertEq(n, 2000, "the tree holds all 2,000 seats");
    }

    // All 2,000 claims, in eight batches (one test can't hold 2,000 claims' worth of memory; each real claim is
    // its own transaction).
    function test_claims_0000() public onlySnapshot {
        _batch(0);
    }

    function test_claims_0250() public onlySnapshot {
        _batch(250);
    }

    function test_claims_0500() public onlySnapshot {
        _batch(500);
    }

    function test_claims_0750() public onlySnapshot {
        _batch(750);
    }

    function test_claims_1000() public onlySnapshot {
        _batch(1000);
    }

    function test_claims_1250() public onlySnapshot {
        _batch(1250);
    }

    function test_claims_1500() public onlySnapshot {
        _batch(1500);
    }

    function test_claims_1750() public onlySnapshot {
        _batch(1750);
    }

    function _batch(uint256 from) internal {
        string memory json = vm.readFile(vm.envOr("SNAPSHOT_TREE", string(DEFAULT_TREE)));
        bytes32[] memory tree = vm.parseJsonBytes32Array(json, ".tree");
        address owner = makeAddr("owner");
        seats = new AllSeats();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        MockERC20 ink = new MockERC20("INK", "INK", 18);
        ink.mint(address(vault), 2000 * vault.PORTRAIT());
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        vault.setInk(IERC20(address(ink)));
        vault.setup(tree[0], uint64(block.timestamp), address(new ConfiguredLiquidity(IERC20(address(ink))))); // Configured test double; this test never releases.
        vm.stopPrank();

        uint256 totalGas;
        uint256 maxGas;
        uint256 maxDepth;
        for (uint256 n = from; n < from + 250; n++) {
            (uint256 g, uint256 depth) = _claim(json, tree, n);
            totalGas += g;
            if (g > maxGas) maxGas = g;
            if (depth > maxDepth) maxDepth = depth;
        }
        assertEq(portraits.agentMinted(), 250);
        emit log_named_uint("max proof length", maxDepth);
        emit log_named_uint("avg claim gas (execution)", totalGas / 250);
        emit log_named_uint("max claim gas (execution)", maxGas);
    }

    function _stats(string memory json, string memory p)
        internal
        pure
        returns (InkPortraits.AgentStats memory s)
    {
        s.accepted = uint32(vm.parseJsonUint(json, string.concat(p, ".value[1]")));
        s.rateBps = uint16(vm.parseJsonUint(json, string.concat(p, ".value[2]")));
        s.turns = uint32(vm.parseJsonUint(json, string.concat(p, ".value[3]")));
        s.hoursTenths = uint32(vm.parseJsonUint(json, string.concat(p, ".value[4]")));
        s.outdated = vm.parseJsonBool(json, string.concat(p, ".value[5]"));
    }

    function _claim(string memory json, bytes32[] memory tree, uint256 n)
        internal
        returns (uint256 gasUsed, uint256 depth)
    {
        string memory p = string.concat(".values[", vm.toString(n), "]");
        uint256 seat = vm.parseJsonUint(json, string.concat(p, ".value[0]"));
        InkPortraits.AgentStats memory s = _stats(json, p);
        bytes32[] memory proof = _proof(tree, vm.parseJsonUint(json, string.concat(p, ".treeIndex")));
        address holder = address(uint160(0x5EA70000 + seat + 1));
        seats.mint(holder, seat);
        uint256 g = gasleft();
        vm.prank(holder);
        vault.claim(seat, s, proof);
        return (g - gasleft(), proof.length);
    }

    /// OpenZeppelin StandardMerkleTree: sibling = i odd ? i + 1 : i - 1; parent = (i - 1) / 2.
    function _proof(bytes32[] memory t, uint256 i) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory tmp = new bytes32[](32);
        uint256 len;
        while (i > 0) {
            tmp[len++] = t[i % 2 == 1 ? i + 1 : i - 1];
            i = (i - 1) / 2;
        }
        proof = new bytes32[](len);
        for (uint256 k; k < len; k++) {
            proof[k] = tmp[k];
        }
    }
}
