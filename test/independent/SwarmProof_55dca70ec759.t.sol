// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

contract CoreStubB {
    uint64 public genesis;
    uint64 public settled;
    uint96 public units;
    bool public down;
    mapping(uint64 => uint96) public after_;

    constructor(uint64 g) { genesis = g; }
    function setDown(bool d) external { down = d; }
    function settle(uint64 round, uint64 blocks) external {
        units += uint96(blocks) * 1e9;
        for (uint64 r = settled + 1; r <= round; ++r) after_[r] = units;
        settled = round;
    }
    function state() external view returns (ISqueekCore.CoreState memory s) {
        require(!down, "down");
        s.settledThroughRound = settled;
        s.cumulativeBlockUnits = units;
        s.blockHeight = uint64(units / 1e9);
    }
    function configuration() external view returns (ISqueekCore.CoreConfiguration memory c) {
        require(!down, "down");
        c.genesisTimestamp = genesis;
        c.roundDuration = 600;
        c.blockUnitsPerBlock = 1e9;
    }
    function roundPage(uint64 a, uint64 t, uint256) external view returns (ISqueekCore.RoundPage memory p) {
        require(!down, "down");
        require(a <= t && t <= settled, "bounds");
        p.certifiedThroughRound = t;
        p.end.cumulativeBlockUnits = after_[t];
    }
}

contract PauseForfeitTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    CoreStubB core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new CoreStubB(GENESIS);
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
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_pauseForfeit() public {
        vm.prank(alice);
        farm.deposit{value: 10 ether}();
        core.settle(core.settled() + 1, 1000);
        vm.prank(owner);
        controller.pauseEmissions();
        uint256 shares = farm.sharesOf(alice);
        vm.startPrank(alice);
        farm.withdraw(shares);
        uint256 a = farm.claim(alice);
        vm.stopPrank();
        vm.prank(owner);
        controller.unpauseEmissions();
        vm.prank(bob);
        farm.deposit{value: 1 ether}();
        emit log_named_uint("alice claimed", a);
        emit log_named_uint("forfeited", controller.forfeitedEmission());
        assertGt(a, 0, "alice lost rewards for 1000 blocks certified before the pause");
    }
}