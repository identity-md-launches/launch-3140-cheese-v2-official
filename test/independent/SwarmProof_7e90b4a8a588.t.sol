// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev Minimal SqueekCore double: certifies rounds and completes blocks.
contract TinyCore is ISqueekCore {
    uint64 public genesisTimestamp;
    uint64 public settledThroughRound;
    uint96 public cumulativeBlockUnits;
    mapping(uint64 => uint96) public unitsAfterRound;

    constructor(uint64 genesis) {
        genesisTimestamp = genesis;
    }

    function settle(uint64 round, uint64 newBlocks) external {
        cumulativeBlockUnits += uint96(newBlocks) * 1_000_000_000;
        for (uint64 r = settledThroughRound + 1; r <= round; ++r) {
            unitsAfterRound[r] = cumulativeBlockUnits;
        }
        settledThroughRound = round;
    }

    function state() external view returns (CoreState memory result) {
        result.settledThroughRound = settledThroughRound;
        result.cumulativeBlockUnits = cumulativeBlockUnits;
        result.blockHeight = uint64(cumulativeBlockUnits / 1_000_000_000);
    }

    function configuration() external view returns (CoreConfiguration memory result) {
        result.genesisTimestamp = genesisTimestamp;
        result.roundDuration = 600;
        result.blockUnitsPerBlock = 1_000_000_000;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256)
        external
        view
        returns (RoundPage memory result)
    {
        result.certifiedThroughRound = throughRound;
        result.start.cumulativeBlockUnits = unitsAfterRound[afterRound];
        result.end.cumulativeBlockUnits = unitsAfterRound[throughRound];
    }

    function blockInfo(uint64) external pure returns (BlockInfo memory) {
        revert("BlockNotSettled");
    }

    function paused() external pure returns (bool) {
        return false;
    }
}

/// @notice A 1-wei first depositor makes `accRewardPerShare` grow by amount * 1e36 / 1000 per pull.
///         After one Squeek round the ETH farm refuses every deposit of a few ETH: `sharesOf * accRewardPerShare`
///         in CheeseFarm._deposit overflows uint256 and reverts. The accumulator never decreases, so the farm
///         is permanently unusable for ordinary deposits. Fails on the current code; passes once the
///         share * accumulator products use a 512-bit mulDiv (or ACC_PRECISION is lowered).
contract AccOverflowTest is Test {
    uint64 internal constant GENESIS = 1_793_735_400;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    TinyCore internal core;
    CheeseEmissionController internal controller;
    CheeseToken internal cheese;
    CheeseFarmETH internal ethFarm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new TinyCore(GENESIS);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        cheese = new CheeseToken(owner, owner, owner, address(controller));
        ethFarm = new CheeseFarmETH(owner, address(controller));
        vm.startPrank(owner);
        controller.bindToken(address(cheese));
        controller.addPool(address(ethFarm), 200);
        controller.activate();
        vm.stopPrank();
        // certify through startRound - 1 with zero blocks so h0 == 0
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
        assertTrue(controller.startCaptured());
        vm.deal(attacker, 1 ether);
        vm.deal(victim, 100 ether);
    }

    function test_oneWeiFirstDepositorBricksDepositsAfterOneRound() public {
        // 1. attacker is the first depositor with 1 wei -> 1000 shares
        vm.prank(attacker);
        ethFarm.deposit{value: 1}();
        assertEq(ethFarm.totalShares(), 1000);

        // 2. one Squeek round of 40 blocks is certified (about ten minutes)
        core.settle(core.settledThroughRound() + 1, 40);

        // 3. the victim deposits 10 ETH. Expected: shares minted, deposit accepted.
        //    Actual: arithmetic overflow in `sharesOf[msg.sender] * accRewardPerShare` (panic 0x11).
        vm.prank(victim);
        uint256 shares = ethFarm.deposit{value: 10 ether}();
        assertGt(shares, 0, "victim should receive shares");
        assertEq(ethFarm.totalAssets(), 10 ether + 1);
    }

    function test_thresholdDropsWithEveryRound() public {
        vm.prank(attacker);
        ethFarm.deposit{value: 1}();
        // 24 rounds (~4 hours) with the 1-wei staker alone
        for (uint256 i; i < 24; ++i) {
            core.settle(core.settledThroughRound() + 1, 40);
            controller.checkpoint();
        }
        // even 0.5 ETH is refused now
        vm.prank(victim);
        uint256 shares = ethFarm.deposit{value: 0.5 ether}();
        assertGt(shares, 0, "0.5 ETH deposit should succeed");
    }
}