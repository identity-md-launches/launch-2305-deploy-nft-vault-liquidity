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
import {UploadRenderer} from "../script/UploadRenderer.s.sol";

contract PreviewSeats is ERC721("identity.md", "IMD-ID") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Writes real tokenURIs (the full art script uploaded, as UploadRenderer does) to out-preview/ so
/// they can be opened in a browser and checked by eye.
contract TokenURIPreviewTest is Test {
    function test_writeTokenURIs() public {
        address owner = makeAddr("owner");
        PreviewSeats seats = new PreviewSeats();
        InkPortraits portraits = new InkPortraits(owner);
        InkVault vault = new InkVault(portraits, seats, owner);
        InkRenderer renderer = new InkRenderer(portraits, owner);
        MockERC20 ink = new MockERC20("INK", "INK", 18);
        ink.mint(address(vault), 2000 * vault.PORTRAIT());

        InkPortraits.AgentStats memory s = InkPortraits.AgentStats(3351, 9859, 10634, 467, false);
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(abi.encode(uint256(280), s.accepted, s.rateBps, s.turns, s.hoursTenths, s.outdated))
            )
        );

        bytes memory art = new UploadRenderer().artScript();
        uint256 chunk = renderer.MAX_CHUNK();
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        portraits.setRenderer(address(renderer));
        vault.setInk(IERC20(address(ink)));
        vault.setup(leaf, uint64(block.timestamp), address(new ConfiguredLiquidity(IERC20(address(ink))))); // Configured test double; this test never releases.
        for (uint256 off; off < art.length; off += chunk) {
            uint256 end = off + chunk > art.length ? art.length : off + chunk;
            bytes memory part = new bytes(end - off);
            for (uint256 i; i < part.length; i++) {
                part[i] = art[off + i];
            }
            renderer.addChunk(part);
        }
        vm.stopPrank();

        address holder = makeAddr("holder");
        seats.mint(holder, 280);
        vm.prank(holder);
        vault.claim(280, s, new bytes32[](0));
        _check("out-preview/agent-280.txt", portraits.tokenURI(280));

        // A pool portrait, minted straight from the vault's address.
        vm.prank(address(vault));
        uint256 poolId = portraits.mintSwarm(holder, keccak256("preview pool seed"));
        _check("out-preview/pool.txt", portraits.tokenURI(poolId));
    }

    /// Asserts a real JSON data URI, then saves it if this profile may write (read-only profiles just log).
    function _check(string memory path, string memory uri) internal {
        assertTrue(vm.contains(uri, "data:application/json;base64,"), "tokenURI is a JSON data URI");
        assertGt(bytes(uri).length, 10_000, "tokenURI carries the art");
        try vm.writeFile(path, uri) {}
        catch {
            emit log_string(string.concat(
                    "read-only profile: not written ", path, " (use FOUNDRY_PROFILE=preview)"
                ));
        }
    }
}
