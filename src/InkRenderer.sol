// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {InkPortraits, IInkRenderer, IInkTraitRerolls} from "./InkPortraits.sol";

/// @title Ink & Inference renderer
/// @notice Stores the owner's art script on-chain and builds every token's metadata:
/// - traits computed on-chain with the same rules as the script's deriveTraits() (FNV-1a seeds,
///   mulberry32 rolls, the scene and label thresholds), so marketplaces show them without any server;
/// - an animation_url holding a self-contained HTML page that runs the script with the token's inputs;
/// - an image URL from previewBase, for marketplaces that need a still (set before locking).
/// The script is uploaded in chunks, each stored as the code of a small data contract, then locked forever.
contract InkRenderer is IInkRenderer, Ownable2Step {
    using Strings for uint256;

    uint256 public constant MAX_CHUNK = 24_575;
    string[6] internal PALETTES = ["Ember", "Rosewater", "Peach Dusk", "Lagoon", "Ochre Ink", "Signal"];

    InkPortraits public immutable portraits;
    address[] public chunks;
    bool public locked;
    /// @notice Still previews: image = previewBase + tokenId + ".png". Empty means no image field.
    string public previewBase;

    struct Labels {
        string scene;
        string palette;
        string glitch;
        string density;
        string depth;
        string paper;
    }

    event ChunkAdded(uint256 index, address pointer, uint256 size);
    event PreviewBaseSet(string previewBase);
    event Locked();

    error IsLocked();
    error ChunkTooLarge();
    error WriteFailed();
    error NoScript();

    constructor(InkPortraits portraits_, address owner_) Ownable(owner_) {
        portraits = portraits_;
    }

    // ---------------------------------------------------------------- owner, until locked

    function addChunk(bytes calldata data) external onlyOwner {
        if (locked) revert IsLocked();
        if (data.length == 0) revert NoScript();
        if (data.length > MAX_CHUNK) revert ChunkTooLarge();
        // Runtime code = 0x00 (STOP, so the data can never run) + data.
        bytes memory init = abi.encodePacked(hex"600B5981380380925939F3", hex"00", data);
        address pointer;
        assembly {
            pointer := create(0, add(init, 0x20), mload(init))
        }
        if (pointer == address(0)) revert WriteFailed();
        chunks.push(pointer);
        emit ChunkAdded(chunks.length - 1, pointer, data.length);
    }

    function setPreviewBase(string calldata base) external onlyOwner {
        if (locked) revert IsLocked();
        previewBase = base;
        emit PreviewBaseSet(base);
    }

    /// @notice Freezes the script and preview base forever.
    function lock() external onlyOwner {
        if (chunks.length == 0) revert NoScript(); // locking with no art would break every token for good
        locked = true;
        emit Locked();
    }

    function renounceOwnership() public override onlyOwner {
        if (chunks.length == 0) revert NoScript();
        super.renounceOwnership();
    }

    // ---------------------------------------------------------------- reading

    function chunkCount() external view returns (uint256) {
        return chunks.length;
    }

    /// @notice The full art script, joined from its chunks.
    function script() public view returns (bytes memory out) {
        for (uint256 i; i < chunks.length; i++) {
            address p = chunks[i];
            uint256 size = p.code.length - 1;
            bytes memory part = new bytes(size);
            assembly {
                extcodecopy(p, add(part, 0x20), 1, size)
            }
            out = bytes.concat(out, part);
        }
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(tokenJSON(tokenId))));
    }

    /// @notice The metadata JSON that tokenURI() wraps: name ("Agent Portrait #0280", or "Swarm Portrait #0003"
    /// for a swarm portrait filling unclaimed seat 3),
    /// portrait_type ("agent" or "swarm", also the Type trait), description, image, animation_url, attributes.
    function tokenJSON(uint256 tokenId) public view returns (string memory) {
        bool agent = portraits.isAgentPortrait(tokenId);
        string memory params;
        string memory name;
        Labels memory l;
        string memory extra;
        if (agent) {
            InkPortraits.AgentStats memory s = portraits.agentStats(tokenId);
            l = agentLabels(tokenId, s);
            name = string.concat("Agent Portrait #", _padded(tokenId));
            params = string.concat(
                '{"mode":"agent","seat":',
                tokenId.toString(),
                ',"accepted":',
                uint256(s.accepted).toString(),
                ',"rate":',
                _decimal(s.rateBps, 2),
                ',"turns":',
                uint256(s.turns).toString(),
                ',"hours":',
                _decimal(s.hoursTenths, 1),
                ',"outdated":',
                s.outdated ? "true" : "false",
                "}"
            );
            extra = string.concat(
                ',{"trait_type":"Seat","value":"#',
                tokenId.toString(),
                '"},{"trait_type":"Accepted","display_type":"number","value":',
                uint256(s.accepted).toString(),
                '},{"trait_type":"Acceptance","value":"',
                ((uint256(s.rateBps) + 50) / 100).toString(),
                '%"},{"trait_type":"Turns","display_type":"number","value":',
                uint256(s.turns).toString(),
                '},{"trait_type":"Hours","value":"',
                _decimal(s.hoursTenths, 1),
                '"}'
            );
        } else {
            string memory seed = Strings.toHexString(uint256(portraits.swarmSeed(tokenId)), 32);
            l = swarmLabels(seed);
            name = string.concat("Swarm Portrait #", _padded(portraits.swarmNumber(tokenId)));
            params = string.concat('{"mode":"swarm","seed":"', seed, '"}');
        }

        string memory attrs = string.concat(
            '[{"trait_type":"Type","value":"',
            agent ? "Agent Portrait" : "Swarm Portrait",
            '"},{"trait_type":"Scene","value":"',
            l.scene,
            '"},{"trait_type":"Palette","value":"',
            l.palette,
            '"},{"trait_type":"Glitch","value":"',
            l.glitch,
            '"},{"trait_type":"Density","value":"',
            l.density,
            '"},{"trait_type":"Depth","value":"',
            l.depth,
            '"},{"trait_type":"Paper","value":"',
            l.paper,
            '"}',
            extra,
            "]"
        );
        string memory html = string.concat(
            "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<style>html,body{margin:0;height:100%;background:#f5f3ee}canvas{display:block;margin:auto;max-width:100%;max-height:100vh;object-fit:contain}</style>"
            "</head><body><canvas id=c></canvas><script>",
            string(script()),
            "</script><script>SwarmArt.render(document.getElementById('c'),",
            params,
            ",{scale:4});</script></body></html>"
        );
        string memory image = bytes(previewBase).length == 0
            ? ""
            : string.concat('"image":"', previewBase, tokenId.toString(), '.png",');
        return string.concat(
            '{"name":"',
            name,
            '","description":"',
            agent
                ? string.concat("Agent portrait of identity.md seat #", tokenId.toString(), ". ")
                : string.concat(
                    "Swarm portrait filling unclaimed seat #",
                    portraits.swarmNumber(tokenId).toString(),
                    ", pulled from the pool. "
                ),
            'The swarm, painted by its own work. Drawn live in your browser from code stored on Ethereum.",',
            '"portrait_type":"',
            agent ? "agent" : "swarm",
            '",',
            '"traitRerollBlock":',
            agent ? "0" : uint256(IInkTraitRerolls(portraits.vault()).traitRerollBlock(tokenId)).toString(),
            ",",
            image,
            '"animation_url":"data:text/html;base64,',
            Base64.encode(bytes(html)),
            '","attributes":',
            attrs,
            "}"
        );
    }

    // ---------------------------------------------------------------- traits, mirroring deriveTraits()

    /// @notice Labels for an agent portrait. Thresholds are the script's, solved for whole numbers:
    /// Sketch below 25 accepted, Vortex from 2,500, Corridor from 15 hours; glitch 0.16 + (1 − rate) × 6
    /// is Clean from 97.67% and Weathered from 92.67%; density log10(turns+1)/log10(30000) is Sparse up to
    /// 60 turns and Dense up to 2,278; depth hours/60 is Shallow under 18 hours and Deep under 39.
    function agentLabels(uint256 seat, InkPortraits.AgentStats memory s)
        public
        view
        returns (Labels memory l)
    {
        bool sketch = s.accepted < 25;
        l.scene = sketch
            ? "Sketch"
            : s.accepted >= 2500 ? "Vortex" : s.hoursTenths >= 150 ? "Corridor" : "Glitch City";
        l.palette = PALETTES[_fnv(abi.encodePacked("seat:", seat.toString(), ":palette")) % 6];
        l.glitch =
            sketch ? "Clean" : s.rateBps >= 9767 ? "Clean" : s.rateBps >= 9267 ? "Weathered" : "Fractured";
        l.density = s.turns <= 60 ? "Sparse" : s.turns <= 2278 ? "Dense" : "Teeming";
        l.depth = s.hoursTenths < 180 ? "Shallow" : s.hoursTenths < 390 ? "Deep" : "Abyssal";
        l.paper = s.outdated ? "Weathered" : "Fresh";
    }

    /// @notice Labels for a pool portrait from its seed string (the bytes32 seed as lowercase 0x hex). The
    /// script draws, in order: texture, scene, structure, density, depth, glitch.
    function swarmLabels(string memory seed) public view returns (Labels memory l) {
        bytes memory seedStr = abi.encodePacked("swarm:", seed);
        uint32 a = _fnv(seedStr);
        uint32 u;
        (a, u) = _mulberry(a); // texture
        (a, u) = _mulberry(a); // scene
        uint256 x = uint256(u);
        l.scene = x * 100 < 45 << 32
            ? "Glitch City"
            : x * 100 < 75 << 32
                ? "Corridor"
                : x * 100 < 90 << 32 ? "Vortex" : x * 100 < 97 << 32 ? "Sketch" : "Line Study";
        (a, u) = _mulberry(a); // structure
        (a, u) = _mulberry(a); // density = 0.4 + r × 0.6
        x = uint256(u);
        l.density = x * 12 < 7 << 32 ? "Dense" : "Teeming";
        (a, u) = _mulberry(a); // depth = r
        x = uint256(u);
        l.depth = x * 10 < 3 << 32 ? "Shallow" : x * 20 < 13 << 32 ? "Deep" : "Abyssal";
        (a, u) = _mulberry(a); // glitch = 0.2 + r × 0.5
        x = uint256(u);
        bool sketch = keccak256(bytes(l.scene)) == keccak256("Sketch")
            || keccak256(bytes(l.scene)) == keccak256("Line Study");
        l.glitch = sketch || x * 5 < 1 << 32 ? "Clean" : x * 5 < 4 << 32 ? "Weathered" : "Fractured";
        l.palette = PALETTES[_fnv(abi.encodePacked(seedStr, ":palette")) % 6];
        l.paper = "Fresh";
    }

    /// @dev FNV-1a, 32-bit, as hashStr() in the script.
    function _fnv(bytes memory s) internal pure returns (uint32 h) {
        h = 2166136261;
        unchecked {
            for (uint256 i; i < s.length; i++) {
                h ^= uint32(uint8(s[i]));
                h *= 16777619;
            }
        }
    }

    /// @dev mulberry32, as rng() in the script. Returns the new state and the 32-bit output (÷ 2^32 = r).
    function _mulberry(uint32 a) internal pure returns (uint32, uint32) {
        unchecked {
            a += 0x6D2B79F5;
            uint32 t = (a ^ (a >> 15)) * (1 | a);
            t = (t + ((t ^ (t >> 7)) * (61 | t))) ^ t;
            return (a, t ^ (t >> 14));
        }
    }

    /// @dev At least four digits, zero-padded: 7 → "0007", 280 → "0280", 12345 → "12345".
    function _padded(uint256 n) internal pure returns (string memory s) {
        s = n.toString();
        while (bytes(s).length < 4) s = string.concat("0", s);
    }

    /// @dev value / 10^places as a JavaScript number would print it ("46.7", "46", "98.59").
    function _decimal(uint256 value, uint256 places) internal pure returns (string memory) {
        uint256 unit = 10 ** places;
        uint256 whole = value / unit;
        uint256 frac = value % unit;
        if (frac == 0) return whole.toString();
        bytes memory f = bytes(frac.toString());
        while (f.length < places) f = bytes.concat("0", f);
        uint256 len = f.length;
        while (len > 0 && f[len - 1] == "0") len--;
        bytes memory trimmed = new bytes(len);
        for (uint256 i; i < len; i++) {
            trimmed[i] = f[i];
        }
        return string.concat(whole.toString(), ".", string(trimmed));
    }
}
