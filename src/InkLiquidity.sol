// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {InkHook} from "./InkHook.sol";
import {InkVault} from "./InkVault.sol";

/// @title Ink liquidity
/// @notice Adds INK to the INK/IMD pool and keeps the positions forever: it has no way to remove
/// liquidity or move a position, so nobody (the owner included) can take the INK back out.
/// It receives the unclaimed seats' INK from the vault after the 24-hour window. Anyone can call
/// It also receives every INK fee in the system (hook fees, reroll fees, and the INK side of its own LP fees)
/// instead of burning it. Anyone can call
/// addLiquidity() to put its INK into the pool, single-sided, just past the current price, and never below
/// the price the pool had when setPool() was called (the opening price, since the pool is locked until
/// release). Without that floor, a dust sell through the empty side of a single-sided pool could drag the
/// price to the extreme for free and the released INK would be listed at almost nothing.
/// The positions earn the pool's LP fee like any other liquidity. Anyone can call collectFees(): the IMD side
/// goes to the treasury and the INK side stays here for the next addLiquidity(), the same split as the hook's fee.
contract InkLiquidity is Ownable2Step, IERC721Receiver {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    /// @notice Receives the IMD side of the LP fees (the same wallet as the hook's treasury).
    address public immutable treasury;

    IERC20 public ink;
    PoolKey public poolKey;
    bool public poolSet;
    /// @notice The vault the pool's hook is bound to; INK is listed only once it has released.
    InkVault public vault;
    /// @notice The pool's tick when setPool() was called; released INK is never listed below this price.
    int24 public floorTick;
    /// @notice Width of a single position, in ticks (about 7.4x in price at 20,000). Used once the price has
    /// passed the release start; below it, INK goes in as the ladder.
    int24 public width = 20_000;
    /// @notice The release ladder: LADDER_BANDS positions of LADDER_BAND_WIDTH ticks each, stacked upward from
    /// the release start, each with twice the liquidity of the one below. 8 x 5,800 ticks is about 100x in
    /// price (5x to ~500x the opening price with the launch premium). Thin at the bottom so the price keeps
    /// moving as people buy, with no wall at the release start; deeper higher up so no one cheaply corners
    /// the supply.
    uint256 public constant LADDER_BANDS = 8;
    int24 public constant LADDER_BAND_WIDTH = 5_800;
    /// @notice How far above the opening price (in ticks, INK dearer) released INK starts; 0 = at the floor.
    /// About 6,931 ticks doubles the price. Can only be set before the first position.
    int24 public premium;

    /// @notice addLiquidity() waits until at least one portrait's worth of INK has built up, so fees go back
    /// in as a few sizeable positions rather than many dust ones (which would also be cheaper to sandwich).
    uint256 public constant MIN_ADD = 400_000e18;
    address public constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    uint256[] public positions;

    event PoolSet(PoolId indexed poolId, address ink);
    event LiquidityAdded(uint256 indexed positionId, int24 tickLower, int24 tickUpper, uint256 inkAmount);
    event WidthSet(int24 width);
    event PremiumSet(int24 premium);
    event FeesCollected(uint256 fromIndex, uint256 toIndex, uint256 otherToTreasury, uint256 inkKept);

    error PoolAlreadySet();
    error PoolNotSet();
    error PoolNotInitialized();
    error NotInkPool();
    error NothingToAdd();
    error BelowMinAdd();
    error BadWidth();
    error BadPremium();
    error NothingToCollect();
    error ZeroTreasury();
    error InvalidHook();
    error InvalidPositionManager();
    error UnexpectedNFT();
    error NotReleased();

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        address owner_,
        address treasury_
    ) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroTreasury();
        poolManager = poolManager_;
        positionManager = positionManager_;
        treasury = treasury_;
    }

    /// @notice Points at the swarm-launched INK/IMD pool. Once.
    function setPool(PoolKey calldata key, IERC20 ink_) external onlyOwner {
        if (poolSet) revert PoolAlreadySet();
        Currency c = Currency.wrap(address(ink_));
        if (!(key.currency0 == c || key.currency1 == c)) revert NotInkPool();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        InkVault boundVault = _checkHook(key, ink_);
        if (address(positionManager.poolManager()) != address(poolManager)) revert InvalidPositionManager();
        poolKey = key;
        ink = ink_;
        vault = boundVault;
        poolSet = true;
        floorTick = tick;
        emit PoolSet(key.toId(), address(ink_));
    }

    /// @dev The later hook launch supplies these bindings; no dependency is called in the constructor.
    function _checkHook(PoolKey calldata key, IERC20 ink_) internal view returns (InkVault boundVault) {
        if (address(key.hooks).code.length == 0) revert InvalidHook();
        InkHook hook = InkHook(address(key.hooks));
        Currency other = Currency.unwrap(key.currency0) == address(ink_) ? key.currency1 : key.currency0;
        if (
            !hook.poolCreated() || address(hook.poolManager()) != address(poolManager)
                || Currency.unwrap(hook.ink()) != address(ink_)
                || Currency.unwrap(hook.imd()) != Currency.unwrap(other) || hook.treasury() != treasury
                || (block.chainid == 1 && Currency.unwrap(other) != MAINNET_IMD)
        ) revert InvalidHook();
        boundVault = InkVault(address(hook.vault()));
        if (
            boundVault.ink() != ink_ || address(boundVault.portraits()) != address(hook.portraits())
                || boundVault.portraits().vault() != address(boundVault) || boundVault.owner() != owner()
        ) revert InvalidHook();
    }

    function renounceOwnership() public override onlyOwner {
        if (!poolSet) revert PoolNotSet();
        super.renounceOwnership();
    }

    function setWidth(int24 width_) external onlyOwner {
        if (width_ < poolKey.tickSpacing) revert BadWidth();
        width = width_;
        emit WidthSet(width_);
    }

    /// @notice Sets the release premium. Only before any INK is listed, so it can't reprice live liquidity.
    function setPremium(int24 premium_) external onlyOwner {
        if (premium_ < 0 || premium_ > 100_000 || positions.length != 0) revert BadPremium();
        premium = premium_;
        emit PremiumSet(premium_);
    }

    /// @notice Adds all INK this contract holds to the pool, single-sided, once it holds at least MIN_ADD.
    /// While the price hasn't passed the release start (opening price plus premium), it goes in as the release
    /// ladder from there; after that, as one `width`-tick position just past the current price. Anyone can
    /// call it, from the vault's release on (the pool is locked until then, and listing INK earlier would only
    /// fix the premium before the owner has set it). Returns the first new position.
    function addLiquidity() external returns (uint256 positionId) {
        if (!poolSet) revert PoolNotSet();
        if (!vault.released()) revert NotReleased();
        uint256 amount = ink.balanceOf(address(this));
        if (amount == 0) revert NothingToAdd();
        if (amount < MIN_ADD) revert BelowMinAdd();
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
        int24 start = releaseStartTick();
        if (_inkIs0() ? tick <= start : tick >= start) return _addLadder(start, amount);
        (int24 lower, int24 upper) = _rangeFrom(tick, width);
        positionId = _add(lower, upper, amount);
    }

    /// @notice The tick the released INK starts at: the opening price plus the premium, INK dearer.
    function releaseStartTick() public view returns (int24) {
        return _inkIs0() ? floorTick + premium : floorTick - premium;
    }

    /// @dev Splits `amount` over the ladder's bands so band k gets 2^k times the liquidity of band 0.
    function _addLadder(int24 start, uint256 amount) internal returns (uint256 firstId) {
        bool inkIs0 = _inkIs0();
        int24[] memory lowers = new int24[](LADDER_BANDS);
        int24[] memory uppers = new int24[](LADDER_BANDS);
        uint256[] memory weights = new uint256[](LADDER_BANDS);
        uint256 total;
        int24 from = start;
        for (uint256 k; k < LADDER_BANDS; k++) {
            (int24 lower, int24 upper) = _rangeFrom(from, LADDER_BAND_WIDTH);
            if (lower >= upper) break; // ran into the end of the price range
            lowers[k] = lower;
            uppers[k] = upper;
            // INK needed for 2^k units of liquidity in this band.
            uint128 unitLiq = uint128(1e24) << k;
            uint160 sa = TickMath.getSqrtPriceAtTick(lower);
            uint160 sb = TickMath.getSqrtPriceAtTick(upper);
            weights[k] = inkIs0
                ? SqrtPriceMath.getAmount0Delta(sa, sb, unitLiq, false)
                : SqrtPriceMath.getAmount1Delta(sa, sb, unitLiq, false);
            total += weights[k];
            // The next band starts where this one ends (on INK's side of it).
            from = inkIs0 ? upper - poolKey.tickSpacing : lower;
        }
        uint256 left = amount;
        for (uint256 k; k < LADDER_BANDS && weights[k] != 0; k++) {
            bool last = k + 1 == LADDER_BANDS || weights[k + 1] == 0;
            uint256 amt = last ? left : (amount * weights[k]) / total;
            left -= amt;
            uint256 id = _add(lowers[k], uppers[k], amt);
            if (k == 0) firstId = id;
        }
    }

    function _add(int24 lower, int24 upper, uint256 amount) internal returns (uint256 positionId) {
        positionId = _mintSingleSided(lower, upper, amount);
        positions.push(positionId);
        emit LiquidityAdded(positionId, lower, upper, amount);
    }

    /// @notice Collects the LP fees earned by positions[from .. to) (clamped to the list): the other side
    /// (IMD) goes to the treasury and INK stays here to be added back by addLiquidity(). Takes a range so a pile
    /// of dust positions can't make it run out of gas. Anyone can call it.
    function collectFees(uint256 from, uint256 to) external returns (uint256 otherOut, uint256 inkKept) {
        if (!poolSet) revert PoolNotSet();
        if (to > positions.length) to = positions.length;
        if (from >= to) revert NothingToCollect();
        Currency inkC = Currency.wrap(address(ink));
        Currency other = _inkIs0() ? poolKey.currency1 : poolKey.currency0;
        address to_ = treasury;
        uint256 otherBefore = other.balanceOf(to_);
        uint256 inkBefore = ink.balanceOf(address(this));

        uint256 n = to - from;
        bytes memory actions = new bytes(n + 2);
        bytes[] memory params = new bytes[](n + 2);
        for (uint256 i; i < n; i++) {
            // Removing zero liquidity just credits the position's fees to this contract.
            actions[i] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(positions[from + i], uint256(0), uint128(0), uint128(0), bytes(""));
        }
        actions[n] = bytes1(uint8(Actions.TAKE));
        params[n] = abi.encode(other, to_, ActionConstants.OPEN_DELTA);
        actions[n + 1] = bytes1(uint8(Actions.TAKE));
        params[n + 1] = abi.encode(inkC, address(this), ActionConstants.OPEN_DELTA);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        otherOut = other.balanceOf(to_) - otherBefore;
        inkKept = ink.balanceOf(address(this)) - inkBefore;
        emit FeesCollected(from, to, otherOut, inkKept);
    }

    function _inkIs0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(ink);
    }

    /// @dev A range of `w` ticks starting just past `tick`, on INK's side of it, and never below the release
    /// start. Price in ticks is IMD per INK when INK is currency0, INK per IMD when it's currency1, so "never
    /// cheaper" means tick >= start or tick <= start respectively.
    function _rangeFrom(int24 tick, int24 w) internal view returns (int24 lower, int24 upper) {
        int24 spacing = poolKey.tickSpacing;
        int24 start = releaseStartTick();
        if (_inkIs0() ? tick < start : tick > start) tick = start;
        w = (w / spacing) * spacing;
        if (w == 0) w = spacing;
        // Widen in int256 so a width near type(int24).max clamps instead of overflowing.
        if (_inkIs0()) {
            // Token0-only liquidity sits above the price.
            lower = _floor(tick, spacing) + spacing;
            int256 maxTick = TickMath.maxUsableTick(spacing);
            int256 up = int256(lower) + int256(w);
            upper = int24(up > maxTick ? maxTick : up);
        } else {
            // Token1-only liquidity sits below the price.
            upper = _floor(tick, spacing);
            int256 minTick = TickMath.minUsableTick(spacing);
            int256 low = int256(upper) - int256(w);
            lower = int24(low < minTick ? minTick : low);
        }
    }

    function _mintSingleSided(int24 lower, int24 upper, uint256 amount)
        internal
        returns (uint256 positionId)
    {
        bool inkIs0 = _inkIs0();
        uint128 liq = inkIs0
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
            );

        positionId = positionManager.nextTokenId();
        ink.safeTransfer(address(positionManager), amount);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            lower,
            upper,
            uint256(liq),
            inkIs0 ? uint128(amount) : uint128(0),
            inkIs0 ? uint128(0) : uint128(amount),
            address(this),
            bytes("")
        );
        // The position manager pays from the INK just sent to it, then returns any rounding dust.
        params[1] = abi.encode(Currency.wrap(address(ink)), ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(Currency.wrap(address(ink)), address(this));
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SWEEP)),
                params
            ),
            block.timestamp
        );
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert UnexpectedNFT();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }
}
