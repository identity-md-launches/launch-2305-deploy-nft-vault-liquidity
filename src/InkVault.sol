// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InkPortraits} from "./InkPortraits.sol";

interface IInkLiquidity {
    function addLiquidity() external returns (uint256 positionId);
    function ink() external view returns (IERC20);
    function poolSet() external view returns (bool);
}

/// @title Ink vault
/// @notice 400,000 INK is one portrait, and at most 2,000 can ever exist. INK is created by the IMD swarm's v4
/// launch, which sends 80% of the supply here: a full portrait's worth for each of the 2,000 identity.md
/// seats. The pool stays closed until release().
/// - Claim (first 24 hours, free): the current owner of any seat mints that seat's agent portrait, painted
///   from its work record (a Sketch if it has little or none). One per seat. The seat's 400,000 INK stays
///   here, backing the portrait.
/// - Release (after 24 hours): every unclaimed seat becomes a swarm slot, its 400,000 INK is added to the
///   pool, and the pool opens for trading (the hook waits for released()).
/// - Pull (after release): lock 400,000 INK to get a random portrait. The pick comes from the hash of the
///   block after the pull, so it can't be known (or retried) when the INK is spent. Anyone can reveal it.
///   Pulls are revealed strictly in order, and a portrait handed in only joins the draw for pulls made in
///   later blocks, so once a block hash is public nobody can change what it picks.
/// - Reroll: hand a swarm portrait back for 400,000 INK minus a fee. Holders of an agent portrait pay half on
///   the portraits they pulled and still hold (not on ones bought or handed to them, so the discount can't be
///   resold through a contract that holds one agent portrait).
/// - Trait reroll: pay the same fee to give a swarm portrait you hold a new random seed, drawn from the hash
///   of the block after the request like a pull. Same token, new art and traits.
/// - Agent deposit: hand an agent portrait in for exactly 400,000 INK. It joins the draw, so any pull can
///   land a one-of-a-kind agent portrait.
/// Every fee goes to the liquidity contract, which adds it back to the pool; nothing is burned.
/// Every portrait outside the vault is backed by 400,000 INK inside it.
contract InkVault is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant PORTRAIT = 400_000e18;
    uint256 public constant SEATS = 2000;
    uint64 public constant CLAIM_WINDOW = 24 hours;
    uint16 public constant MAX_FEE_BPS = 500;
    /// @notice The claim window must open within this long of setup().
    uint64 public constant MAX_START_DELAY = 30 days;
    /// @notice Maximum deposits admitted per reveal step; large queues continue over several calls.
    uint256 public constant MAX_ADMISSIONS = 100;

    struct Pull {
        address to;
        uint64 blockNumber;
        bool done;
    }

    /// @dev A portrait handed in, waiting to join the draw.
    struct Incoming {
        uint256 tokenId;
        uint64 blockNumber;
    }

    enum Step {
        Revealed,
        TooEarly,
        Expired,
        Admitting
    }

    InkPortraits public immutable portraits;
    IERC721 public immutable seats;

    /// @notice INK, set once after the swarm launch creates it.
    IERC20 public ink;
    /// @notice Gets the unclaimed seats' INK after the window, and every fee, to add to the pool.
    address public liquidity;

    // Set once by setup().
    /// @notice Root of every seat's stats (OpenZeppelin StandardMerkleTree, double-hashed leaves of
    /// abi.encode(uint256 seat, uint32 accepted, uint16 rateBps, uint32 turns, uint32 hoursTenths, bool outdated)).
    /// Seats with no work are in it too, with zeros.
    bytes32 public statsRoot;
    uint64 public claimStart;
    uint64 public claimEnd;

    uint16 public rerollFeeBps = 100;
    uint16 public agentRerollFeeBps = 50;

    bool public released;
    /// @dev Portraits a pull can land on.
    uint256[] internal _inventory;
    /// @dev Portraits handed in that join `_inventory` for pulls made in a later block.
    Incoming[] internal _incoming;
    uint256 internal _incomingHead;
    Pull[] public pulls;
    /// @notice The next pull to reveal. Pulls are revealed in order.
    uint256 public nextReveal;
    /// @notice Reroll fee fixed at purchase, retained if a pull expires without a recorded draw.
    mapping(uint256 pullId => uint256) public pullExpiryFee;
    mapping(uint256 pullId => bool) public pullExpired;
    /// @dev Preserve the original draw across bounded admission calls.
    mapping(uint256 pullId => bytes32) internal _pullEntropy;
    /// @dev How many portraits were handed in during the latest deposit block. They don't count for pulls
    /// made in that block, since those never admit them.
    uint64 internal _lastDepositBlock;
    uint192 internal _depositedInBlock;
    /// @notice The block of a swarm portrait's pending trait reroll; 0 when none is pending.
    mapping(uint256 tokenId => uint64) public traitRerollBlock;

    event InkSet(address ink);
    event Setup(bytes32 statsRoot, uint64 claimStart, uint64 claimEnd, address liquidity);
    event AgentClaimed(uint256 indexed seat, address indexed to);
    event Released(uint256 unclaimedSeats, uint256 inkToPool);
    event Pulled(uint256 indexed pullId, address indexed to, uint64 blockNumber);
    event PullExpired(uint256 indexed pullId, address indexed to, uint256 refund, uint256 fee);
    event AdmissionProgress(uint256 indexed pullId, uint256 admitted);
    event Revealed(uint256 indexed pullId, address indexed to, uint256 tokenId, bool newlyMinted);
    event Deposited(address indexed from, uint256 indexed tokenId, uint256 inkOut, uint256 fee);
    event TraitRerollRequested(uint256 indexed tokenId, address indexed by, uint256 fee, uint64 blockNumber);
    event TraitRerollExpired(uint256 indexed tokenId);
    event TraitsRerolled(uint256 indexed tokenId, bytes32 seed);
    event FeesSet(uint16 rerollFeeBps, uint16 agentRerollFeeBps);

    error InkAlreadySet();
    error InkNotSet();
    error NotFunded();
    error AlreadySetUp();
    error BadSetup();
    error ClaimClosed();
    error ClaimStillOpen();
    error AlreadyReleased();
    error NotSeatOwner();
    error InvalidProof();
    error ZeroPulls();
    error UnknownPull();
    error AlreadyRevealed();
    error TooEarly();
    error NoneAvailable();
    error FeeTooHigh();
    error NotReleased();
    error BelowMinOut();
    error NotYourPortrait();
    error AgentPortrait();
    error RerollPending();
    error NoRerollPending();
    error UseDeposit();
    error InvalidInk();
    error SetupIncomplete();

    constructor(InkPortraits portraits_, IERC721 seats_, address owner_) Ownable(owner_) {
        portraits = portraits_;
        seats = seats_;
    }

    // ---------------------------------------------------------------- owner

    /// @notice Points the vault at INK once the swarm launch has created it.
    function setInk(IERC20 ink_) external onlyOwner {
        if (address(ink) != address(0)) revert InkAlreadySet();
        if (address(ink_).code.length == 0) revert InvalidInk();
        if (ink_.balanceOf(address(this)) < SEATS * PORTRAIT) revert NotFunded();
        ink = ink_;
        emit InkSet(address(ink_));
    }

    /// @notice One-time setup: the stats list, when the 24-hour window starts, and the liquidity
    /// contract. The vault must already hold the 400,000 INK allocation for every seat.
    function setup(bytes32 root, uint64 start, address liquidity_) external onlyOwner {
        if (address(ink) == address(0)) revert InkNotSet();
        if (statsRoot != bytes32(0)) revert AlreadySetUp();
        if (
            root == bytes32(0) || liquidity_.code.length == 0 || start < block.timestamp
                || start > block.timestamp + MAX_START_DELAY
        ) revert BadSetup();
        if (ink.balanceOf(address(this)) < SEATS * PORTRAIT) revert NotFunded();
        if (IInkLiquidity(liquidity_).ink() != ink || !IInkLiquidity(liquidity_).poolSet()) {
            revert BadSetup();
        }
        statsRoot = root;
        claimStart = start;
        claimEnd = start + CLAIM_WINDOW;
        liquidity = liquidity_;
        emit Setup(root, start, claimEnd, liquidity_);
    }

    function setFees(uint16 baseBps, uint16 agentBps) external onlyOwner {
        if (baseBps > MAX_FEE_BPS || agentBps > baseBps) revert FeeTooHigh();
        rerollFeeBps = baseBps;
        agentRerollFeeBps = agentBps;
        emit FeesSet(baseBps, agentBps);
    }

    function renounceOwnership() public override onlyOwner {
        if (statsRoot == bytes32(0)) revert SetupIncomplete();
        super.renounceOwnership();
    }

    // ---------------------------------------------------------------- agent portraits

    function claimOpen() public view returns (bool) {
        return statsRoot != bytes32(0) && block.timestamp >= claimStart && block.timestamp < claimEnd;
    }

    /// @notice Mints a seat's agent portrait to the seat's current owner, free. The seat's 400,000 INK stays
    /// in the vault as the portrait's backing. Once per seat (the portrait's token id is the seat number).
    function claim(uint256 seat, InkPortraits.AgentStats calldata stats, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (!claimOpen()) revert ClaimClosed();
        if (seats.ownerOf(seat) != msg.sender) revert NotSeatOwner();
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        seat, stats.accepted, stats.rateBps, stats.turns, stats.hoursTenths, stats.outdated
                    )
                )
            )
        );
        if (!MerkleProof.verifyCalldata(proof, statsRoot, leaf)) revert InvalidProof();
        portraits.mintAgent(seat, msg.sender, stats); // reverts if this seat was already claimed
        emit AgentClaimed(seat, msg.sender);
    }

    /// @notice After the window: unclaimed seats become swarm slots and their INK is added to the pool, which
    /// opens the pool for trading. Anyone can call it, once.
    function release() external nonReentrant returns (uint256 inkToPool) {
        if (statsRoot == bytes32(0)) revert InkNotSet();
        if (block.timestamp < claimEnd) revert ClaimStillOpen();
        if (released) revert AlreadyReleased();
        released = true;
        uint256 unclaimed = SEATS - portraits.agentMinted();
        inkToPool = unclaimed * PORTRAIT;
        if (inkToPool > 0) {
            ink.safeTransfer(liquidity, inkToPool);
            IInkLiquidity(liquidity).addLiquidity();
        }
        emit Released(unclaimed, inkToPool);
    }

    // ---------------------------------------------------------------- swarm: pull and reveal

    /// @notice How many swarm portraits can exist: none during the window, then one per unclaimed seat.
    function swarmSlots() public view returns (uint256) {
        if (statsRoot == bytes32(0) || block.timestamp < claimEnd) return 0;
        return SEATS - portraits.agentMinted();
    }

    /// @notice Swarm portraits a pull could land on right now: the vault's inventory plus unminted ones.
    function available() public view returns (uint256) {
        return _inventory.length + swarmSlots() - portraits.swarmMinted();
    }

    /// @notice Locks 400,000 INK per pull and queues that many random portraits. Opens at release, and only
    /// while there are enough portraits (unminted slots, the vault's inventory and ones handed in before this
    /// block that are waiting to join it) for every queued pull.
    /// If nobody records the draw before its hash expires, the pull closes and returns its backing minus
    /// the current reroll fee, fixed here at purchase (including the agent-holder discount).
    function pull(uint256 count) external nonReentrant returns (uint256 firstPullId) {
        if (!released) revert NotReleased();
        if (count == 0) revert ZeroPulls();
        // Every queued pull must have a portrait to land on, so no INK waits on a pull that can't be filled.
        // Portraits handed in this block never join a pull made now, so they don't count for it.
        if (pulls.length - nextReveal + count > available() + waitingBefore()) revert NoneAvailable();
        ink.safeTransferFrom(msg.sender, address(this), count * PORTRAIT);
        firstPullId = pulls.length;
        uint256 expiryFee =
            (PORTRAIT * (portraits.isAgentHolder(msg.sender) ? agentRerollFeeBps : rerollFeeBps)) / 10_000;
        for (uint256 i; i < count; i++) {
            pullExpiryFee[firstPullId + i] = expiryFee;
            pulls.push(Pull({to: msg.sender, blockNumber: uint64(block.number), done: false}));
            emit Pulled(firstPullId + i, msg.sender, uint64(block.number));
        }
    }

    /// @notice Reveals every pull up to and including `pullId`, in order. Anyone can call it; each portrait
    /// goes to its puller (without the ERC-721 receiver check, so a contract puller can't veto its draw).
    /// An expired pull closes with a refund minus its fixed reroll fee, never with a free replacement draw.
    /// Also stops after a bounded admission batch if more eligible deposits remain. Call again to finish;
    /// no draw occurs until all deposits eligible for that pull have joined, preserving its candidate set.
    /// @return done Whether `pullId` itself was revealed (false if expired or still pending).
    function reveal(uint256 pullId) external nonReentrant returns (bool done) {
        if (pullId >= pulls.length) revert UnknownPull();
        if (pullId < nextReveal) revert AlreadyRevealed();
        bool progressed;
        while (nextReveal <= pullId) {
            Step step = _revealNext();
            if (step == Step.TooEarly) {
                if (!progressed) revert TooEarly();
                return false;
            }
            if (step == Step.Admitting) return false;
            progressed = true;
        }
        return !pullExpired[pullId];
    }

    /// @notice Processes up to `max` pulls in order; returns the number of portraits actually revealed.
    /// May admit deposits without revealing a pull; call again while pulls remain pending.
    function revealNext(uint256 max) external nonReentrant returns (uint256 revealed) {
        for (uint256 processed; processed < max && nextReveal < pulls.length; processed++) {
            Step step = _revealNext();
            if (step == Step.TooEarly || step == Step.Admitting) break;
            if (step == Step.Revealed) revealed++;
        }
    }

    function _revealNext() internal returns (Step) {
        uint256 pullId = nextReveal;
        Pull storage p = pulls[pullId];
        if (block.number <= uint256(p.blockNumber) + 1) return Step.TooEarly;

        bytes32 entropy = _pullEntropy[pullId];
        if (entropy == bytes32(0)) {
            entropy = blockhash(uint256(p.blockNumber) + 1);
            if (entropy == bytes32(0)) {
                p.done = true;
                pullExpired[pullId] = true;
                nextReveal = pullId + 1;
                uint256 fee = pullExpiryFee[pullId];
                // Equivalent to returning an unwanted swarm portrait: no free retry, and the next
                // puller can progress without this holder's cooperation or allowance.
                ink.safeTransfer(p.to, PORTRAIT - fee);
                if (fee != 0) ink.safeTransfer(liquidity, fee);
                emit PullExpired(pullId, p.to, PORTRAIT - fee, fee);
                return Step.Expired;
            }
            _pullEntropy[pullId] = entropy;
        }
        // Only hand-ins from before this pull may join its draw, including across admission batches.
        if (!_admit(p.blockNumber)) {
            emit AdmissionProgress(pullId, MAX_ADMISSIONS);
            return Step.Admitting;
        }
        uint256 avail = available();
        // avail is never 0 here: pull() only counts portraits that this cutoff admits, and each reveal takes one.
        if (avail == 0) revert NoneAvailable();
        delete _pullEntropy[pullId];
        p.done = true;
        nextReveal = pullId + 1;
        uint256 r = uint256(keccak256(abi.encode(entropy, pullId)));
        uint256 held = _inventory.length;
        uint256 pick = r % avail;

        if (pick < held) {
            uint256 tokenId = _inventory[pick];
            _inventory[pick] = _inventory[held - 1];
            _inventory.pop();
            portraits.transferFrom(address(this), p.to, tokenId);
            emit Revealed(pullId, p.to, tokenId, false);
        } else {
            uint256 tokenId = portraits.mintSwarm(p.to, keccak256(abi.encode(entropy, pullId, "seed")));
            emit Revealed(pullId, p.to, tokenId, true);
        }
        return Step.Revealed;
    }

    function _admit(uint64 beforeBlock) internal returns (bool complete) {
        uint256 head = _incomingHead;
        uint256 end = _incoming.length;
        uint256 limit = head + MAX_ADMISSIONS;
        while (head < end && head < limit && _incoming[head].blockNumber < beforeBlock) {
            _inventory.push(_incoming[head].tokenId);
            delete _incoming[head];
            head++;
        }
        _incomingHead = head;
        return head == end || _incoming[head].blockNumber >= beforeBlock;
    }

    // ---------------------------------------------------------------- deposits: rerolls and agent portraits

    /// @notice Hands portraits to the vault, where pulls made from the next block on can land them.
    /// - A swarm portrait returns 400,000 INK minus the reroll fee, which goes to the liquidity contract.
    ///   An agent-portrait holder pays the lower fee on portraits the vault handed to it (its own pulls) that
    ///   it has not moved since; one received from anyone else pays the full fee, so the discount can't be
    ///   resold through a contract that parks an agent portrait.
    /// - An agent portrait returns exactly 400,000 INK.
    /// @param minOut Reverts if the INK paid out would be less (fees can change between signing and mining).
    function deposit(uint256[] calldata tokenIds, uint256 minOut)
        external
        nonReentrant
        returns (uint256 inkOut)
    {
        // Read before the transfers: handing in your only agent portrait still counts for the discount.
        bool agentHolder = portraits.isAgentHolder(msg.sender);
        if (_lastDepositBlock == uint64(block.number)) {
            _depositedInBlock += uint192(tokenIds.length);
        } else {
            _lastDepositBlock = uint64(block.number);
            _depositedInBlock = uint192(tokenIds.length);
        }
        uint256 fees;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (traitRerollBlock[tokenId] != 0) revert RerollPending();
            // Read before the transfer, which the vault makes and so would mark the portrait as its own.
            bool discounted = agentHolder && portraits.heldFromVault(tokenId);
            portraits.transferFrom(msg.sender, address(this), tokenId);
            _incoming.push(Incoming({tokenId: tokenId, blockNumber: uint64(block.number)}));

            uint256 fee = portraits.isAgentPortrait(tokenId)
                ? 0
                : (PORTRAIT * (discounted ? agentRerollFeeBps : rerollFeeBps)) / 10_000;
            fees += fee;
            inkOut += PORTRAIT - fee;
            emit Deposited(msg.sender, tokenId, PORTRAIT - fee, fee);
        }
        if (inkOut < minOut) revert BelowMinOut();
        ink.safeTransfer(msg.sender, inkOut);
        if (fees > 0) ink.safeTransfer(liquidity, fees);
    }

    // ---------------------------------------------------------------- trait rerolls

    /// @notice Pays the reroll fee (sent to the liquidity contract) to repaint a swarm portrait you hold with a
    /// new random seed. Agent-portrait holders pay the lower fee on portraits the vault handed to them that
    /// they have not moved since (see deposit()). The seed comes from the hash of the next block, so it can't
    /// be known when the fee is paid; anyone can reveal it with revealTraits(). The portrait can't be
    /// transferred or handed in meanwhile.
    /// @param maxFee Reverts if the fee would be more (fees can change between signing and mining).
    function rerollTraits(uint256 tokenId, uint256 maxFee) external nonReentrant returns (uint256 fee) {
        if (!released) revert NotReleased();
        if (portraits.isAgentPortrait(tokenId)) revert AgentPortrait();
        if (portraits.ownerOf(tokenId) != msg.sender) revert NotYourPortrait();
        if (traitRerollBlock[tokenId] != 0) revert RerollPending();
        fee =
            (PORTRAIT * (portraits.hasRerollDiscount(msg.sender, tokenId) ? agentRerollFeeBps : rerollFeeBps))
                / 10_000;
        if (fee > maxFee) revert FeeTooHigh();
        traitRerollBlock[tokenId] = uint64(block.number);
        ink.safeTransferFrom(msg.sender, liquidity, fee);
        emit TraitRerollRequested(tokenId, msg.sender, fee, uint64(block.number));
    }

    /// @notice Applies a pending trait reroll once its block hash is known. Anyone can call it. If the hash
    /// has expired (older than 256 blocks), close the request and keep the old seed. The fee is spent;
    /// another draw requires another paid reroll. Anyone can clear the transfer lock this way.
    /// @return done Whether the portrait was repainted.
    function revealTraits(uint256 tokenId) external nonReentrant returns (bool done) {
        uint64 b = traitRerollBlock[tokenId];
        if (b == 0) revert NoRerollPending();
        if (block.number <= uint256(b) + 1) revert TooEarly();
        bytes32 entropy = blockhash(uint256(b) + 1);
        delete traitRerollBlock[tokenId];
        if (entropy == bytes32(0)) {
            emit TraitRerollExpired(tokenId);
            return false;
        }
        bytes32 seed = keccak256(abi.encode(entropy, tokenId, "traits"));
        portraits.setSwarmSeed(tokenId, seed);
        emit TraitsRerolled(tokenId, seed);
        return true;
    }

    // ---------------------------------------------------------------- views

    /// @notice Portraits a pull can land on now (excludes ones handed in that haven't joined yet).
    function inventorySize() external view returns (uint256) {
        return _inventory.length;
    }

    /// @notice Every portrait the vault holds: the draw inventory plus ones waiting to join it.
    function heldCount() external view returns (uint256) {
        return _inventory.length + _incoming.length - _incomingHead;
    }

    /// @notice Portraits handed in that join the draw for pulls made after their block.
    function waitingCount() public view returns (uint256) {
        return _incoming.length - _incomingHead;
    }

    /// @notice Portraits handed in before this block that are still waiting to join the draw. A pull made now
    /// can land on them; ones handed in this block only count for pulls made from the next block on.
    function waitingBefore() public view returns (uint256) {
        uint256 waiting = waitingCount();
        return _lastDepositBlock == uint64(block.number) ? waiting - _depositedInBlock : waiting;
    }

    /// @notice The block a pull was made in: only portraits handed in before it join that pull's draw. A
    /// pull's block never changes, even if its hash expires.
    function pullBlock(uint256 pullId) external view returns (uint64) {
        if (pullId >= pulls.length) revert UnknownPull();
        return pulls[pullId].blockNumber;
    }

    function inventoryAt(uint256 index) external view returns (uint256) {
        return _inventory[index];
    }

    function pullCount() external view returns (uint256) {
        return pulls.length;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        // Only deposit() accounts for custody and pays the sender. It uses transferFrom, not safeTransferFrom.
        revert UseDeposit();
    }
}
