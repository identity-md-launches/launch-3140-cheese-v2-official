// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "../CheeseBase.t.sol";
import {CheeseFarm} from "../../src/CheeseFarm.sol";
import {CheeseFarmSIMD} from "../../src/farms/CheeseFarmSIMD.sol";
import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Token changes balances BEFORE returning a chosen response to the Treasury. The farm must roll back
/// those changes on failure, otherwise its deferred liability is backed by tokens already paid out.
contract AdversarialTreasuryToken is ERC20 {
    address public immutable treasury;
    uint8 public mode;

    constructor(address recipient) ERC20("Regression token", "REG") {
        treasury = recipient;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (to != treasury) return result;
        uint256 m = mode;
        assembly ("memory-safe") {
            switch m
            case 1 {
                mstore(0, 0)
                return(0, 32)
            } // false after balance mutation
            case 2 {
                mstore(0, 2)
                return(0, 32)
            } // invalid bool
            case 3 {
                mstore(0, 1)
                return(1, 31)
            } // short return
            case 4 {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            } // trailing words
            case 5 {
                mstore(0, 1)
                revert(0, 32)
            }
            case 6 { for {} // gas exhaustion after mutation
             1 {} {} }
            case 7 { return(0, 0) } // legitimate legacy no-return token
            case 8 { return(0, 0x200000) } // oversized return bomb
            case 9 { revert(0, 0x200000) } // oversized revert bomb
        }
        return result;
    }
}

contract SecurityFixRegressionTest is CheeseBase {
    bytes constant BOMB = hex"6000621fffe0525b5a6200ffff10600757622000006000f3";

    function _outage(uint256 mode) internal {
        if (mode == 0) {
            vm.etch(address(core), hex"fe");
        } else if (mode == 1) {
            vm.etch(address(core), hex"5b600056");
        } else if (mode == 2) {
            vm.etch(address(core), hex"60006000fd");
        } else if (mode == 3) {
            vm.etch(address(core), BOMB);
        } else if (mode == 4) {
            vm.etch(address(core), "");
        } else if (mode == 5) {
            vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), hex"01");
        } else if (mode == 6) {
            bytes memory data = new bytes(256);
            assembly ("memory-safe") { mstore(add(data, 256), 2) } // non-canonical paused bool
            vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), data);
        } else {
            ISqueekCore.CoreState memory regressed;
            vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), abi.encode(regressed));
        }
    }

    function _cold(CheeseFarm farm) internal {
        vm.cool(address(core));
        vm.cool(address(controller));
        vm.cool(address(cheese));
        vm.cool(address(simd));
        vm.cool(address(farm));
        vm.cool(treasury);
    }

    function testFuzz_unpausedColdExitAndClaimDuringEveryCoreFailure(uint8 assetKind, uint8 failure) public {
        uint256 kind = bound(assetKind, 0, 2);
        uint256 fault = bound(failure, 0, 7);
        activateWithHistory(0);
        CheeseFarm farm;
        if (kind == 0) {
            depositEth(alice, 1 ether);
            depositEth(bob, 1 ether);
            farm = ethFarm;
        } else if (kind == 1) {
            depositCheese(alice, 1 ether);
            depositCheese(bob, 1 ether);
            farm = cheeseFarm;
        } else {
            depositSimd(alice, 1 ether);
            depositSimd(bob, 1 ether);
            farm = simdFarm;
        }
        advanceBlocks(10);
        controller.checkpoint();
        uint256 expected = farm.pendingRewards(alice);
        uint64 height = controller.lastHeight();
        uint256 emission = controller.cumulativeEmission();
        _outage(fault);
        uint256 shares = farm.sharesOf(alice);
        _cold(farm);
        vm.prank(alice);
        assertEq(farm.withdraw{gas: 3_000_000}(shares), 0.85 ether, "unpaused exit");
        assertEq(farm.sharesOf(alice), 0);
        _cold(farm);
        vm.prank(alice);
        assertEq(farm.claim{gas: 3_000_000}(alice), expected, "earned rewards survive exit");
        assertEq(controller.lastHeight(), height, "failed read never advances cursor");
        assertEq(controller.cumulativeEmission(), emission, "no invented outage emission");
        assertFalse(controller.emissionsPaused(), "no owner intervention required");
        // The remaining depositor can also exit; the whole residual fee goes to Treasury.
        shares = farm.sharesOf(bob);
        uint256 treasuryBefore =
            kind == 0 ? treasury.balance : (kind == 1 ? cheese.balanceOf(treasury) : simd.balanceOf(treasury));
        uint256 backing = farm.totalAssets();
        _cold(farm);
        vm.prank(bob);
        uint256 paid = farm.withdraw{gas: 3_000_000}(shares);
        uint256 treasuryAfter =
            kind == 0 ? treasury.balance : (kind == 1 ? cheese.balanceOf(treasury) : simd.balanceOf(treasury));
        assertEq(treasuryAfter - treasuryBefore, backing - paid);
        assertEq(farm.totalAssets(), 0);
    }

    function test_outageRecoveryNeverReopensAlreadyClaimedRewardsOrRewardsNewDepositorRetroactively() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        controller.checkpoint();
        uint256 earned = ethFarm.pendingRewards(alice);
        bytes memory goodCore = address(core).code;
        _outage(0);
        vm.prank(bob);
        vm.expectRevert(CheeseFarm.SyncRequired.selector);
        ethFarm.deposit{value: 1 ether}();
        vm.prank(alice);
        assertEq(ethFarm.claim{gas: 3_000_000}(alice), earned);
        vm.prank(alice);
        assertEq(ethFarm.claim{gas: 3_000_000}(alice), 0);
        vm.etch(address(core), goodCore);
        advanceBlocks(10);
        depositEth(bob, 1 ether); // syncs old certified blocks before Bob receives shares
        assertEq(ethFarm.pendingRewards(bob), 0);
        uint256 further = (issued(20) - issued(10)) * 200 / 1000;
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), further);
        assertEq(cheese.balanceOf(alice), earned + further);
    }

    function test_unobservedOutageEmissionCannotBeInheritedAfterFarmEmpties() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        advanceBlocks(10);
        controller.checkpoint();
        uint256 earned = ethFarm.pendingRewards(alice);
        advanceBlocks(10); // certified by the mock, not yet readable by CHEESE
        bytes memory goodCore = address(core).code;
        _outage(0);
        uint256 shares = ethFarm.sharesOf(alice);
        vm.prank(alice);
        ethFarm.withdraw{gas: 3_000_000}(shares);
        vm.prank(alice);
        assertEq(ethFarm.claim{gas: 3_000_000}(alice), earned);
        vm.etch(address(core), goodCore);
        depositEth(bob, 1 ether);
        assertEq(ethFarm.pendingRewards(bob), 0);
        assertEq(controller.forfeitedEmission(), (issued(20) - issued(10)) * 200 / 1000);
    }

    function test_coreOversizedSuccessfulReturnStillRejectedWithoutCopying() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), new bytes(257));
        (bool synced,) = controller.checkpoint();
        assertFalse(synced);
        withdrawAll(ethFarm, alice);
    }

    function testFuzz_invalidTreasuryTransferRollsBackAndDefersExactlyOnce(uint8 response) public {
        uint8 mode = uint8(bound(response, 0, 9));
        AdversarialTreasuryToken asset = new AdversarialTreasuryToken(treasury);
        CheeseFarmSIMD farm = new CheeseFarmSIMD(owner, address(controller));
        vm.startPrank(owner);
        controller.addPool(address(farm), 100);
        farm.setAsset(address(asset));
        vm.stopPrank();
        activateWithHistory(0);
        asset.mint(alice, 100 ether);
        vm.startPrank(alice);
        asset.approve(address(farm), 100 ether);
        farm.deposit(100 ether);
        vm.stopPrank();
        asset.setMode(mode);
        uint256 shares = farm.sharesOf(alice);
        _cold(farm);
        vm.cool(address(asset));
        vm.prank(alice);
        assertEq(farm.withdraw{gas: 3_000_000}(shares), 85 ether);
        assertEq(asset.balanceOf(alice), 85 ether);
        assertEq(farm.totalAssets(), 0);
        if (mode == 0 || mode == 7) {
            assertEq(farm.treasuryOwed(), 0);
            assertEq(asset.balanceOf(treasury), 15 ether);
        } else {
            assertEq(farm.treasuryOwed(), 15 ether);
            assertEq(asset.balanceOf(treasury), 0, "invalid token-side write rolled back");
            assertEq(asset.balanceOf(address(farm)), 15 ether, "deferred fee remains backed");
            assertEq(farm.surplus(), 0, "deferred fee cannot be skimmed");
            asset.setMode(0);
            farm.payTreasury();
            assertEq(farm.treasuryOwed(), 0);
            assertEq(asset.balanceOf(treasury), 15 ether);
        }
        vm.expectRevert(CheeseFarm.NothingOwedToTreasury.selector);
        farm.payTreasury();
        assertEq(asset.balanceOf(address(farm)), 0);
        assertEq(asset.totalSupply(), asset.balanceOf(alice) + asset.balanceOf(treasury));
    }

    function test_treasuryTokenHelperRejectsExternalCallers() public {
        vm.prank(alice);
        vm.expectRevert(CheeseFarm.OnlySelf.selector);
        cheeseFarm.transferTreasuryToken(IERC20(address(cheese)), alice, 1 ether);
    }

    function test_all24FarmAndCoreFailureCombinations() public {
        for (uint8 farm; farm < 3; ++farm) {
            for (uint8 fault; fault < 8; ++fault) {
                uint256 snapshot = vm.snapshotState();
                testFuzz_unpausedColdExitAndClaimDuringEveryCoreFailure(farm, fault);
                vm.clearMockedCalls();
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_all10TreasuryReturnModes() public {
        for (uint8 mode; mode < 10; ++mode) {
            uint256 snapshot = vm.snapshotState();
            testFuzz_invalidTreasuryTransferRollsBackAndDefersExactlyOnce(mode);
            assertTrue(vm.revertToState(snapshot));
        }
    }
}
