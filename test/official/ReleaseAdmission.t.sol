// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OfficialLaunchTest} from "../../checks/launch/OfficialLaunch.t.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseFarm} from "src/CheeseFarm.sol";
import {CheeseFarmERC20} from "src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "src/farms/CheeseFarmSIMD.sol";

contract ConstructorValueProbe {
    function attempt(bytes memory init) external payable returns (address created) {
        assembly ("memory-safe") {
            created := create(callvalue(), add(init, 32), mload(init))
        }
    }
}

/// @notice Include the existing exact-release creation hashes, complete runtime immutable checks,
/// factory ownership and premint checks in the default, offline `forge test` entry point.
/// This is a local rehearsal: no broadcast, wallet authentication, or live source verification is implied.
contract ReleaseAdmissionTest is OfficialLaunchTest {
    function test_allFiveConstructorsRejectNativeValue() public {
        bytes[5] memory init;
        init[0] = abi.encodePacked(type(CheeseEmissionController).creationCode, abi.encode(OWNER, CORE, OWNER));
        init[1] = abi.encodePacked(type(CheeseToken).creationCode, abi.encode(OWNER, OWNER, OWNER, address(controller)));
        init[2] = abi.encodePacked(
            type(CheeseFarmERC20).creationCode, abi.encode(OWNER, address(controller), address(cheese))
        );
        init[3] = abi.encodePacked(type(CheeseFarmETH).creationCode, abi.encode(OWNER, address(controller)));
        init[4] = abi.encodePacked(type(CheeseFarmSIMD).creationCode, abi.encode(OWNER, address(controller)));
        ConstructorValueProbe probe = new ConstructorValueProbe();
        vm.deal(address(this), 5);
        for (uint256 i; i < init.length; ++i) {
            assertEq(probe.attempt{value: 1}(init[i]), address(0), "nonzero constructor value accepted");
        }
        assertEq(address(probe).balance, 5, "failed creations must retain all constructor value");
        assertEq(cheese.totalMinted(), 210_000_000e18);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_strangerCannotPerformAnyPendingOwnerSetup(address stranger) public {
        if (stranger == OWNER) stranger = address(factory);
        bytes memory errorData = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger);
        vm.startPrank(stranger);
        vm.expectRevert(errorData);
        controller.bindToken(address(cheese));
        vm.expectRevert(errorData);
        controller.setTreasury(stranger);
        vm.expectRevert(errorData);
        controller.setGuardian(stranger);
        vm.expectRevert(errorData);
        controller.addPool(address(cheeseFarm), 400);
        vm.expectRevert(errorData);
        controller.activate();
        vm.expectRevert(errorData);
        simdFarm.setAsset(address(cheese));
        vm.expectRevert(errorData);
        cheeseFarm.setDepositsPaused(true);
        vm.expectRevert(errorData);
        ethFarm.setDepositsPaused(true);
        vm.expectRevert(errorData);
        simdFarm.setDepositsPaused(true);
        vm.stopPrank();
        assertEq(controller.owner(), OWNER);
        assertEq(controller.treasury(), OWNER);
        assertEq(controller.guardian(), OWNER);
        assertEq(controller.poolCount(), 0);
        assertEq(controller.token(), address(0));
        assertEq(address(simdFarm.asset()), address(0));
        assertFalse(controller.activated());
        assertEq(cheese.balanceOf(OWNER), 210_000_000e18);
    }

    function test_failedSIMDConfigurationLeavesItAvailableForVerifiedAsset() public {
        vm.startPrank(OWNER);
        vm.expectRevert(CheeseFarm.ZeroAddress.selector);
        simdFarm.setAsset(address(0));
        vm.expectRevert(CheeseFarmSIMD.AssetIsNotAContract.selector);
        simdFarm.setAsset(OWNER);
        vm.stopPrank();
        assertEq(address(simdFarm.asset()), address(0));
        vm.expectRevert(CheeseFarm.AssetNotConfigured.selector);
        simdFarm.deposit(1);
        assertEq(simdFarm.totalShares(), 0);
        assertEq(simdFarm.totalAssets(), 0);
    }
}
