// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {SqueekIssuance} from "src/libraries/SqueekIssuance.sol";

/// @dev Minimal SqueekCore double: certifies rounds, completes blocks, and can be made unreadable.
contract OutageCore is ISqueekCore {
    uint64 public genesisTimestamp;
    uint64 public settledThroughRound;
    uint96 public cumulativeBlockUnits;
    bool public unavailable;
    mapping(uint64 => uint96) public unitsAfterRound;

    constructor(uint64 genesis) {
        genesisTimestamp = genesis;
    }

    function setUnavailable(bool v) external {
        unavailable = v;
    }

    function settle(uint64 round, uint64 newBlocks) external {
        cumulativeBlockUnits += uint96(newBlocks) * 1_000_000_000;
        for (uint64 r = settledThroughRound + 1; r <= round; ++r) {
            unitsAfterRound[r] = cumulativeBlockUnits;
        }
        settledThroughRound = round;
    }

    function state() external view returns (CoreState memory r) {
        require(!unavailable, "core unavailable");
        r.settledThroughRound = settledThroughRound;
        r.cumulativeBlockUnits = cumulativeBlockUnits;
        r.blockHeight = uint64(cumulativeBlockUnits / 1_000_000_000);
    }

    function configuration() external view returns (CoreConfiguration memory r) {
        require(!unavailable, "core unavailable");
        r.genesisTimestamp = genesisTimestamp;
        r.roundDuration = 600;
        r.blockUnitsPerBlock = 1_000_000_000;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256) external view returns (RoundPage memory r) {
        require(!unavailable, "core unavailable");
        require(throughRound <= settledThroughRound, "bounds");
        r.certifiedThroughRound = throughRound;
        r.start.cumulativeBlockUnits = unitsAfterRound[afterRound];
        r.end.cumulativeBlockUnits = unitsAfterRound[throughRound];
    }

    function blockInfo(uint64) external pure returns (BlockInfo memory) {
        revert("BlockNotSettled");
    }

    function paused() external pure returns (bool) {
        return false;
    }
}

/// @notice A depositor who joins while SqueekCore is unreadable receives emission for Squeek blocks that were
///         certified before the deposit. Deposits are closed while emissions are paused (the same "sync failed"
///         condition) but not when the sync fails because the Core is unreadable or regressed.
contract DepositDuringOutageTest is Test {
    uint64 constant GENESIS = 1_793_735_400;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    OutageCore core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new OutageCore(GENESIS);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        cheese = new CheeseToken(owner, owner, owner, address(controller));
        farm = new CheeseFarmETH(owner, address(controller));
        vm.startPrank(owner);
        controller.bindToken(address(cheese));
        controller.addPool(address(farm), 200);
        controller.activate();
        vm.stopPrank();
        // certify through startRound - 1 with zero completed blocks so h0 == 0
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
        assertTrue(controller.startCaptured());
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_depositorJoiningDuringCoreOutageGetsNoEarlierEmission() public {
        // alice is the only staker while 10 Squeek blocks are certified
        vm.prank(alice);
        farm.deposit{value: 1 ether}();
        core.settle(core.settledThroughRound() + 1, 10);

        // the Core becomes unreadable before anyone checkpoints; bob deposits during the outage
        core.setUnavailable(true);
        vm.prank(bob);
        (bool ok,) = address(farm).call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        // whether the deposit was accepted or refused, bob must never earn from blocks 1..10

        core.setUnavailable(false);
        controller.checkpoint();

        uint256 poolEmission = (SqueekIssuance.issued(10) * 200) / 1000;
        uint256 alicePending = farm.pendingRewards(alice);
        uint256 bobPending = farm.pendingRewards(bob);
        emit log_named_uint("deposit accepted", ok ? 1 : 0);
        emit log_named_uint("alice pending", alicePending);
        emit log_named_uint("bob pending", bobPending);
        assertEq(bobPending, 0, "bob earned emission for blocks certified before his deposit");
        assertEq(alicePending, poolEmission, "alice should receive the whole pool emission for blocks 1..10");
    }
}