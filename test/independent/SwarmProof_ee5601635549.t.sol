// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev Minimal SqueekCore double: certifies rounds and completed blocks.
contract CoreDouble {
    uint64 public genesis;
    uint64 public settled;
    uint96 public units;
    mapping(uint64 => uint96) public after_;

    constructor(uint64 g) {
        genesis = g;
    }

    function settle(uint64 round, uint64 blocks) external {
        units += uint96(blocks) * 1e9;
        for (uint64 r = settled + 1; r <= round; ++r) {
            after_[r] = units;
        }
        settled = round;
    }

    function state() external view returns (ISqueekCore.CoreState memory s) {
        s.settledThroughRound = settled;
        s.cumulativeBlockUnits = units;
        s.blockHeight = uint64(units / 1e9);
    }

    function configuration() external view returns (ISqueekCore.CoreConfiguration memory c) {
        c.genesisTimestamp = genesis;
        c.roundDuration = 600;
        c.blockUnitsPerBlock = 1e9;
    }

    function roundPage(uint64 a, uint64 t, uint256) external view returns (ISqueekCore.RoundPage memory p) {
        p.certifiedThroughRound = t;
        p.start.cumulativeBlockUnits = after_[a];
        p.end.cumulativeBlockUnits = after_[t];
    }
}

/// @notice Every depositor must be able to claim the rewards pendingRewards() reports. Per-account reward
///         debt is floored (CheeseFarm._deposit / withdraw / _harvestDebt), so the sum of what accounts can
///         claim exceeds rewardReserve by a wei; the last claimer's claim() underflows `rewardReserve -= amount`
///         and reverts, permanently once emission has completed.
contract RoundingOverclaimProof is Test {
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    CoreDouble core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        uint64 genesis = 1_793_735_400;
        vm.warp(genesis + 100 * 600 + 17);
        core = new CoreDouble(genesis);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        cheese = new CheeseToken(owner, owner, owner, address(controller));
        farm = new CheeseFarmETH(owner, address(controller));
        vm.startPrank(owner);
        controller.bindToken(address(cheese));
        controller.addPool(address(farm), 200);
        controller.activate();
        vm.stopPrank();
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 1 ether);
    }

    function _advance(uint64 blocks) internal {
        core.settle(core.settled() + 1, blocks);
    }

    function test_everyDepositorCanClaimAfterEmissionEnds() public {
        vm.prank(alice);
        farm.deposit{value: 12021}();
        _advance(16);
        vm.prank(bob);
        farm.deposit{value: 2376452954}();
        _advance(1);
        vm.prank(carol);
        farm.deposit{value: 2231}();
        vm.prank(alice);
        farm.withdraw(17);
        _advance(44);
        controller.checkpoint();
        // Emission ends: no further CHEESE will ever reach the farm.
        _advance(3 * 393_470);
        controller.checkpoint();
        assertTrue(controller.completed());

        uint256 owedAlice = farm.pendingRewards(alice);
        uint256 owedBob = farm.pendingRewards(bob);
        uint256 owedCarol = farm.pendingRewards(carol);
        vm.prank(carol);
        assertEq(farm.claim(carol), owedCarol);
        vm.prank(bob);
        assertEq(farm.claim(bob), owedBob);
        // Expected: alice receives what pendingRewards reported. Actual: panic 0x11 (rewardReserve underflow).
        vm.prank(alice);
        assertEq(farm.claim(alice), owedAlice);
    }
}