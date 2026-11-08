// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";

/// @notice Regression tests for the two reviewer findings fixed for the official Sepolia launch:
///         - df1f3c45: a stake placed just before a dominant exit captured the retained 14% Hamster Bite;
///         - a4e5b610: a deposit mined just before the Reporter's settle tx earned a full share of the round.
contract LaunchFindingsTest is CheeseBase {
    // ------------------------------------------------------------------------------------------------
    // Hamster Bite: the retained share is capped at the remaining stake's own future fee
    // ------------------------------------------------------------------------------------------------

    /// Reviewer scenario: sole staker exits, a dust deposit lands just ahead of her in the same block.
    function test_dustFrontRunnerCannotProfitFromSoleStakerExit() public {
        depositEth(alice, 10 ether);
        uint256 aliceShares = ethFarm.sharesOf(alice);
        (uint256 gross,,, uint256 promised) = ethFarm.previewWithdraw(aliceShares);
        assertEq(promised, (gross * 1500) / 10_000, "sole staker: whole 15% to the Treasury");

        uint256 attackerBefore = carol.balance;
        depositEth(carol, 1000);
        uint256 treasuryBefore = treasury.balance;
        withdrawAll(ethFarm, alice);
        withdrawAll(ethFarm, carol);

        assertLe(carol.balance, attackerBefore, "front-runner never nets a profit");
        assertGe(treasury.balance - treasuryBefore, (gross * 1500) / 10_000, "Treasury receives the full 15%");
        assertEq(ethFarm.totalAssets(), 0);
        assertEq(address(ethFarm).balance, 0);
    }

    /// With honest stakers remaining, the attacker's inherited share never exceeds its own exit fee either.
    function test_frontRunnerWithHonestRemainingStakersCannotProfit() public {
        depositEth(alice, 100 ether); // dominant
        depositEth(bob, 10 ether); // honest remaining
        uint256 bobAssetsBefore = ethFarm.assetsOf(bob);
        uint256 attackerBefore = carol.balance;
        depositEth(carol, 10 ether); // same block, ahead of alice's exit
        withdrawAll(ethFarm, alice);
        withdrawAll(ethFarm, carol);
        assertLe(carol.balance, attackerBefore, "no profit");
        assertGe(ethFarm.assetsOf(bob), bobAssetsBefore, "honest remaining staker still gains");
    }

    /// The cap: retained = min(14% of gross, 15/85 of the assets backing the remaining shares).
    function test_retainedShareIsCappedAtRemainingStakesFee() public {
        depositEth(alice, 100 ether);
        depositEth(bob, 1 ether);
        uint256 shares = ethFarm.sharesOf(alice);
        uint256 remainingAssets = ethFarm.convertToAssets(ethFarm.totalShares() - shares);
        (uint256 gross,, uint256 retained, uint256 toTreasury) = ethFarm.previewWithdraw(shares);
        uint256 cap = (remainingAssets * 1500) / 8500;
        assertLt(cap, (gross * 1400) / 10_000, "scenario binds the cap");
        assertEq(retained, cap, "retained capped");
        assertEq(toTreasury, (gross * 1500) / 10_000 - cap, "excess goes to the Treasury");
        uint256 treasuryBefore = treasury.balance;
        uint256 assetsBefore = ethFarm.totalAssets();
        uint256 paid = withdrawAll(ethFarm, alice);
        assertEq(treasury.balance - treasuryBefore, toTreasury);
        assertEq(assetsBefore - ethFarm.totalAssets(), paid + toTreasury);
    }

    /// Below the cap nothing changes: 85 / 14 / 1 exactly.
    function test_smallExitKeepsTheFullFourteenPercent() public {
        depositEth(alice, 10 ether);
        depositEth(bob, 10 ether);
        uint256 shares = ethFarm.sharesOf(alice) / 2;
        (uint256 gross, uint256 paid, uint256 retained, uint256 toTreasury) = ethFarm.previewWithdraw(shares);
        assertEq(paid, gross - (gross * 1500) / 10_000);
        assertEq(retained, (gross * 1400) / 10_000);
        assertEq(toTreasury, (gross * 1500) / 10_000 - retained);
    }

    /// The last depositor still sweeps the whole 15% plus residual dust to the Treasury.
    function test_lastDepositorStillSweepsEverythingToTreasury() public {
        depositEth(alice, 5 ether);
        depositEth(bob, 5 ether);
        withdrawAll(ethFarm, alice);
        uint256 treasuryBefore = treasury.balance;
        uint256 backing = ethFarm.totalAssets();
        uint256 paid = withdrawAll(ethFarm, bob);
        assertEq(treasury.balance - treasuryBefore, backing - paid);
        assertEq(ethFarm.totalAssets(), 0);
    }

    /// Any split of a withdrawal, any sizes: a stake that arrives just before an exit and leaves right after
    /// never ends up with more than it brought.
    function testFuzz_frontRunnerNeverProfits(uint96 big, uint96 small, uint16 fractionBps) public {
        uint256 w = bound(big, 1e9, 900 ether);
        uint256 d = bound(small, 1, 900 ether);
        depositEth(alice, w);
        uint256 before = carol.balance;
        depositEth(carol, d);
        uint256 shares = (ethFarm.sharesOf(alice) * bound(fractionBps, 1, 10_000)) / 10_000;
        if (shares == 0) shares = 1;
        vm.prank(alice);
        ethFarm.withdraw(shares);
        withdrawAll(ethFarm, carol);
        // The 1 wei allowance is the farm's virtual asset (VIRTUAL_ASSETS), which the last exit sweeps.
        assertLe(carol.balance, before + 1, "zero-duration stake cannot profit from another's exit");
    }

    // ------------------------------------------------------------------------------------------------
    // Rewards: shares wait for one priced pull before they earn
    // ------------------------------------------------------------------------------------------------

    /// Reviewer scenario: a deposit mined just ahead of the settle tx earns nothing from that round.
    function test_depositAheadOfSettleEarnsNothingFromTheRound() public {
        activateWithHistory(0);
        depositCheese(alice, 100_000e18);
        uint256 honestBefore = cheeseFarm.pendingRewards(alice);
        giveCheese(bob, 100_000e18);
        uint256 attackerBefore = cheese.balanceOf(bob);
        vm.startPrank(bob);
        cheese.approve(address(cheeseFarm), type(uint256).max);
        cheeseFarm.deposit(100_000e18);
        vm.stopPrank();
        assertEq(cheeseFarm.waitingSharesOf(bob), cheeseFarm.sharesOf(bob), "bob's shares wait");
        assertEq(cheeseFarm.activeShares(), cheeseFarm.sharesOf(alice), "only alice earns");

        advanceBlocks(40); // the Reporter certifies one round
        uint256 roundToPool = (issued(40) * 400) / 1000;
        assertEq(cheeseFarm.pendingRewards(bob), 0, "nothing for the round he was not staked for");
        assertApproxEqAbs(cheeseFarm.pendingRewards(alice) - honestBefore, roundToPool, 2, "alice gets it all");

        vm.startPrank(bob);
        cheeseFarm.claim(bob);
        cheeseFarm.withdraw(cheeseFarm.sharesOf(bob));
        vm.stopPrank();
        assertLt(cheese.balanceOf(bob), attackerBefore, "the exit fee is a pure loss");
    }

    /// After one priced pull the waiting shares earn exactly like any other share.
    function test_waitingSharesEarnFromTheNextPricedPullOn() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        depositEth(bob, 3 ether);
        assertEq(ethFarm.waitingSharesOf(bob), 3 ether * 1e3);
        advanceBlocks(10); // alice's alone
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), 0, "waiting shares earn nothing from the pull they wait for");
        assertEq(ethFarm.waitingSharesOf(bob), 0, "activated by that pull");
        assertEq(ethFarm.activeShares(), ethFarm.totalShares());
        advanceBlocks(10);
        uint256 next = ((issued(20) - issued(10)) * 200) / 1000;
        assertApproxEqAbs(ethFarm.pendingRewards(bob), (next * 3) / 4, 2, "bob: 3/4 of the next round");
        assertApproxEqAbs(ethFarm.pendingRewards(alice), (issued(10) * 200) / 1000 + next / 4, 2);
        vm.prank(bob);
        uint256 claimed = ethFarm.claim(bob);
        assertApproxEqAbs(claimed, (next * 3) / 4, 2);
    }

    /// A pull that priced blocks but forfeited them (nobody active) still activates waiting shares.
    function test_forfeitedPullActivatesWaitingShares() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        depositEth(bob, 1 ether); // waits
        withdrawAll(ethFarm, alice); // nobody active, bob waiting
        assertEq(ethFarm.activeShares(), 0);
        advanceBlocks(5);
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), 0);
        assertEq(controller.forfeitedEmission(), (issued(5) * 200) / 1000, "chunk forfeited, not minted");
        assertEq(ethFarm.activeShares(), ethFarm.sharesOf(bob), "bob active from now on");
        advanceBlocks(5);
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), ((issued(10) - issued(5)) * 200) / 1000);
    }

    /// The first stake into an empty farm dilutes nobody and earns from the next pull.
    function test_firstDepositorIntoEmptyFarmEarnsImmediately() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        assertEq(ethFarm.waitingSharesOf(alice), 0);
        assertEq(ethFarm.activeShares(), ethFarm.sharesOf(alice));
        advanceBlocks(10);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), (issued(10) * 200) / 1000);
    }

    /// Withdrawals burn waiting shares first and never delay principal; the active debt stays consistent.
    function test_withdrawBurnsWaitingSharesFirst() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        depositEth(bob, 1 ether);
        advanceBlocks(10);
        vm.prank(bob);
        ethFarm.claim(bob); // bob active
        depositEth(bob, 2 ether); // waiting on top
        uint256 waiting = ethFarm.waitingSharesOf(bob);
        assertEq(waiting, 2 ether * 1e3);
        vm.prank(bob);
        ethFarm.withdraw(1 ether * 1e3);
        assertEq(ethFarm.waitingSharesOf(bob), waiting - 1 ether * 1e3, "waiting burned first");
        assertEq(ethFarm.activeShares(), 2 ether * 1e3, "alice's and bob's active shares untouched");
        advanceBlocks(10);
        uint256 next = ((issued(20) - issued(10)) * 200) / 1000;
        assertApproxEqAbs(ethFarm.pendingRewards(bob), next / 2, 2, "bob's active half");
        vm.prank(bob);
        uint256 claimed = ethFarm.claim(bob);
        assertApproxEqAbs(claimed, next / 2, 2);
        assertEq(ethFarm.waitingSharesOf(bob), 0, "the rest activated by that pull");
        assertEq(ethFarm.activeShares(), ethFarm.totalShares());
    }

    /// pendingRewards agrees with claim for accounts with active, waiting and freshly activated shares.
    function testFuzz_pendingMatchesClaimWithWaitingShares(uint96 a, uint96 b, uint96 c, uint32 blocks) public {
        uint256 da = bound(a, 1e9, 100 ether);
        uint256 db = bound(b, 1e9, 100 ether);
        uint256 dc = bound(c, 1e9, 100 ether);
        uint64 n = uint64(bound(blocks, 1, 5000));
        activateWithHistory(0);
        depositEth(alice, da);
        depositEth(bob, db);
        advanceBlocks(n);
        depositEth(bob, dc); // bob: active + waiting
        advanceBlocks(n);
        uint256 promisedA = ethFarm.pendingRewards(alice);
        uint256 promisedB = ethFarm.pendingRewards(bob);
        vm.prank(alice);
        assertEq(ethFarm.claim(alice), promisedA, "alice");
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), promisedB, "bob");
        advanceBlocks(n);
        promisedB = ethFarm.pendingRewards(bob);
        vm.prank(bob);
        assertEq(ethFarm.claim(bob), promisedB, "bob after activation");
        assertLe(cheese.balanceOf(alice) + cheese.balanceOf(bob), controller.totalMinted());
        assertEq(ethFarm.rewardReserve(), cheese.balanceOf(address(ethFarm)));
    }
}
