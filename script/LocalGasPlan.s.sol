// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";
import {MockSqueekCore} from "../test/mocks/MockSqueekCore.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Simulation only. Broadcast cheatcodes collect UNSIGNED transaction requests in Forge's VM.
/// Run without --broadcast, without a signer, and without a live RPC. Never use this as a deployment script.
contract LocalGasPlan is Script {
    address constant OWNER = 0x0000000000000000000000000000000000001001;
    address[5] internal users = [
        0x0000000000000000000000000000000000001002,
        0x0000000000000000000000000000000000001003,
        0x0000000000000000000000000000000000001004,
        0x0000000000000000000000000000000000001005,
        0x0000000000000000000000000000000000001006
    ];
    uint256 constant ETH_DEPOSIT = 0.0001 ether;
    uint256 constant TOKEN_DEPOSIT = 10 ether;

    function run() external {
        // Deterministic VM fixture addresses only; no real wallet identity or key is used.
        vm.chainId(11155111);
        vm.warp(1_793_735_400 + 6_017);
        vm.deal(OWNER, 1 ether);
        for (uint256 i; i < users.length; ++i) {
            vm.deal(users[i], 1 ether);
        }

        vm.startBroadcast(OWNER);
        MockSqueekCore core = new MockSqueekCore(1_793_735_400);
        MockERC20 simd = new MockERC20("CHEESE QA mock sIMD", "mock-sIMD");
        CheeseEmissionController controller = new CheeseEmissionController(OWNER, address(core), OWNER);
        CheeseToken token = new CheeseToken(OWNER, OWNER, OWNER, address(controller));
        CheeseFarmERC20 cheeseFarm = new CheeseFarmERC20(OWNER, address(controller), address(token));
        CheeseFarmETH ethFarm = new CheeseFarmETH(OWNER, address(controller));
        CheeseFarmSIMD simdFarm = new CheeseFarmSIMD(OWNER, address(controller));
        controller.bindToken(address(token));
        controller.addPool(address(cheeseFarm), 400);
        controller.addPool(address(ethFarm), 200);
        controller.addPool(address(simdFarm), 200);
        simdFarm.setAsset(address(simd));
        controller.activate();
        core.settle(controller.startRound() - 1, 100, 0);
        controller.checkpoint();
        for (uint256 i; i < users.length; ++i) {
            token.transfer(users[i], 100 ether);
            simd.mint(users[i], 100 ether);
        }
        vm.stopBroadcast();

        for (uint256 i; i < users.length; ++i) {
            vm.startBroadcast(users[i]);
            token.approve(address(cheeseFarm), TOKEN_DEPOSIT);
            simd.approve(address(simdFarm), TOKEN_DEPOSIT);
            cheeseFarm.deposit(TOKEN_DEPOSIT);
            ethFarm.deposit{value: ETH_DEPOSIT}();
            simdFarm.deposit(TOKEN_DEPOSIT);
            vm.stopBroadcast();
        }
        vm.startBroadcast(OWNER);
        core.settle(core.settledThroughRound() + 1, 10, 0);
        controller.checkpoint();
        controller.setPoolWeight(0, 350);
        controller.setPoolWeight(0, 400);
        controller.disablePool(2);
        controller.enablePool(2);
        controller.pauseEmissions();
        controller.unpauseEmissions();
        vm.stopBroadcast();

        for (uint256 i; i < users.length; ++i) {
            vm.startBroadcast(users[i]);
            cheeseFarm.withdraw(cheeseFarm.sharesOf(users[i]) / 2);
            ethFarm.withdraw(ethFarm.sharesOf(users[i]) / 2);
            simdFarm.withdraw(simdFarm.sharesOf(users[i]) / 2);
            cheeseFarm.claim(users[i]);
            ethFarm.claim(users[i]);
            simdFarm.claim(users[i]);
            cheeseFarm.withdraw(cheeseFarm.sharesOf(users[i]));
            ethFarm.withdraw(ethFarm.sharesOf(users[i]));
            simdFarm.withdraw(simdFarm.sharesOf(users[i]));
            cheeseFarm.claim(users[i]);
            ethFarm.claim(users[i]);
            simdFarm.claim(users[i]);
            vm.stopBroadcast();
            require(cheeseFarm.sharesOf(users[i]) == 0, "CHEESE shares left");
            require(ethFarm.sharesOf(users[i]) == 0, "ETH shares left");
            require(simdFarm.sharesOf(users[i]) == 0, "sIMD shares left");
        }
        require(cheeseFarm.totalAssets() == 0, "CHEESE assets left");
        require(ethFarm.totalAssets() == 0, "ETH assets left");
        require(simdFarm.totalAssets() == 0, "sIMD assets left");
        console2.log("Simulation complete: 33 deployer actions, 17 actions per test wallet; all principal exited.");
    }
}
