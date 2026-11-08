// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev SqueekCore stand-in with the live ABI. `bombBytes != 0` simulates a broken or compromised Core upgrade
///      whose state() returns that many bytes of zeroes.
contract CoreDouble {
    uint64 internal genesis;
    uint64 internal settled;
    uint96 internal units;
    uint256 internal bombBytes;

    constructor(uint64 genesis_) {
        genesis = genesis_;
    }

    function settle(uint64 round, uint64 blocks) external {
        settled = round;
        units = uint96(blocks) * 1e9;
    }

    function bomb(uint256 bytes_) external {
        bombBytes = bytes_;
    }

    function state() external view returns (ISqueekCore.CoreState memory s) {
        uint256 b = bombBytes;
        if (b != 0) {
            assembly {
                return(0, b)
            }
        }
        s.settledThroughRound = settled;
        s.cumulativeBlockUnits = units;
        s.blockHeight = uint64(units / 1e9);
    }

    function configuration() external view returns (ISqueekCore.CoreConfiguration memory c) {
        c.genesisTimestamp = genesis;
        c.roundDuration = 600;
        c.blockUnitsPerBlock = 1e9;
    }

    function roundPage(uint64, uint64 through, uint256) external view returns (ISqueekCore.RoundPage memory p) {
        p.certifiedThroughRound = through;
        p.end.cumulativeBlockUnits = units;
    }
}

/// @notice A SqueekCore whose state() returns a very large payload makes the controller's raw staticcall copy
///         all of it into memory, and the quadratic memory cost exhausts the 1/64 of gas the caller kept. Every
///         path that syncs then runs out of gas: withdraw, claim, checkpoint and, since the revision that syncs
///         first, pauseEmissions too, so the guardian's emergency pause no longer frees principal.
contract ReturnBombTest is Test {
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    CoreDouble core;
    CheeseEmissionController controller;
    CheeseFarmETH ethFarm;

    function setUp() public {
        uint64 genesis = 1_793_735_400;
        vm.warp(genesis + 100 * 600 + 17);
        core = new CoreDouble(genesis);
        vm.startPrank(owner);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        CheeseToken token = new CheeseToken(owner, treasury, owner, address(controller));
        ethFarm = new CheeseFarmETH(owner, address(controller));
        controller.bindToken(address(token));
        controller.addPool(address(ethFarm), 200);
        controller.activate();
        vm.stopPrank();
        uint64 start = controller.startRound();
        core.settle(start - 1, 0);
        controller.checkpoint();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        ethFarm.deposit{value: 1 ether}();
        core.settle(start, 10);
        controller.checkpoint();
        // Core now answers state() with 2 MiB of zeroes.
        core.bomb(2 << 20);
    }

    /// @dev Fails today (OutOfGas inside the withdrawal); passes once the Core read copies at most the expected
    ///      CORE_STATE_BYTES of return data (bounded returndatacopy) and treats any other size as unavailable.
    function test_withdrawSurvivesReturnBombingCore() public {
        uint256 shares = ethFarm.sharesOf(alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        ethFarm.withdraw{gas: 30_000_000}(shares);
        assertEq(alice.balance - before, 0.85 ether, "85% of principal returned");
    }

    /// @dev The emergency stop must not depend on SqueekCore behaving.
    function test_guardianPauseSurvivesReturnBombingCore() public {
        vm.prank(owner);
        controller.pauseEmissions{gas: 30_000_000}();
        assertTrue(controller.emissionsPaused());
    }
}
