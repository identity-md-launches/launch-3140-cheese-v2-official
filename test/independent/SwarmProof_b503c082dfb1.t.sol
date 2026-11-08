// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

contract CoreStubR {
    uint64 public genesis;
    uint64 public settled;
    uint96 public units;
    mapping(uint64 => uint96) public after_;

    constructor(uint64 g) { genesis = g; }
    function settle(uint64 round, uint64 blocks) external {
        units += uint96(blocks) * 1e9;
        for (uint64 r = settled + 1; r <= round; ++r) after_[r] = units;
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
        require(a <= t && t <= settled, "bounds");
        p.certifiedThroughRound = t;
        p.end.cumulativeBlockUnits = after_[t];
    }
}

/// MasterChef debt rounding overpays by up to 1 wei per share change; the last claimer underflows rewardReserve.
contract RewardReserveUnderflowTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    CoreStubR core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new CoreStubR(GENESIS);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        cheese = new CheeseToken(owner, treasury, owner, address(controller));
        farm = new CheeseFarmETH(owner, address(controller));
        vm.startPrank(owner);
        controller.bindToken(address(cheese));
        controller.addPool(address(farm), 200);
        controller.activate();
        vm.stopPrank();
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
    }

    function test_lastClaimUnderflows() public {
        address[3] memory u = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];
        uint256[6] memory amt = [
            uint256(10000000000000000000),
            999999999000000000000413,
            999999999000000000000601,
            999999999000000000006234,
            999999999000001793735401,
            999999999000000000012429
        ];
        uint64[6] memory blocks = [uint64(3), 3, 3, 1, 2, 3];
        for (uint256 i; i < 6; ++i) {
            address who = u[i % 3];
            vm.deal(who, amt[i]);
            vm.prank(who);
            farm.deposit{value: amt[i]}();
            core.settle(core.settled() + 1, blocks[i]);
        }
        // Every staker must be able to claim what the farm reports; the third claim reverts with panic 0x11.
        for (uint256 i; i < 3; ++i) {
            vm.prank(u[i]);
            farm.claim(u[i]);
        }
        assertEq(farm.rewardReserve() + farm.claimedOf(u[0]) + farm.claimedOf(u[1]) + farm.claimedOf(u[2]),
            cheese.balanceOf(address(farm)) + farm.claimedOf(u[0]) + farm.claimedOf(u[1]) + farm.claimedOf(u[2]));
    }
}