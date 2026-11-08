// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @notice Minimal SqueekCore double: certifies rounds and completes blocks.
contract CoreDouble is ISqueekCore {
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

    function roundPage(uint64 afterRound, uint64 throughRound, uint256) external view returns (RoundPage memory result) {
        result.certifiedThroughRound = throughRound;
        result.start.cumulativeBlockUnits = unitsAfterRound[afterRound];
        result.end.cumulativeBlockUnits = unitsAfterRound[throughRound];
    }

    function blockInfo(uint64) external pure returns (BlockInfo memory) {
        revert();
    }

    function paused() external pure returns (bool) {
        return false;
    }
}

/// @notice A SqueekCore whose every call expands memory to 2 MiB, burns the forwarded gas down to ~65k and then
///         returns the whole 2 MiB. The caller keeps 1/64 of its gas and must copy 2 MiB of return data (~8.6M
///         gas), so it runs out of gas however much the transaction supplies.
///
///         Bytecode: PUSH1 0 PUSH3 0x1FFFE0 MSTORE | JUMPDEST GAS PUSH3 0xFFFF LT PUSH1 7 JUMPI |
///                   PUSH3 0x200000 PUSH1 0 RETURN
contract ReturnBombCoreTest is Test {
    uint64 internal constant GENESIS = 1_793_735_400;
    bytes internal constant BOMB = hex"6000621fffe0525b5a6200ffff10600757622000006000f3";

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");

    CoreDouble internal core;
    CheeseEmissionController internal controller;
    CheeseToken internal cheese;
    CheeseFarmETH internal farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new CoreDouble(GENESIS);
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
        vm.prank(alice);
        farm.deposit{value: 1 ether}();
        core.settle(core.settledThroughRound() + 1, 10);
        controller.checkpoint();
        assertGt(farm.pendingRewards(alice), 0);
    }

    function test_returnBombCoreDoesNotBlockWithdrawClaimOrPause() public {
        vm.etch(address(core), BOMB);

        // Sanity: a bare call to the bomb succeeds when the caller can afford the copy but burns the gas.
        (bool ok, bytes memory data) = address(core).staticcall{gas: 20_000_000}(abi.encodeCall(ISqueekCore.state, ()));
        assertTrue(ok);
        assertEq(data.length, 0x200000);

        // The brief: Squeekchain unavailability must never block withdrawals; owner emergency procedures work.
        uint256 shares = farm.sharesOf(alice);
        vm.prank(alice);
        uint256 paid = farm.withdraw{gas: 30_000_000}(shares);
        assertEq(paid, 0.85 ether, "85% of principal paid");

        vm.prank(alice);
        uint256 claimed = farm.claim{gas: 30_000_000}(alice);
        assertGt(claimed, 0, "accrued rewards claimable");

        vm.prank(owner);
        controller.pauseEmissions{gas: 30_000_000}();
        assertTrue(controller.emissionsPaused(), "emergency pause works");
    }
}