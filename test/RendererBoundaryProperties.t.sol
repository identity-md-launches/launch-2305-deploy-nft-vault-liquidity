// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {InkPortraits} from "src/InkPortraits.sol";
import {InkRenderer} from "src/InkRenderer.sol";

contract RendererBoundaryPropertiesTest is Test {
    InkPortraits internal portraits;
    InkRenderer internal renderer;
    address internal owner = makeAddr("renderer boundary owner");
    address internal outsider = makeAddr("renderer boundary outsider");

    function setUp() public {
        portraits = new InkPortraits(owner);
        renderer = new InkRenderer(portraits, owner);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_binaryChunksRoundTripAndLock(bytes memory a, bytes memory b) public {
        // Foundry generates arbitrary binary inputs, including embedded zero bytes and EVM opcodes.
        // Prefixing makes even empty generated inputs exercise successful chunk creation.
        a = bytes.concat(hex"00", a);
        b = bytes.concat(hex"ff", b);
        // Keep input generation valid without discarding any cases.
        uint256 max = renderer.MAX_CHUNK();
        uint256 aLength = bound(a.length, 1, max);
        uint256 bLength = bound(b.length, 1, max);
        assembly ("memory-safe") {
            mstore(a, aLength)
            mstore(b, bLength)
        }
        vm.startPrank(owner);
        renderer.addChunk(a);
        renderer.addChunk(b);
        renderer.setPreviewBase("ipfs://portrait-previews/");
        renderer.lock();
        vm.expectRevert(InkRenderer.IsLocked.selector);
        renderer.addChunk("replacement");
        vm.expectRevert(InkRenderer.IsLocked.selector);
        renderer.setPreviewBase("ipfs://replacement/");
        vm.stopPrank();
        assertEq(renderer.script(), bytes.concat(a, b), "binary script survives storage and lock");
        assertEq(renderer.chunkCount(), 2);
        assertEq(renderer.previewBase(), "ipfs://portrait-previews/");
        assertEq(renderer.owner(), owner);
        _checkStoredChunk(0, a);
        _checkStoredChunk(1, b);
    }

    function _checkStoredChunk(uint256 index, bytes memory original) internal view {
        bytes memory code = renderer.chunks(index).code;
        assertEq(code, bytes.concat(hex"00", original), "data runtime has a leading STOP");
        assertLe(code.length, 24_576, "data runtime fits EIP-170");
    }

    function test_chunkLimitAndRejectedWritesDoNotDamageUploadedArt() public {
        uint256 max = renderer.MAX_CHUNK();
        bytes memory largest = new bytes(max);
        largest[0] = 0xef;
        largest[max - 1] = 0xff;
        bytes memory tooLarge = new bytes(max + 1);
        vm.startPrank(owner);
        vm.expectRevert(InkRenderer.NoScript.selector);
        renderer.lock();
        vm.expectRevert(InkRenderer.NoScript.selector);
        renderer.addChunk("");
        renderer.addChunk(largest);
        vm.expectRevert(InkRenderer.ChunkTooLarge.selector);
        renderer.addChunk(tooLarge);
        renderer.addChunk(hex"01");
        vm.stopPrank();
        assertEq(renderer.chunkCount(), 2);
        assertEq(renderer.script(), bytes.concat(largest, hex"01"));
        _checkStoredChunk(0, largest);
        _checkStoredChunk(1, hex"01");
    }

    function test_ownershipTransferRevokesOldOwnerAcrossEveryRendererMutation() public {
        bytes memory outsiderDenied =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider);
        address stranger = makeAddr("renderer boundary stranger");

        vm.prank(owner);
        renderer.transferOwnership(outsider);
        // Two-step: nothing moves until the nominee accepts.
        assertEq(renderer.owner(), owner);
        assertEq(renderer.pendingOwner(), outsider);
        vm.startPrank(outsider);
        vm.expectRevert(outsiderDenied);
        renderer.addChunk("premature art");
        vm.expectRevert(outsiderDenied);
        renderer.setPreviewBase("ipfs://premature/");
        vm.expectRevert(outsiderDenied);
        renderer.lock();
        vm.stopPrank();
        // Nobody but the nominee can complete the handover, not even the current owner.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        renderer.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        renderer.acceptOwnership();
        assertEq(renderer.owner(), owner);
        assertEq(renderer.chunkCount(), 0);

        vm.prank(outsider);
        renderer.acceptOwnership();
        assertEq(renderer.owner(), outsider);
        assertEq(renderer.pendingOwner(), address(0));

        vm.startPrank(owner);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner);
        vm.expectRevert(denied);
        renderer.addChunk("injected art");
        vm.expectRevert(denied);
        renderer.setPreviewBase("ipfs://injected/");
        vm.expectRevert(denied);
        renderer.lock();
        vm.expectRevert(denied);
        renderer.transferOwnership(owner);
        vm.expectRevert(denied);
        renderer.renounceOwnership();
        vm.stopPrank();
        vm.startPrank(outsider);
        renderer.addChunk("accepted art");
        renderer.lock();
        vm.stopPrank();
        assertEq(renderer.owner(), outsider);
        assertEq(renderer.script(), bytes("accepted art"));
        // Renderer ownership cannot silently replace the NFT's owner or royalty recipient.
        assertEq(portraits.owner(), owner);
        (address receiver,) = portraits.royaltyInfo(0, 1 ether);
        assertEq(receiver, owner);
    }
}
