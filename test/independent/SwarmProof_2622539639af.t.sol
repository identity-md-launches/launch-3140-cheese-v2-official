// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev Minimal SqueekCore double with an availability switch.
contract CoreStub is ISqueekCore {
    uint64 public genesis;
    uint64 public settledThroughRound;
    uint96 public units;
    bool public down;
    mapping(uint64 => uint96) public unitsAfter;

    constructor(uint64 g) {
        genesis = g;
    }

    function setDown(bool v) external {
        down = v;
    }

    function settle(uint64 round, uint64 blocks) external {
        units += uint96(blocks) * 1_000_000_000;
        for (uint64 r = settledThroughRound + 1; r <= round; ++r) unitsAfter[r] = units;
        settledThroughRound = round;
    }

    function state() external view returns (CoreState memory r) {
        require(!down, "core unavailable");
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
        require(!down, "core unavailable");
        r.certifiedThroughRound = b;
        r.start.cumulativeBlockUnits = unitsAfter[a];
        r.end.cumulativeBlockUnits = unitsAfter[b];
    }

    function blockInfo(uint64) external pure returns (BlockInfo memory r) {}

    function paused() external pure returns (bool) {
        return false;
    }
}

/// @notice While SqueekCore cannot be read, deposits still go through. Blocks certified before the deposit
///         are then priced at the next successful checkpoint and split with the new depositor, which the
///         brief forbids ("new depositors must never receive rewards accrued before their eligibility").
contract UnavailableInheritTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

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
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
        assertTrue(controller.startCaptured());
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_depositDuringCoreOutageInheritsEarlierBlocks() public {
        vm.prank(alice);
        farm.deposit{value: 1 ether}();

        // 100 blocks are certified while only Alice is staked, but nobody checkpoints them.
        core.settle(core.settledThroughRound() + 1, 100);

        // SqueekCore becomes unreadable; Bob deposits an equal amount during the outage.
        core.setDown(true);
        vm.prank(bob);
        // Fixed behavior rejects the deposit before it can inherit any earlier emission.
        vm.expectRevert(bytes4(keccak256("SyncRequired()")));
        farm.deposit{value: 1 ether}();
        core.setDown(false);

        // The outage ends and the 100 earlier blocks are priced.
        controller.checkpoint();

        uint256 alicePending = farm.pendingRewards(alice);
        uint256 bobPending = farm.pendingRewards(bob);
        assertGt(alicePending, 0, "alice earns the 100 blocks");
        // Expected: Bob was not staked when those blocks were certified, so he receives nothing from them.
        // Actual: Bob receives half of the 100 blocks' emission.
        assertEq(bobPending, 0, "bob must not inherit emission from before his deposit");
    }
}
