// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev Minimal SqueekCore double: settle() certifies rounds and completes blocks.
contract CoreStub is ISqueekCore {
    uint64 public genesis;
    uint64 public settledThroughRound;
    uint96 public units;
    mapping(uint64 => uint96) public unitsAfter;

    constructor(uint64 g) {
        genesis = g;
    }

    function settle(uint64 round, uint64 blocks) external {
        units += uint96(blocks) * 1_000_000_000;
        for (uint64 r = settledThroughRound + 1; r <= round; ++r) unitsAfter[r] = units;
        settledThroughRound = round;
    }

    function state() external view returns (CoreState memory r) {
        r.settledThroughRound = settledThroughRound;
        r.cumulativeBlockUnits = units;
        r.blockHeight = uint64(units / 1_000_000_000);
    }

    function configuration() external view returns (CoreConfiguration memory r) {
        r.genesisTimestamp = genesis;
        r.roundDuration = 600;
        r.blockUnitsPerBlock = 1_000_000_000;
    }

    function roundPage(uint64 a, uint64 b, uint256) external view returns (RoundPage memory r) {
        r.certifiedThroughRound = b;
        r.start.cumulativeBlockUnits = unitsAfter[a];
        r.end.cumulativeBlockUnits = unitsAfter[b];
    }

    function blockInfo(uint64) external pure returns (BlockInfo memory r) {}

    function paused() external pure returns (bool) {
        return false;
    }
}

/// @notice A 1 wei first deposit followed by a few hours of emission pushes accRewardPerShare so high that
///         `sharesOf * accRewardPerShare` overflows for any ordinary deposit; the farm then refuses every
///         deposit above a shrinking ceiling forever (accRewardPerShare never decreases).
contract AccOverflowTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address griefer = makeAddr("griefer");
    address alice = makeAddr("alice");

    CoreStub core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new CoreStub(GENESIS);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        cheese = new CheeseToken(owner, owner, owner, address(controller));
        farm = new CheeseFarmETH(owner, address(controller));
        vm.startPrank(owner);
        controller.bindToken(address(cheese));
        controller.addPool(address(farm), 200);
        controller.activate();
        vm.stopPrank();
        // certify through startRound - 1 with no blocks so h0 == 0
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
        assertTrue(controller.startCaptured());
        vm.deal(griefer, 1 ether);
        vm.deal(alice, 1000 ether);
    }

    function test_oneWeiDepositThenEmissionBricksOrdinaryDeposits() public {
        // Griefer is the first and only staker with 1 wei (1000 shares).
        vm.prank(griefer);
        farm.deposit{value: 1}();
        assertEq(farm.totalShares(), 1000);

        // 1000 Squeek blocks (about four hours) get certified; the pool's 20% share accrues to 1000 shares.
        core.settle(core.settledThroughRound() + 1, 1000);

        // Alice deposits 1 ETH: expected to succeed and mint ~1e21 shares.
        // Actual: `sharesOf * accRewardPerShare` overflows (panic 0x11) at CheeseFarm._deposit.
        vm.prank(alice);
        farm.deposit{value: 1 ether}();

        // Once fixed, the deposit lands and the view functions keep working.
        assertGt(farm.sharesOf(alice), 0);
        farm.pendingRewards(alice);
    }
}