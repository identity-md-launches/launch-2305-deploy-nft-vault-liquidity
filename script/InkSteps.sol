// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkHook} from "../src/InkHook.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";

/// @notice The owner's setup steps, with every check that should pass before each one. Used by the
/// ConfigureNft / OpenClaims scripts (which the owner broadcasts when the time comes) and by Rehearse (which
/// runs the same steps on an in-memory mainnet fork and never broadcasts).
abstract contract InkSteps is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant SEATS = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    uint256 constant PORTRAIT = 400_000e18;
    /// IMD fee beneficiary only, including hook/LP fees and the router's IMD receipts.
    /// Every owner role and royalty beneficiary is the separately supplied launch owner.
    address constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;
    /// Released INK starts 16,000 ticks (about 5x) above the opening price, so the unclaimed seats' INK
    /// isn't sold off at IMD's fixed 2,500 IMD opening price.
    int24 constant RELEASE_PREMIUM = 16_000;
    /// Owner's schedule: claims open Tue 20 Oct 2026, 9:00 US Eastern (13:00 UTC), and close 24 hours later,
    /// when release() becomes callable (the API server's release scheduler sends it right away).
    uint64 constant CLAIM_START = 1_792_501_200;

    error Check(string what);

    function _require(bool ok, string memory what) internal pure {
        if (!ok) revert Check(what);
    }

    function artScript() public view returns (bytes memory) {
        string memory src = vm.readFile("../artifacts/empty-harness/src/lib/original-art.js");
        return bytes(vm.replace(src, "export default SwarmArt;", ""));
    }

    /// Checks the contracts launch delivered what was asked: owners, wiring, no stray roles.
    function checkContractsLaunch(
        InkPortraits portraits,
        InkVault vault,
        InkLiquidity liq,
        InkRenderer renderer,
        address owner
    ) public view {
        _require(portraits.owner() == owner, "InkPortraits owner");
        _require(vault.owner() == owner, "InkVault owner");
        _require(liq.owner() == owner, "InkLiquidity owner");
        _require(liq.treasury() == TREASURY, "InkLiquidity treasury");
        _require(renderer.owner() == owner, "InkRenderer owner");
        _require(address(vault.portraits()) == address(portraits), "vault -> portraits");
        _require(address(vault.seats()) == SEATS, "vault -> identity.md seats");
        _require(address(liq.poolManager()) == address(MANAGER), "liquidity -> PoolManager");
        _require(address(liq.positionManager()) == POSM, "liquidity -> PositionManager");
        (address royaltyTo, uint256 royalty) = portraits.royaltyInfo(0, 10_000);
        _require(royaltyTo == owner, "royalty receiver");
        _require(royalty == 0, "0% trading fee");
    }

    /// Step 2: wire the NFT to the vault and renderer and upload the art (not locked here).
    function stepConfigureNft(InkPortraits portraits, InkVault vault, InkRenderer renderer) internal {
        _require(portraits.vault() == address(0), "vault already set");
        portraits.setVault(address(vault));
        portraits.setRenderer(address(renderer));
        if (renderer.chunkCount() == 0) {
            bytes memory art = artScript();
            uint256 chunk = renderer.MAX_CHUNK();
            for (uint256 off; off < art.length; off += chunk) {
                uint256 end = off + chunk > art.length ? art.length : off + chunk;
                bytes memory part = new bytes(end - off);
                for (uint256 i; i < part.length; i++) {
                    part[i] = art[off + i];
                }
                renderer.addChunk(part);
            }
        }
    }

    /// Checks the hook launch: the hook's immutables, the pool, and the vault's 80%.
    function checkHookLaunch(
        InkHook hook,
        InkPortraits portraits,
        InkVault vault,
        address treasury,
        IERC20 ink,
        PoolKey memory key
    ) public view {
        _require(address(hook.poolManager()) == address(MANAGER), "hook -> PoolManager");
        _require(address(hook.portraits()) == address(portraits), "hook -> portraits");
        _require(address(hook.vault()) == address(vault), "hook -> vault");
        _require(Currency.unwrap(hook.imd()) == IMD, "hook -> IMD");
        _require(hook.treasury() == treasury, "hook treasury");
        _require(hook.feeBps() == 25, "hook fee");
        _require(hook.poolCreated() && Currency.unwrap(hook.ink()) == address(ink), "hook saw the INK pool");
        _require(address(key.hooks) == address(hook), "pool key hook");
        (uint160 sqrtPrice,,,) = MANAGER.getSlot0(key.toId());
        _require(sqrtPrice != 0, "pool initialized");
        _require(ink.totalSupply() == 1_000_000_000e18, "INK supply");
        _require(ink.balanceOf(address(vault)) >= 2000 * PORTRAIT, "vault holds 800M INK");
        _require(!hook.tradingOpen(), "pool still locked");
    }

    /// Step 4: point the vault and liquidity at INK and schedule the 24-hour window.
    function stepOpenClaims(
        InkVault vault,
        InkLiquidity liq,
        IERC20 ink,
        PoolKey memory key,
        bytes32 root,
        uint64 start
    ) internal {
        _require(root != bytes32(0), "snapshot root");
        _require(start >= block.timestamp && start <= block.timestamp + 30 days, "claim start within 30 days");
        vault.setInk(ink);
        // Premium first, as the documented order. addLiquidity() is only callable from the vault's release
        // on, so this order is no longer load-bearing: nobody can list INK and lock the premium before it.
        liq.setPremium(RELEASE_PREMIUM);
        liq.setPool(key, ink);
        vault.setup(root, start, address(liq));
    }
}
