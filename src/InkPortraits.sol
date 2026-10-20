// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IInkRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IInkTraitRerolls {
    function traitRerollBlock(uint256 tokenId) external view returns (uint64);
    function liquidity() external view returns (address);
}

interface IInkPortraitBinding {
    function portraits() external view returns (address);
}

interface IInkVaultBinding {
    function seats() external view returns (address);
}

interface IInkRendererBinding {
    function chunkCount() external view returns (uint256);
}

/// @title Ink & Inference portraits
/// @notice A static, one-time drop of at most 2,000 portraits. Only the vault mints.
/// - Agent portraits: token id = seat number (0–1999), painted from that agent's work record.
/// - Swarm portraits: token ids from 10,000, painted from a random seed. Each one fills an unclaimed seat's
///   number: the k-th swarm portrait is numbered after the k-th unclaimed seat (see swarmNumber).
/// - 0% trading fee: ERC-2981 reports a zero royalty, so marketplaces show no creator fee on resales.
contract InkPortraits is ERC721, ERC2981, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 2000;
    uint256 public constant SEAT_COUNT = 2000;
    uint256 public constant SWARM_ID_OFFSET = 10_000;
    uint96 public constant ROYALTY_BPS = 0;

    struct AgentStats {
        uint32 accepted;
        uint16 rateBps;
        uint32 turns;
        uint32 hoursTenths;
        bool outdated;
    }

    address public vault;
    address public renderer;
    bool public rendererLocked;
    /// @notice Collection-level metadata (ERC-7572): name, description, image, banner_image, external_link.
    /// Marketplaces read it for the collection page. Only presentation; the owner can update it any time.
    string public contractURI;

    uint256 public agentMinted;
    uint256 public swarmMinted;

    mapping(uint256 seat => AgentStats) internal _stats;
    /// @dev One bit per seat (8 × 256 ≥ 2,000), set when the seat's agent portrait is claimed.
    uint256[8] internal _claimedSeats;
    mapping(uint256 tokenId => bytes32) public swarmSeed;
    /// @notice How many agent portraits an address holds.
    mapping(address => uint256) public agentBalanceOf;
    /// @notice The block an address last went from holding no agent portrait to holding one.
    mapping(address => uint256) public agentHolderSince;
    /// @notice Whether a swarm portrait's current holder received it from the vault (a pull) and has not
    /// moved it since. The vault's agent-holder reroll discount applies only to such portraits, so a
    /// contract that parks one agent portrait can't resell the discount on portraits handed to it.
    mapping(uint256 tokenId => bool) public heldFromVault;

    event VaultSet(address vault);
    event RendererSet(address renderer);
    event RendererLocked();
    event ContractURIUpdated();
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event MetadataUpdate(uint256 _tokenId);

    error NotASwarmPortrait();
    error OnlyVault();
    error VaultAlreadySet();
    error SoldOut();
    error NotASeat();
    error Locked();
    error NoRenderer();
    error SwarmStarted();
    error RerollPending();
    error InvalidBinding();
    error UseDeposit();
    error SetupIncomplete();
    error InvalidRecipient();

    constructor(address owner_) ERC721("Ink & Inference", "INKINF") Ownable(owner_) {
        _setDefaultRoyalty(owner_, ROYALTY_BPS);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // ---------------------------------------------------------------- owner

    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        _checkBinding(vault_);
        // The renderer also exposes portraits(); distinguish the two application types.
        if (IInkVaultBinding(vault_).seats() == address(0)) revert InvalidBinding();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function setRenderer(address renderer_) external onlyOwner {
        if (rendererLocked) revert Locked();
        _checkBinding(renderer_);
        // Reject a vault mistakenly supplied as the renderer, even though its collection matches.
        IInkRendererBinding(renderer_).chunkCount();
        renderer = renderer_;
        emit RendererSet(renderer_);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Freezes the renderer forever.
    function lockRenderer() external onlyOwner {
        if (renderer == address(0)) revert NoRenderer(); // locking with no renderer would break tokenURI for good
        rendererLocked = true;
        emit RendererLocked();
    }

    /// @notice Sets the collection-level metadata (ERC-7572), e.g. an ipfs:// JSON with the banner image.
    /// Marketplaces such as OpenSea also let whoever owner() returns edit the collection page directly.
    function setContractURI(string calldata uri) external onlyOwner {
        contractURI = uri;
        emit ContractURIUpdated();
    }

    function _checkBinding(address target) internal view {
        if (target.code.length == 0 || IInkPortraitBinding(target).portraits() != address(this)) {
            revert InvalidBinding();
        }
    }

    function renounceOwnership() public override onlyOwner {
        if (vault == address(0) || renderer == address(0)) revert SetupIncomplete();
        super.renounceOwnership();
    }

    // ---------------------------------------------------------------- minting (vault only)

    function mintAgent(uint256 seat, address to, AgentStats calldata stats) external onlyVault {
        if (seat >= SEAT_COUNT) revert NotASeat();
        if (agentMinted + swarmMinted >= MAX_SUPPLY) revert SoldOut();
        // Swarm numbers fill the unclaimed seats, so they'd shift if a seat were claimed after the first
        // swarm portrait. The vault never does that (pulls start after the claim window), and this makes sure.
        if (swarmMinted != 0) revert SwarmStarted();
        _claimedSeats[seat >> 8] |= 1 << (seat & 255);
        _stats[seat] = stats;
        agentMinted++;
        // No receiver check, so a seat held by a contract wallet can still claim. Reverts if this seat's
        // portrait already exists.
        _mint(to, seat);
    }

    function mintSwarm(address to, bytes32 seed) external onlyVault returns (uint256 tokenId) {
        if (agentMinted + swarmMinted >= MAX_SUPPLY) revert SoldOut();
        tokenId = SWARM_ID_OFFSET + swarmMinted;
        swarmMinted++;
        swarmSeed[tokenId] = seed;
        _mint(to, tokenId); // no receiver check: reveals are run by anyone and must not be blockable
    }

    /// @notice A trait reroll: the vault gives an existing swarm portrait a new seed, which repaints it.
    function setSwarmSeed(uint256 tokenId, bytes32 seed) external onlyVault {
        if (isAgentPortrait(tokenId)) revert NotASwarmPortrait();
        _requireOwned(tokenId);
        swarmSeed[tokenId] = seed;
        emit MetadataUpdate(tokenId);
    }

    // ---------------------------------------------------------------- views

    function isAgentPortrait(uint256 tokenId) public pure returns (bool) {
        return tokenId < SWARM_ID_OFFSET;
    }

    /// @notice Whether `holder` gets agent-holder perks (no hook fee, half-price rerolls): it holds an agent
    /// portrait and has since an earlier block, so a portrait lent for one transaction doesn't count.
    function isAgentHolder(address holder) public view returns (bool) {
        return agentBalanceOf[holder] > 0 && agentHolderSince[holder] < block.number;
    }

    /// @notice Whether `holder` pays the agent-holder reroll fee on swarm portrait `tokenId`: it is an agent
    /// holder and the portrait came to it straight from the vault. A portrait received from anyone else
    /// (a sale, or a hand-in through a contract that holds an agent portrait) pays the full fee.
    function hasRerollDiscount(address holder, uint256 tokenId) external view returns (bool) {
        return heldFromVault[tokenId] && _ownerOf(tokenId) == holder && isAgentHolder(holder);
    }

    /// @notice The number a swarm portrait goes by: the seat number it fills. Swarm portrait k (token id
    /// 10,000 + k) takes the k-th unclaimed seat in ascending order, so the collection's numbers run
    /// 0000–1999 once, agent and swarm together.
    function swarmNumber(uint256 tokenId) external view returns (uint256) {
        if (isAgentPortrait(tokenId)) revert NotASwarmPortrait();
        _requireOwned(tokenId);
        uint256 k = tokenId - SWARM_ID_OFFSET;
        for (uint256 w; w < 8; w++) {
            uint256 bits = w == 7 ? SEAT_COUNT - 7 * 256 : 256;
            uint256 open = ~_claimedSeats[w];
            if (bits < 256) open &= (1 << bits) - 1;
            uint256 free = _popcount(open);
            if (k >= free) {
                k -= free;
                continue;
            }
            for (uint256 b;; b++) {
                if (open & (1 << b) != 0) {
                    if (k == 0) return w * 256 + b;
                    k--;
                }
            }
        }
        revert SoldOut(); // unreachable: MAX_SUPPLY keeps swarm portraits ≤ unclaimed seats
    }

    function _popcount(uint256 x) internal pure returns (uint256 n) {
        while (x != 0) {
            x &= x - 1;
            n++;
        }
    }

    function agentStats(uint256 seat) external view returns (AgentStats memory) {
        return _stats[seat];
    }

    function totalSupply() external view returns (uint256) {
        return agentMinted + swarmMinted;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return IInkRenderer(renderer).tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        // Only deposit() accounts for custody and releases backing to the holder.
        if (to == vault && msg.sender != vault) revert UseDeposit();
        if (to != address(0) && vault != address(0) && to == IInkTraitRerolls(vault).liquidity()) {
            revert InvalidRecipient();
        }
        // A buyer must receive the traits offered for sale. Only the holder can request a reroll and
        // anyone can finish it; there is no owner-controlled transfer lock. Mints skip the reroll check.
        if (
            _ownerOf(tokenId) != address(0) && !isAgentPortrait(tokenId)
                && IInkTraitRerolls(vault).traitRerollBlock(tokenId) != 0
        ) revert RerollPending();
        from = super._update(to, tokenId, auth);
        if (isAgentPortrait(tokenId)) {
            if (from != address(0)) agentBalanceOf[from]--;
            if (to != address(0) && agentBalanceOf[to]++ == 0) agentHolderSince[to] = block.number;
        } else {
            // Only the vault's own hand-outs (mintSwarm, a revealed inventory portrait) keep the discount.
            heldFromVault[tokenId] = msg.sender == vault;
        }
    }
}
