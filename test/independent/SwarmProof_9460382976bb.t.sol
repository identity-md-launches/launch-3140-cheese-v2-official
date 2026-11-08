// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev Core double whose state() can be switched to return data the controller's ABI cannot decode
///      (an upgraded proxy with a changed CoreState layout, or a proxy whose implementation was removed).
contract ShapeShiftCore {
    uint64 public genesisTimestamp;
    uint64 public settledThroughRound;
    uint96 public cumulativeBlockUnits;
    uint8 public mode; // 0 = normal, 1 = short return data, 2 = empty return data
    mapping(uint64 => uint96) public unitsAfterRound;

    constructor(uint64 genesis) {
        genesisTimestamp = genesis;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function settle(uint64 round, uint64 newBlocks) external {
        cumulativeBlockUnits += uint96(newBlocks) * 1_000_000_000;
        for (uint64 r = settledThroughRound + 1; r <= round; ++r) {
            unitsAfterRound[r] = cumulativeBlockUnits;
        }
        settledThroughRound = round;
    }

    function configuration() external view returns (ISqueekCore.CoreConfiguration memory r) {
        r.genesisTimestamp = genesisTimestamp;
        r.roundDuration = 600;
        r.blockUnitsPerBlock = 1_000_000_000;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256)
        external
        view
        returns (ISqueekCore.RoundPage memory r)
    {
        r.certifiedThroughRound = throughRound;
        r.start.cumulativeBlockUnits = unitsAfterRound[afterRound];
        r.end.cumulativeBlockUnits = unitsAfterRound[throughRound];
    }

    // state() is served by the fallback so the return shape can change after "an upgrade"
    fallback(bytes calldata) external returns (bytes memory) {
        if (mode == 1) return abi.encode(uint256(1), uint256(2)); // 2 words, the decoder needs 8
        if (mode == 2) return "";
        ISqueekCore.CoreState memory s;
        s.settledThroughRound = settledThroughRound;
        s.cumulativeBlockUnits = cumulativeBlockUnits;
        s.blockHeight = uint64(cumulativeBlockUnits / 1_000_000_000);
        return abi.encode(s);
    }
}

/// @notice `_sync` catches reverts from SqueekCore but not return-data decoding failures; those propagate out of
///         pullRewards and block every farm withdraw and claim until the owner pauses emissions.
contract MalformedCoreTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    ShapeShiftCore core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new ShapeShiftCore(GENESIS);
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
    }

    function test_shortReturnData_withdrawStillWorks() public {
        core.setMode(1);
        uint256 half = farm.sharesOf(alice) / 2;
        vm.prank(alice);
        farm.withdraw(half);
    }

    function test_emptyReturnData_withdrawStillWorks() public {
        core.setMode(2);
        uint256 half = farm.sharesOf(alice) / 2;
        vm.prank(alice);
        farm.withdraw(half);
    }

    function test_coreWithoutCode_withdrawAndClaimStillWork() public {
        vm.etch(address(core), "");
        uint256 half = farm.sharesOf(alice) / 2;
        vm.prank(alice);
        farm.withdraw(half);
        vm.prank(alice);
        farm.claim(alice);
    }
}