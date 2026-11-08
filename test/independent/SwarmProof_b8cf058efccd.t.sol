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
    bool public down;
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

    function setDown(bool d) external {
        down = d;
    }

    function state() external view returns (ISqueekCore.CoreState memory s) {
        require(!down, "core unavailable");
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

/// @notice A depositor must never receive emission for Squeek blocks certified before their deposit. While
///         SqueekCore.state() reverts, CheeseFarm._deposit still accepts deposits (only emissionsPaused closes
///         them), pullRewards' best-effort _sync silently fails, and the blocks certified before the deposit are
///         priced later and spread over the late depositor's shares too.
contract OutageRetroactiveRewardProof is Test {
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
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
        vm.deal(bob, 100 ether);
    }

    function test_lateDepositorDuringOutageGetsNoEarlierEmission() public {
        vm.prank(alice);
        farm.deposit{value: 1 ether}();
        core.settle(core.settled() + 1, 1000); // certified while alice is the only depositor
        core.setDown(true);
        // Expected: the deposit is refused (or the earlier blocks are attributed to alice alone).
        vm.prank(bob);
        try farm.deposit{value: 99 ether}() {} catch {}
        core.setDown(false);
        controller.checkpoint();
        // Expected 0 for bob; actual ~99% of the 1000 blocks' pool emission.
        assertEq(farm.pendingRewards(bob), 0, "bob earned emission from blocks before their deposit");
    }
}