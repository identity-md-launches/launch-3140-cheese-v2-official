// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {CheeseToken} from "../../src/CheeseToken.sol";
import {CheeseEmissionController} from "../../src/CheeseEmissionController.sol";
import {CheeseFarm} from "../../src/CheeseFarm.sol";
import {CheeseFarmERC20} from "../../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "../../src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "../../src/farms/CheeseFarmSIMD.sol";

/// @dev Local factory rehearsal only. Not a launch target and never broadcast.
contract OfficialLaunchFactoryProbe {
    function deployAll(address owner, address core) external returns (address[5] memory deployed) {
        deployed[0] =
            _create(abi.encodePacked(type(CheeseEmissionController).creationCode, abi.encode(owner, core, owner)));
        deployed[1] =
            _create(abi.encodePacked(type(CheeseToken).creationCode, abi.encode(owner, owner, owner, deployed[0])));
        deployed[2] =
            _create(abi.encodePacked(type(CheeseFarmERC20).creationCode, abi.encode(owner, deployed[0], deployed[1])));
        deployed[3] = _create(abi.encodePacked(type(CheeseFarmETH).creationCode, abi.encode(owner, deployed[0])));
        deployed[4] = _create(abi.encodePacked(type(CheeseFarmSIMD).creationCode, abi.encode(owner, deployed[0])));
    }

    function _create(bytes memory init) private returns (address deployed) {
        require(init.length <= 49_152, "init code limit");
        assembly ("memory-safe") {
            deployed := create2(0, add(init, 32), mload(init), 0)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract OfficialLaunchTest is Test {
    address internal constant OWNER = 0xDEA11b3A70b77134424d436f6eb455f1Abbd4449;
    address internal constant CORE = 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4;
    uint256 internal constant SEPOLIA = 11_155_111;
    OfficialLaunchFactoryProbe internal factory;
    CheeseEmissionController internal controller;
    CheeseToken internal cheese;
    CheeseFarmERC20 internal cheeseFarm;
    CheeseFarmETH internal ethFarm;
    CheeseFarmSIMD internal simdFarm;
    address[5] internal deployed;
    Vm.Log[] internal constructorLogs;

    function setUp() public {
        vm.chainId(SEPOLIA);
        assertEq(CORE.code.length, 0, "rehearsal must have no Core code");
        factory = new OfficialLaunchFactoryProbe();
        vm.recordLogs();
        deployed = factory.deployAll(OWNER, CORE);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            constructorLogs.push(entries[i]);
        }
        controller = CheeseEmissionController(deployed[0]);
        cheese = CheeseToken(deployed[1]);
        cheeseFarm = CheeseFarmERC20(deployed[2]);
        ethFarm = CheeseFarmETH(payable(deployed[3]));
        simdFarm = CheeseFarmSIMD(deployed[4]);
    }

    function test_exactFiveCreationHashes() public pure {
        assertEq(
            keccak256(type(CheeseEmissionController).creationCode),
            0x9f1969497a5ee0b481d2bafe6114644818cb31bc213f62b96b7d8406a699d2ac
        );
        assertEq(
            keccak256(type(CheeseToken).creationCode),
            0x4d2fed1db5ad0e3a46c3e2b6a9ca9e73bc872491527fd6d71ca55e6e2385610b
        );
        assertEq(
            keccak256(type(CheeseFarmERC20).creationCode),
            0xf919ccbb9116ac6a1fa7900462c74616f08f9c28bdcf444e0e65ed6d935a8b3e
        );
        assertEq(
            keccak256(type(CheeseFarmETH).creationCode),
            0x4206d17ed1f0752b1f02c7566b4190a218aa33367c044f66adf3f0506ed2041b
        );
        assertEq(
            keccak256(type(CheeseFarmSIMD).creationCode),
            0x78273e05179b53c1fb080214379375b3bd4593e45962429949747ac602141f56
        );
    }

    function test_factoryCannotAcquireOwnerGuardianOrPremint() public view {
        assertEq(controller.owner(), OWNER);
        assertEq(controller.guardian(), OWNER);
        assertEq(controller.treasury(), OWNER);
        assertEq(cheeseFarm.owner(), OWNER);
        assertEq(ethFarm.owner(), OWNER);
        assertEq(simdFarm.owner(), OWNER);
        assertEq(controller.pendingOwner(), address(0));
        assertEq(cheeseFarm.pendingOwner(), address(0));
        assertEq(ethFarm.pendingOwner(), address(0));
        assertEq(simdFarm.pendingOwner(), address(0));
        assertEq(cheese.balanceOf(address(factory)), 0);
        assertEq(cheese.balanceOf(OWNER), 210_000_000e18);
        for (uint256 i; i < deployed.length; ++i) {
            assertEq(deployed[i].balance, 0);
        }
    }

    function test_premintEventsAndLifetimeAccounting() public view {
        assertEq(cheese.name(), "CHEESE");
        assertEq(cheese.symbol(), "CHEESE");
        assertEq(cheese.decimals(), 18);
        assertEq(cheese.MAX_SUPPLY(), 2_100_000_000e18);
        assertEq(cheese.MINING_ALLOWANCE(), 1_890_000_000e18);
        assertEq(cheese.totalMinted(), 210_000_000e18);
        assertEq(cheese.totalSupply(), cheese.totalMinted());
        assertEq(cheese.totalBurned(), 0);
        uint256[3] memory amounts = [uint256(63_000_000e18), 63_000_000e18, 84_000_000e18];
        uint256 count;
        for (uint256 i; i < constructorLogs.length; ++i) {
            Vm.Log storage entry = constructorLogs[i];
            if (entry.emitter != address(cheese) || entry.topics[0] != keccak256("Transfer(address,address,uint256)")) {
                continue;
            }
            assertEq(entry.topics.length, 3);
            assertEq(entry.topics[1], bytes32(0));
            assertEq(entry.topics[2], _word(OWNER));
            assertLt(count, 3);
            assertEq(abi.decode(entry.data, (uint256)), amounts[count++]);
        }
        assertEq(count, 3);
    }

    function test_noAutomaticSetupOrActivation() public {
        assertEq(controller.token(), address(0));
        assertEq(controller.poolCount(), 0);
        _allocation(0, 0, 1000);
        assertFalse(controller.activated());
        assertEq(controller.totalMinted(), 0);
        assertFalse(cheeseFarm.registered());
        assertFalse(ethFarm.registered());
        assertFalse(simdFarm.registered());
        assertEq(address(simdFarm.asset()), address(0)); // Unconfigured state, not a substitute asset.
        vm.prank(OWNER);
        vm.expectRevert(CheeseEmissionController.TokenNotBound.selector);
        controller.activate();
        vm.expectRevert(CheeseFarm.AssetNotConfigured.selector);
        simdFarm.deposit(1);
    }

    function test_onlyRequesterCanPerformPendingSetup() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(factory)));
        controller.bindToken(address(cheese));
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(factory)));
        simdFarm.setAsset(address(cheese));
        vm.startPrank(OWNER);
        controller.bindToken(address(cheese));
        assertEq(controller.addPool(address(cheeseFarm), 400), 0);
        assertEq(controller.addPool(address(ethFarm), 200), 1);
        assertEq(controller.addPool(address(simdFarm), 200), 2);
        vm.stopPrank();
        _allocation(800, 0, 200);
        assertEq(controller.poolCount(), 3);
        assertFalse(controller.activated());
        assertEq(controller.totalMinted(), 0);
        assertEq(address(simdFarm.asset()), address(0));
        assertEq(cheese.balanceOf(OWNER), 210_000_000e18);
        vm.prank(OWNER);
        vm.expectRevert(CheeseEmissionController.SqueekCoreUnavailable.selector);
        controller.activate();
        assertFalse(controller.activated());
    }

    function test_unregisteredCheeseAndEthDepositsDoNotRevertOrEarnRewards() public {
        // Corrects the imported audit's blanket claim that all unwired deposits revert.
        vm.deal(OWNER, 1 ether);
        vm.startPrank(OWNER);
        cheese.approve(address(cheeseFarm), 100 ether);
        cheeseFarm.deposit(100 ether);
        ethFarm.deposit{value: 1 ether}();
        vm.stopPrank();
        assertEq(cheeseFarm.totalAssets(), 100 ether);
        assertEq(ethFarm.totalAssets(), 1 ether);
        assertEq(cheeseFarm.pendingRewards(OWNER), 0);
        assertEq(ethFarm.pendingRewards(OWNER), 0);
        assertFalse(controller.activated());
        assertEq(controller.totalMinted(), 0);
    }

    function test_allRuntimeBytesAndImmutableValues() public view {
        bytes memory code = address(controller).code;
        _clear(code, 1885, _word(CORE));
        _clear(code, 10855, _word(CORE));
        assertEq(keccak256(code), 0x61698399b86962b1a2a1d23eaee6067f33b2267937153ccabae2985f8407fdbd);

        code = address(cheeseFarm).code;
        uint256[11] memory erc20Controller = [uint256(1038), 1326, 1971, 2842, 3419, 3649, 3837, 4456, 5122, 5635, 6198];
        uint256[8] memory erc20Asset = [uint256(906), 5045, 6335, 6404, 6637, 6832, 6952, 7015];
        for (uint256 i; i < erc20Controller.length; ++i) {
            _clear(code, erc20Controller[i], _word(address(controller)));
        }
        for (uint256 i; i < erc20Asset.length; ++i) {
            _clear(code, erc20Asset[i], _word(address(cheese)));
        }
        assertEq(keccak256(code), 0x34d5392d4849494165c6cfcffadc033d151ab89905f8c82a194a098fd0e5b2f2);

        code = address(ethFarm).code;
        uint256[10] memory ethController = [uint256(1261), 1762, 2407, 3278, 3855, 4085, 4273, 4853, 5580, 6129];
        for (uint256 i; i < ethController.length; ++i) {
            _clear(code, ethController[i], _word(address(controller)));
        }
        assertEq(keccak256(code), 0x08cf75d04037b58574dd3818c570bdd2cc0ba028eaadee276dbbf14261593f4f);

        code = address(simdFarm).code;
        uint256[11] memory simdController = [uint256(1029), 1336, 1981, 2852, 3429, 3659, 3847, 4670, 5351, 5908, 6471];
        for (uint256 i; i < simdController.length; ++i) {
            _clear(code, simdController[i], _word(address(controller)));
        }
        assertEq(keccak256(code), 0x747468b5b5cc6f650fce50a229b1c3e290a819837711d8338fad27308e1b7ec4);
        _tokenRuntime();
    }

    function _tokenRuntime() internal view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CHEESE"),
                keccak256("1"),
                SEPOLIA,
                address(cheese)
            )
        );
        assertEq(cheese.DOMAIN_SEPARATOR(), domain);
        bytes memory code = address(cheese).code;
        _clear(code, 759, _word(address(controller)));
        _clear(code, 1228, _word(address(controller)));
        _clear(code, 2178, domain);
        _clear(code, 2136, bytes32(SEPOLIA));
        _clear(code, 2094, _word(address(cheese)));
        _clear(code, 2259, keccak256("CHEESE"));
        _clear(code, 2299, keccak256("1"));
        _clear(code, 2442, bytes32("CHEESE") | bytes32(uint256(6)));
        _clear(code, 2487, bytes32("1") | bytes32(uint256(1)));
        assertEq(keccak256(code), 0x3cf513d6cab26433bc5153e2e869d299968f74c5458eac006f2233ef5d40afd3);
    }

    function test_runtimeLimitsAndForbiddenOpcodes() public view {
        for (uint256 i; i < deployed.length; ++i) {
            bytes memory code = deployed[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            bool reachable = true;
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
                if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
            }
        }
    }

    function _clear(bytes memory code, uint256 offset, bytes32 expected) internal pure {
        assertLe(offset + 32, code.length);
        bytes32 actual;
        assembly ("memory-safe") { actual := mload(add(add(code, 32), offset)) }
        assertEq(actual, expected, "immutable binding");
        assembly ("memory-safe") { mstore(add(add(code, 32), offset), 0) }
    }

    function _word(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function _allocation(uint16 active, uint16 inactive, uint16 reserve) internal view {
        (uint16 a, uint16 i, uint16 r) = controller.getAllocation();
        assertEq(a, active);
        assertEq(i, inactive);
        assertEq(r, reserve);
    }
}
