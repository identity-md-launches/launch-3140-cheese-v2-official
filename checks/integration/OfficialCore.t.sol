// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseEmissionController} from "../../src/CheeseEmissionController.sol";
import {CheeseToken} from "../../src/CheeseToken.sol";
import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";
import {SqueekIssuance} from "../../src/libraries/SqueekIssuance.sol";
import {VerifySqueekchain} from "../../script/VerifySqueekchain.s.sol";

/// @notice Optional READ-ONLY fork suite. No broadcasts and no changes to Squeekchain contracts.
///         Not part of the offline suite: run explicitly with the recorded Sepolia fork block.
contract OfficialCoreCompatibilityTest is Test {
    address internal constant OWNER = 0xDEA11b3A70b77134424d436f6eb455f1Abbd4449;
    ISqueekCore internal constant CORE = ISqueekCore(0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4);
    CheeseEmissionController internal controller;
    CheeseToken internal token;

    function setUp() public {
        assertEq(block.chainid, 11_155_111, "Sepolia only");
        assertGt(address(CORE).code.length, 0, "requires a real Sepolia fork");
        new VerifySqueekchain().run();
        controller = new CheeseEmissionController(OWNER, address(CORE), OWNER);
        token = new CheeseToken(OWNER, OWNER, OWNER, address(controller));
        vm.prank(OWNER);
        controller.bindToken(address(token));
    }

    function test_liveClockActivationBeginsNextRoundWithoutRetroactiveEmission() public {
        ISqueekCore.CoreConfiguration memory config = CORE.configuration();
        vm.prank(OWNER);
        controller.activate(); // Local fork only; official release activation remains pending.
        assertEq(controller.genesisTimestamp(), config.genesisTimestamp);
        assertEq(controller.startRound(), (block.timestamp - config.genesisTimestamp) / 600 + 2);
        (bool synced, uint256 amount) = controller.checkpoint();
        assertTrue(synced);
        assertEq(amount, 0);
        assertEq(token.totalSupply(), 210_000_000e18);
    }

    function test_realHistoricalRoundPageDecodesAndCertifiedBlocksCannotBePricedTwice() public {
        ISqueekCore.CoreState memory state = CORE.state();
        ISqueekCore.CoreConfiguration memory config = CORE.configuration();
        assertGt(state.settledThroughRound, 1);
        assertEq(state.blockHeight, state.cumulativeBlockUnits / config.blockUnitsPerBlock);
        assertEq(state.blockProgress, state.cumulativeBlockUnits % config.blockUnitsPerBlock);
        assertFalse(state.paused, "review a paused Core before activation");
        uint64 anchorRound = state.settledThroughRound - 1;
        ISqueekCore.RoundPage memory page = CORE.roundPage(anchorRound, anchorRound, 0);
        uint64 anchor = uint64(page.end.cumulativeBlockUnits / config.blockUnitsPerBlock);
        // Rehearse an activation before the latest already-certified round, using actual historical Core data.
        // Only the local test timestamp changes. Core storage and code are never patched.
        vm.warp(uint256(config.genesisTimestamp) + uint256(anchorRound) * config.roundDuration - 1);
        vm.prank(OWNER);
        controller.activate();
        assertEq(controller.startRound(), state.settledThroughRound);
        (bool synced, uint256 amount) = controller.checkpoint();
        assertTrue(synced);
        assertTrue(controller.startCaptured());
        assertEq(controller.startHeight(), anchor);
        assertEq(controller.lastHeight(), state.blockHeight);
        assertEq(amount, SqueekIssuance.issued(state.blockHeight - anchor));
        (synced, amount) = controller.checkpoint();
        assertTrue(synced);
        assertEq(amount, 0);
        assertEq(controller.totalMinted(), 0, "no pools registered in this local probe");
    }
}
