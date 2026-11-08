// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "../CheeseBase.t.sol";

/// @notice Edge cases of the waiting-share rule added to CheeseFarm for the official release (fix for the
///         just-in-time staking finding a4e5b610). `test/LaunchFindings.t.sol` covers the reviewer
///         scenario and single-epoch activation. These cover shares left unharvested for several epochs, a
///         top-up by an account that already earns, activation while the pool is disabled, and full
///         distribution of what the farm pulled after random sequences of deposits, exits and claims.
contract WaitingShareEdgesTest is CheeseBase {
    uint256 internal constant ETH_POINTS = 200;

    function _round(uint64 from, uint64 to) internal pure returns (uint256) {
        return ((issued(to) - issued(from)) * ETH_POINTS) / 1000;
    }

    function _claim(address who) internal returns (uint256) {
        vm.prank(who);
        return ethFarm.claim(who);
    }

    /// Waiting shares whose epoch ended at someone else's pull, and were never touched since, earn every
    /// later chunk pro rata and nothing from the chunk they waited for.
    function test_unharvestedWaitingSharesEarnEveryLaterEpoch() public {
        activateWithHistory(0);
        depositEth(alice, 1 ether);
        depositEth(bob, 1 ether); // waits
        advanceBlocks(10);
        _claim(alice); // prices the round: alice alone, then bob's epoch ends
        assertEq(ethFarm.activeShares(), ethFarm.totalShares(), "bob active");
        assertEq(ethFarm.waitingSharesOf(bob), 1 ether * 1e3, "bob not harvested: still recorded as waiting");
        advanceBlocks(10);
        _claim(alice);
        advanceBlocks(10);
        _claim(alice);
        uint256 later = _round(10, 30);
        uint256 promised = ethFarm.pendingRewards(bob);
        assertApproxEqAbs(promised, later / 2, 4, "half of every chunk after activation");
        assertEq(_claim(bob), promised, "claim pays what the view promised");
        assertApproxEqAbs(cheese.balanceOf(alice), _round(0, 10) + later / 2, 4, "alice: first chunk alone");
        assertLe(cheese.balanceOf(alice) + cheese.balanceOf(bob), _round(0, 30), "never more than was emitted");
    }

    /// An account that already earns cannot top up just ahead of a certification and collect on the top-up:
    /// the new shares wait like anybody else's.
    function test_topUpByEarningAccountWaitsForNextPricedPull() public {
        activateWithHistory(0);
        depositEth(alice, 10 ether);
        depositEth(carol, 1 gwei);
        warmUp(ethFarm); // carol's dust now earns
        assertEq(ethFarm.activeShares(), ethFarm.totalShares(), "carol's dust epoch ended");
        uint256 aliceBefore = ethFarm.pendingRewards(alice);
        uint256 carolBefore = ethFarm.pendingRewards(carol);

        depositEth(carol, 500 ether); // just ahead of the settle tx
        assertEq(ethFarm.waitingSharesOf(carol), 500 ether * 1e3, "only the top-up waits (dust merged on harvest)");
        advanceBlocks(40);
        uint256 round = _round(1, 41);
        uint256 carolGain = ethFarm.pendingRewards(carol) - carolBefore;
        // carol's earning stake is 1 gwei against 10 ether: her honest share of the round is about 1e-10 of it
        assertLe(carolGain, round / 1e9 + 2, "top-up earned nothing from the round");
        assertApproxEqAbs(ethFarm.pendingRewards(alice) - aliceBefore, round, round / 1e9 + 2, "alice keeps it");

        // The exit costs the top-up 15% (the cap keeps alice's inherited part at most 15/85 of her stake).
        uint256 cashBefore = carol.balance;
        withdrawAll(ethFarm, carol);
        assertLt(carol.balance - cashBefore, 500 ether, "pure loss for the top-up");
    }

    /// A pull that prices blocks while the pool is disabled mints nothing for the farm but still ends the
    /// epoch: the waiting shares were staked through that period. After re-enabling, the shares earn pro rata
    /// and the disabled period's emission is minted to nobody.
    function test_waitingSharesActivateWhilePoolDisabledWithoutBackdatedEmission() public {
        activateWithHistory(0);
        uint256 pid = ethFarm.poolId();
        depositEth(alice, 1 ether);
        vm.prank(owner);
        controller.disablePool(pid);
        depositEth(bob, 1 ether); // waits
        advanceBlocks(10);
        assertEq(_claim(alice), 0, "disabled pool emits nothing to the farm");
        assertEq(ethFarm.activeShares(), ethFarm.totalShares(), "priced pull ended bob's epoch");
        (,,,, uint256 mintedBefore) = controller.getPoolAllocation(pid);
        assertEq(mintedBefore, 0);

        vm.prank(owner);
        controller.enablePool(pid);
        advanceBlocks(10);
        uint256 next = _round(10, 20);
        assertApproxEqAbs(ethFarm.pendingRewards(bob), next / 2, 2, "half the first enabled chunk");
        assertApproxEqAbs(ethFarm.pendingRewards(alice), next / 2, 2, "no backdated disabled-period emission");
        _claim(alice);
        _claim(bob);
        (,,,, uint256 minted) = controller.getPoolAllocation(pid);
        assertApproxEqAbs(minted, next, 1, "only the enabled period was minted");
    }

    /// Waiting shares never block principal, even when nothing will ever activate them (schedule complete).
    function test_waitingSharesWithdrawWithoutAnyActivation() public {
        activateWithHistory(0);
        depositEth(alice, 2 ether);
        depositEth(bob, 2 ether);
        uint256 shares = ethFarm.sharesOf(bob);
        assertEq(ethFarm.waitingSharesOf(bob), shares);
        uint256 cashBefore = bob.balance;
        (, uint256 preview,,) = ethFarm.previewWithdraw(shares);
        vm.prank(bob);
        uint256 paid = ethFarm.withdraw(shares);
        assertEq(paid, preview);
        assertEq(bob.balance - cashBefore, paid, "immediate principal");
        assertEq(ethFarm.waitingSharesOf(bob), 0);
        assertEq(ethFarm.activeShares(), ethFarm.sharesOf(alice), "alice's earning stake untouched");
        assertEq(ethFarm.pendingRewards(bob), 0);
        vm.expectRevert(); // shares are not transferable and nothing is left
        vm.prank(bob);
        ethFarm.withdraw(1);
    }

    /// Everything the farm pulls is eventually claimable by somebody: after random interleavings of deposits,
    /// partial and full exits, claims and certifications, once every account claims, what stays in the
    /// reserve is rounding dust and the cash held equals the reserve.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_pulledRewardsAreFullyDistributedAcrossEpochs(uint256 seed, uint8 rawSteps) public {
        activateWithHistory(0);
        address[3] memory who = [alice, bob, carol];
        uint256 steps = bound(rawSteps, 4, 40);
        uint256 harvests;
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address a = who[r % 3];
            uint256 action = (r >> 8) % 5;
            if (action == 0 || action == 1) {
                depositEth(a, bound(r >> 16, 1e6, 50 ether));
            } else if (action == 2) {
                uint256 held = ethFarm.sharesOf(a);
                if (held == 0) continue;
                uint256 part = (r >> 16) % 2 == 0 ? held : bound(r >> 24, 1, held);
                vm.prank(a);
                ethFarm.withdraw(part);
                ++harvests;
            } else if (action == 3) {
                uint256 promised = ethFarm.pendingRewards(a);
                assertEq(_claim(a), promised, "claim equals promise");
                ++harvests;
            } else {
                advanceBlocks(uint64(bound(r >> 16, 1, 600)));
            }
            assertLe(ethFarm.activeShares(), ethFarm.totalShares(), "active within total");
            for (uint256 k; k < 3; ++k) {
                assertLe(ethFarm.waitingSharesOf(who[k]), ethFarm.sharesOf(who[k]), "waiting within held");
            }
        }
        // Settle everything already certified, then let everybody claim.
        advanceBlocks(5);
        for (uint256 k; k < 3; ++k) {
            uint256 promised = ethFarm.pendingRewards(who[k]);
            assertEq(_claim(who[k]), promised, "final claim equals promise");
        }
        (,,,, uint256 minted) = controller.getPoolAllocation(ethFarm.poolId());
        uint256 claimed = cheese.balanceOf(alice) + cheese.balanceOf(bob) + cheese.balanceOf(carol);
        assertEq(claimed + ethFarm.rewardReserve(), minted, "pulled = claimed + reserve");
        assertEq(cheese.balanceOf(address(ethFarm)), ethFarm.rewardReserve(), "reserve is backed");
        // Each accrual floors and each harvest ceils a debt (two baselines per activation): a few wei per action.
        assertLe(ethFarm.rewardReserve(), 4 * (steps + 3), "pulled rewards stranded beyond rounding dust");
    }
}
