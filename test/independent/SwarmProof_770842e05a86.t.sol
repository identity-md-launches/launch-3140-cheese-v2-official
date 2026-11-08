// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

contract OverdraftCore is ISqueekCore {
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

/// @notice Floored per-account reward debts let accounts jointly earn more than the farm pulled. Once emission
///         has completed nothing refills rewardReserve, so the last claimer's whole claim reverts forever.
///         Fails on the current code with panic 0x11 at `rewardReserve -= amount`; passes once the sum of
///         harvested rewards can no longer exceed the reserve (or the payout is clamped to it).
contract RewardOverdraftTest is Test {
    uint64 internal constant GENESIS = 1_793_735_400;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    OverdraftCore internal core;
    CheeseEmissionController internal controller;
    CheeseToken internal cheese;
    CheeseFarmETH internal farm;
    address[5] internal users;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new OverdraftCore(GENESIS);
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
        users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2"), makeAddr("u3"), makeAddr("u4")];
        for (uint256 i; i < 5; ++i) {
            vm.deal(users[i], 1000 ether);
        }
    }

    /// Twelve ordinary deposits of 0.01 to 5 ETH by five accounts, 1 to 80 blocks apart, no dust and no withdrawal.
    function test_everyAccountCanClaimAfterEmissionEnds() public {
        for (uint256 k; k < 12; ++k) {
            uint256 r = uint256(keccak256(abi.encode(SEED, k)));
            vm.prank(users[r % 5]);
            farm.deposit{value: 0.01 ether + (r >> 16) % 5 ether}();
            core.settle(core.settledThroughRound() + 1, uint64(1 + (r >> 200) % 80));
        }
        core.settle(core.settledThroughRound() + 1, 3 * 393_470);
        controller.checkpoint();
        assertTrue(controller.completed(), "emission completed");
        for (uint256 i; i < 5; ++i) {
            uint256 pending = farm.pendingRewards(users[i]);
            vm.prank(users[i]);
            uint256 paid = farm.claim(users[i]); // reverts with panic 0x11 for the account left short
            // A fix that clamps may leave the rounding dust unpaid, nothing more.
            assertApproxEqAbs(paid, pending, 16, "claim pays what pendingRewards reports");
        }
    }

    uint256 internal constant SEED = 13;
}