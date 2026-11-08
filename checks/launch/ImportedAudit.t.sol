// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "../../test/CheeseBase.t.sol";
import {CheeseEmissionController} from "../../src/CheeseEmissionController.sol";
import {CheeseToken} from "../../src/CheeseToken.sol";
import {CheeseFarm} from "../../src/CheeseFarm.sol";
import {CheeseFarmSIMD} from "../../src/farms/CheeseFarmSIMD.sol";

/// @dev Adversarial fixture only. Demonstrates the owner's schedule-bounded pool admission power.
contract AuditEmissionSink {
    CheeseEmissionController public immutable controller;
    bool public registered;
    uint256 public poolId;

    constructor(CheeseEmissionController controller_) {
        controller = controller_;
    }

    function emissionController() external view returns (address) {
        return address(controller);
    }

    function onPoolRegistered(uint256 id) external {
        require(msg.sender == address(controller));
        require(!registered);
        registered = true;
        poolId = id;
    }

    function pull() external returns (uint256 amount) {
        (amount,) = controller.pullRewards(poolId, true);
    }
}

/// @notice Evidence of the supplied audit's limitations, not tests claiming these risks were removed.
contract ImportedAuditTest is CheeseBase {
    function test_auditOwnerCanRouteOnlyProspectiveScheduledEmission() public {
        AuditEmissionSink sink = new AuditEmissionSink(controller);
        vm.startPrank(owner);
        controller.setPoolWeight(0, 0);
        controller.setPoolWeight(1, 0);
        controller.addPool(address(sink), 800);
        vm.expectRevert(abi.encodeWithSelector(CheeseToken.UnauthorizedMinter.selector, owner));
        cheese.mintEmission(owner, 1);
        vm.stopPrank();
        assertEq(sink.pull(), 0, "nothing before activation");
        activateWithHistory(1000);
        advanceBlocks(40);
        assertEq(sink.pull(), 117586262400352419921864);
        assertEq(cheese.balanceOf(address(sink)), issued(40) * 800 / 1000);
        assertEq(sink.pull(), 0, "no duplicate mint");
        assertLe(controller.totalMinted(), controller.cumulativeEmission());
    }

    function test_auditOneWeiStakeReceivesRetainedFeeAndFinalDustGoesToTreasury() public {
        vm.prank(alice);
        ethFarm.deposit{value: 1000 ether}();
        vm.prank(bob);
        ethFarm.deposit{value: 1}();
        // Revision (finding df1f3c45): the retained share is capped at 15/85 of the assets backing the
        // remaining shares. Bob's 1 wei backs a cap of 0, so the whole 150 ETH fee goes to the Treasury now.
        uint256 beforeTreasury = treasury.balance;
        assertEq(withdrawAll(ethFarm, alice), 850 ether);
        assertEq(treasury.balance - beforeTreasury, 150 ether);
        assertEq(ethFarm.totalAssets(), 1);
        assertEq(ethFarm.assetsOf(bob), 1);
        assertEq(withdrawAll(ethFarm, bob), 1);
        assertEq(ethFarm.totalAssets(), 0);
        assertEq(address(ethFarm).balance, 0);
    }

    function test_auditJustInTimeStakeSharesNextCertification() public {
        activateWithHistory(1000);
        vm.prank(alice);
        ethFarm.deposit{value: 10 ether}();
        advanceBlocks(40);
        vm.prank(bob);
        ethFarm.deposit{value: 10 ether}(); // Pulls all already-certified emission to Alice first.
        assertEq(ethFarm.pendingRewards(bob), 0);
        advanceBlocks(40);
        // Revision (finding a4e5b610): bob's shares wait for one priced pull, so the round certified right
        // after his deposit is alice's alone; his exit fee buys nothing.
        assertEq(withdrawAll(ethFarm, bob), 8.5 ether);
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), 0);
        assertApproxEqAbs(ethFarm.pendingRewards(alice), (issued(80) * 200) / 1000, 2);
    }

    function test_auditUnconfiguredSIMDForfeitsAndCannotRepairWrongAsset() public {
        CheeseFarmSIMD unset = new CheeseFarmSIMD(owner, address(controller));
        vm.startPrank(owner);
        controller.setPoolWeight(2, 0);
        controller.addPool(address(unset), 200);
        vm.stopPrank();
        activateWithHistory(1000);
        advanceBlocks(40);
        vm.prank(carol);
        assertEq(unset.claim(carol), 0);
        assertEq(controller.forfeitedEmission(), 29396565600088104980466);
        assertEq(cheese.totalSupply(), cheese.PREMINT());
        vm.startPrank(owner);
        unset.setAsset(address(cheese)); // Deliberately wrong, test only: code-length check accepts it.
        vm.expectRevert(CheeseFarmSIMD.AssetAlreadySet.selector);
        unset.setAsset(address(simd));
        vm.stopPrank();
    }

    function test_auditRenounceAfterPauseIsIrrecoverableButWithdrawalWorks() public {
        vm.prank(alice);
        ethFarm.deposit{value: 10 ether}();
        vm.startPrank(owner);
        controller.pauseEmissions();
        controller.renounceOwnership(); // Demonstration only; explicitly forbidden in the launch runbook.
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        controller.unpauseEmissions();
        vm.stopPrank();
        assertEq(controller.owner(), address(0));
        assertTrue(controller.emissionsPaused());
        vm.prank(bob);
        vm.expectRevert(CheeseFarm.EmissionsPausedDepositsClosed.selector);
        ethFarm.deposit{value: 1 ether}();
        assertEq(withdrawAll(ethFarm, alice), 8.5 ether);
    }

    function test_runbookDefersActivationUntilAssetVerifiedAndNeverReopensHistory() public {
        // This test models the ordering only. Its local mock is never evidence of a real sIMD identity.
        CheeseFarmSIMD unset = new CheeseFarmSIMD(owner, address(controller));
        vm.startPrank(owner);
        controller.setPoolWeight(2, 0);
        controller.addPool(address(unset), 200);
        vm.stopPrank();
        core.settle(101, 1000, 0);
        vm.prank(carol);
        unset.claim(carol);
        assertFalse(controller.activated());
        assertEq(controller.cumulativeEmission(), 0);
        assertEq(controller.forfeitedEmission(), 0);
        assertEq(controller.totalMinted(), 0);
        vm.prank(owner);
        unset.setAsset(address(simd));
        vm.prank(owner);
        controller.activate();
        core.settle(controller.startRound() - 1, 0, 0);
        controller.checkpoint();
        assertTrue(controller.startCaptured());
        assertEq(controller.startHeight(), 1000);
        assertEq(controller.cumulativeEmission(), 0, "pre-activation blocks excluded");
    }
}
