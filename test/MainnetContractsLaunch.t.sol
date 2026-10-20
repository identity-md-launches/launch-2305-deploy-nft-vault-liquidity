// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";

/// Rehearses the factory's one-transaction, zero-value, constructor-only launch.
contract MainnetContractsFactoryProbe {
    function deployAll(bytes[] memory codes) external returns (address[] memory apps) {
        apps = new address[](codes.length);
        for (uint256 i; i < codes.length; i++) {
            bytes memory code = codes[i];
            bytes32 salt = bytes32(i);
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0), "constructor failed");
            apps[i] = created;
        }
    }
}

contract MainnetContractsLaunchTest is Test {
    address constant OWNER = 0x824E12b38CfF2D3e7ad9607a0212f7F9Eb6a06E3;
    address constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;
    address constant SEATS = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    MainnetContractsFactoryProbe factory;
    address[] apps;
    InkPortraits portraits;
    InkVault vault;
    InkLiquidity liquidity;
    InkRenderer renderer;

    function _predict(bytes memory code, uint256 salt) internal view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), bytes32(salt), keccak256(code))
                    )
                )
            )
        );
    }

    function setUp() public {
        vm.chainId(1);
        assertEq(PM.code.length, 0);
        assertEq(POSM.code.length, 0);
        assertEq(SEATS.code.length, 0);
        factory = new MainnetContractsFactoryProbe();
        bytes[] memory codes = new bytes[](4);
        codes[0] = abi.encodePacked(vm.getCode("src/InkPortraits.sol:InkPortraits"), abi.encode(OWNER));
        address predictedPortraits = _predict(codes[0], 0);
        codes[1] = abi.encodePacked(
            vm.getCode("src/InkVault.sol:InkVault"), abi.encode(predictedPortraits, SEATS, OWNER)
        );
        codes[2] = abi.encodePacked(
            vm.getCode("src/InkLiquidity.sol:InkLiquidity"), abi.encode(PM, POSM, OWNER, TREASURY)
        );
        codes[3] = abi.encodePacked(
            vm.getCode("src/InkRenderer.sol:InkRenderer"), abi.encode(predictedPortraits, OWNER)
        );
        for (uint256 i; i < 4; i++) {
            assertLe(codes[i].length, 49_152);
        }
        apps = factory.deployAll(codes);
        for (uint256 i; i < 4; i++) {
            assertEq(apps[i], _predict(codes[i], i));
        }
        portraits = InkPortraits(apps[0]);
        vault = InkVault(apps[1]);
        liquidity = InkLiquidity(apps[2]);
        renderer = InkRenderer(apps[3]);
    }

    function test_exactFourContractOrderReferencesAndOwners() public view {
        assertEq(apps.length, 4);
        for (uint256 i; i < 4; i++) {
            assertEq(Ownable(apps[i]).owner(), OWNER);
            assertNotEq(Ownable(apps[i]).owner(), address(factory));
            assertNotEq(Ownable(apps[i]).owner(), TREASURY);
            assertEq(apps[i].balance, 0);
        }
        assertEq(address(vault.portraits()), apps[0]);
        assertEq(address(vault.seats()), SEATS);
        assertEq(address(renderer.portraits()), apps[0]);
        assertEq(address(liquidity.poolManager()), PM);
        assertEq(address(liquidity.positionManager()), POSM);
        assertEq(liquidity.treasury(), TREASURY);
        (address beneficiary, uint256 royalty) = portraits.royaltyInfo(10_000, 100 ether);
        assertEq(beneficiary, OWNER);
        assertEq(royalty, 0);
        assertEq(address(vault.ink()), address(0), "INK belongs to the later hook launch");
        assertFalse(vault.claimOpen());
        assertFalse(liquidity.poolSet());
    }

    function test_runtimeSizeAndOpcodesMeetProtectedFloor() public view {
        for (uint256 i; i < 4; i++) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 pc; pc < code.length; pc++) {
                uint8 op = uint8(code[pc]);
                if (op >= 0x60 && op <= 0x7f) {
                    pc += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }

    function _denied(address caller, address target, bytes memory payload) internal {
        vm.prank(caller);
        (bool ok, bytes memory reason) = target.call(payload);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function test_factoryTreasuryAndOriginHaveNoAdministrativeRights() public {
        address[3] memory callers = [address(factory), TREASURY, tx.origin];
        PoolKey memory key;
        for (uint256 i; i < 3; i++) {
            address caller = callers[i];
            _denied(caller, apps[0], abi.encodeCall(portraits.setVault, (apps[1])));
            _denied(caller, apps[0], abi.encodeCall(portraits.setRenderer, (apps[3])));
            _denied(caller, apps[0], abi.encodeCall(portraits.lockRenderer, ()));
            _denied(caller, apps[0], abi.encodeCall(portraits.setContractURI, ("ipfs://test")));
            _denied(caller, apps[1], abi.encodeCall(vault.setInk, (IERC20(caller))));
            _denied(
                caller,
                apps[1],
                abi.encodeCall(vault.setup, (keccak256("test"), uint64(block.timestamp), apps[2]))
            );
            _denied(caller, apps[1], abi.encodeCall(vault.setFees, (100, 50)));
            _denied(caller, apps[2], abi.encodeCall(liquidity.setPool, (key, IERC20(caller))));
            _denied(caller, apps[2], abi.encodeCall(liquidity.setWidth, (20_000)));
            _denied(caller, apps[2], abi.encodeCall(liquidity.setPremium, (0)));
            _denied(caller, apps[3], abi.encodeCall(renderer.addChunk, (bytes("art"))));
            _denied(caller, apps[3], abi.encodeCall(renderer.setPreviewBase, ("ipfs://test/")));
            _denied(caller, apps[3], abi.encodeCall(renderer.lock, ()));
            for (uint256 j; j < 4; j++) {
                _denied(caller, apps[j], abi.encodeCall(Ownable.transferOwnership, (caller)));
                _denied(caller, apps[j], abi.encodeCall(Ownable.renounceOwnership, ()));
            }
        }
    }
}
