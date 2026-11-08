// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

contract CoreStubA {
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

contract OutageDepositTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    CoreStubA core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new CoreStubA(GENESIS);
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

    function test_outageDeposit() public {
        vm.prank(alice);
        farm.deposit{value: 10 ether}();
        core.settle(core.settled() + 1, 1000); // 1000 blocks while only alice staked
        core.setDown(true);
        vm.prank(bob);
        // Accepted today although the 1000 blocks were not priced; a fixed farm refuses it (or prices them first).
        try farm.deposit{value: 10 ether}() {} catch {}
        core.setDown(false);
        vm.prank(alice); uint256 a = farm.claim(alice);
        vm.prank(bob); uint256 b = farm.claim(bob);
        emit log_named_uint("alice", a);
        emit log_named_uint("bob", b);
        assertEq(b, 0, "bob earned emission of blocks certified before his deposit");
    }
}