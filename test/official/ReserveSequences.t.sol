// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseFarm} from "src/CheeseFarm.sol";
import {CheeseFarmERC20} from "src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "src/farms/CheeseFarmSIMD.sol";
import {MockSqueekCore} from "../mocks/MockSqueekCore.sol";
import {ReserveHandler, SequenceAsset, SequenceTreasury} from "./ReserveHandler.sol";

/// @notice Local custody simulation only. The official deployment rehearsal keeps sIMD unconfigured.
/// These test doubles exercise failure and recovery without requiring network access or live assets.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ReserveSequencesTest is Test {
    address internal constant OWNER = 0xDEA11b3A70b77134424d436f6eb455f1Abbd4449;
    uint64 internal constant GENESIS = 1_793_735_400;
    CheeseEmissionController internal controller;
    CheeseToken internal cheese;
    CheeseFarm[3] internal farms;
    MockSqueekCore internal core;
    SequenceAsset internal asset;
    SequenceTreasury[2] internal treasuries;
    address[4] internal actors;
    ReserveHandler internal handler;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.warp(GENESIS + 600);
        core = new MockSqueekCore(GENESIS);
        asset = new SequenceAsset();
        treasuries[0] = new SequenceTreasury();
        treasuries[1] = new SequenceTreasury();
        controller = new CheeseEmissionController(OWNER, address(core), OWNER);
        cheese = new CheeseToken(OWNER, OWNER, OWNER, address(controller));
        farms[0] = new CheeseFarmERC20(OWNER, address(controller), address(cheese));
        farms[1] = new CheeseFarmETH(OWNER, address(controller));
        farms[2] = new CheeseFarmSIMD(OWNER, address(controller));
        vm.startPrank(OWNER);
        controller.bindToken(address(cheese));
        controller.addPool(address(farms[0]), 400);
        controller.addPool(address(farms[1]), 200);
        controller.addPool(address(farms[2]), 200);
        CheeseFarmSIMD(address(farms[2])).setAsset(address(asset));
        controller.setTreasury(address(treasuries[0]));
        controller.activate();
        vm.stopPrank();
        core.settle(controller.startRound() - 1, 43, 0);
        controller.checkpoint();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("reserve-sequence-actor-", vm.toString(i)));
            vm.deal(actors[i], 1_000_000 ether);
            asset.mint(actors[i], 1_000_000 ether);
            vm.prank(OWNER);
            cheese.transfer(actors[i], 1_000_000 ether);
        }
        handler = new ReserveHandler(controller, core, asset, treasuries, actors);
        for (uint256 kind; kind < 3; ++kind) {
            for (uint256 actor; actor < 4; ++actor) {
                handler.deposit(kind, actor, (actor + 1) * 1 ether);
            }
        }
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.skim.selector;
        selectors[5] = handler.payTreasury.selector;
        selectors[6] = handler.rotateTreasury.selector;
        selectors[7] = handler.burn.selector;
        selectors[8] = handler.transfer.selector;
        selectors[9] = handler.advance.selector;
        selectors[10] = handler.checkpoint.selector;
        selectors[11] = handler.outage.selector;
        selectors[12] = handler.pause.selector;
        selectors[13] = handler.reweight.selector;
        selectors[14] = handler.togglePool.selector;
        selectors[15] = handler.withdraw.selector; // deliberately emphasize full/partial exits
        selectors[16] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_allAssetAndRewardLiabilitiesAreBacked() public view {
        for (uint256 kind; kind < 3; ++kind) {
            CheeseFarm farm = farms[kind];
            assertEq(
                handler.deposited(kind),
                farm.totalAssets() + farm.treasuryOwed() + handler.paidUsers(kind) + handler.paidTreasury(kind),
                "principal deposits = remaining principal + deferred fees + actual outgoing cash"
            );
            uint256 surplus = handler.donated(kind) - handler.skimmed(kind);
            assertEq(farm.surplus(), surplus, "only tracked donations are skimmable");
            uint256 reserve = farm.totalAssets() + farm.treasuryOwed() + surplus;
            if (kind == 0) reserve += farm.rewardReserve();
            assertEq(handler.principalBalance(kind, address(farm)), reserve, "all custody has an accounting owner");
            if (kind != 0) assertEq(cheese.balanceOf(address(farm)), farm.rewardReserve(), "separate reward backing");

            uint256 shares;
            uint256 principalOwed;
            uint256 rewardsOwed;
            uint256 claimed;
            for (uint256 i; i < actors.length; ++i) {
                shares += farm.sharesOf(actors[i]);
                principalOwed += farm.assetsOf(actors[i]);
                rewardsOwed += farm.pendingRewards(actors[i]);
                claimed += farm.claimedOf(actors[i]);
            }
            assertEq(shares, farm.totalShares(), "no unowned or duplicated shares");
            assertLe(principalOwed, farm.totalAssets(), "gross principal claims exceed backing");
            assertLe(rewardsOwed, farm.rewardReserve() + controller.previewPoolEmission(kind), "reward insolvency");
            assertEq(claimed, handler.rewardsPaid(kind), "claim accounting must equal actual rewards delivered");
            (,,,, uint256 minted) = controller.getPoolAllocation(kind);
            assertEq(minted, farm.rewardReserve() + handler.rewardsPaid(kind), "minted rewards are held or paid");
            if (shares == 0) assertEq(farm.totalAssets(), 0, "empty farm kept principal dust");
        }
    }

    function invariant_lifetimeSupplyAndEmissionAllocationAreConserved() public view {
        uint256 heldCheese = cheese.balanceOf(OWNER);
        uint256 heldAsset;
        for (uint256 i; i < actors.length; ++i) {
            heldCheese += cheese.balanceOf(actors[i]);
            heldAsset += asset.balanceOf(actors[i]);
        }
        for (uint256 i; i < treasuries.length; ++i) {
            heldCheese += cheese.balanceOf(address(treasuries[i]));
            heldAsset += asset.balanceOf(address(treasuries[i]));
        }
        uint256 totalPoolMinted;
        uint256 totalPoolPending;
        uint256 activeWeight;
        uint256 disabledWeight;
        for (uint256 i; i < farms.length; ++i) {
            heldCheese += cheese.balanceOf(address(farms[i]));
            heldAsset += asset.balanceOf(address(farms[i]));
            (, uint16 weight, bool enabled, uint256 pending, uint256 minted) = controller.getPoolAllocation(i);
            totalPoolMinted += minted;
            totalPoolPending += pending;
            if (enabled) activeWeight += weight;
            else disabledWeight += weight;
        }
        assertEq(cheese.totalSupply(), heldCheese, "CHEESE supply is the sum of all real balances");
        assertEq(asset.totalSupply(), heldAsset, "test asset cannot disappear on a false transfer return");
        assertEq(cheese.totalBurned(), handler.burned());
        assertEq(cheese.totalSupply() + handler.burned(), cheese.totalMinted());
        assertEq(cheese.totalMinted(), 210_000_000e18 + controller.totalMinted());
        assertLe(cheese.totalMinted(), 2_100_000_000e18);
        assertEq(totalPoolMinted, controller.totalMinted());
        uint256 accounted =
            totalPoolMinted + totalPoolPending + controller.reserveUnminted() + controller.forfeitedEmission();
        assertLe(accounted, controller.cumulativeEmission(), "allocated more than scheduled");
        // At most one reserve floor and one pool-settlement floor per handler action, plus the three
        // unsettled pool floors. A generous four wei/action bounds dust without hiding missing emission.
        assertLe(
            controller.cumulativeEmission() - accounted,
            4 * (handler.accountingSteps() + 1),
            "unexplained emission loss"
        );
        assertLe(controller.cumulativeEmission(), 1_890_000_000e18);
        (uint16 active, uint16 disabled, uint16 future) = controller.getAllocation();
        assertEq(active, activeWeight);
        assertEq(disabled, disabledWeight);
        assertEq(activeWeight + disabledWeight + future, 1000);
    }

    function afterInvariant() public {
        handler.closeAll();
        invariant_allAssetAndRewardLiabilitiesAreBacked();
        invariant_lifetimeSupplyAndEmissionAllocationAreConserved();
    }

    function test_seededSequenceExercisesDeferredPaymentOutageAndRecovery() public {
        handler.advance(40);
        handler.checkpoint();
        handler.rotateTreasury(false, true);
        handler.outage(true);
        handler.deposit(1, 0, 1 ether);
        handler.withdraw(1, 0, 0, true);
        handler.withdraw(2, 0, 0, true);
        assertEq(handler.failedDeposits(), 1);
        assertEq(handler.deferredWithdrawals(), 2);
        handler.payTreasury(1);
        handler.payTreasury(2);
        handler.donate(2, 1, 1 ether);
        handler.skim(2);
        handler.claim(2, 0, 3);
        assertGt(handler.rewardsPaid(2), 0, "outage must preserve already accrued rewards");
        handler.rotateTreasury(true, false);
        handler.payTreasury(1);
        handler.payTreasury(2);
        assertEq(handler.successfulTreasuryPayments(), 2);
        handler.skim(2);
        handler.outage(false);
        handler.advance(13);
        handler.deposit(2, 0, 2 ether);
        handler.burn(0, 1 ether, false);
        handler.transfer(1, 0, 1 ether);
        invariant_allAssetAndRewardLiabilitiesAreBacked();
        invariant_lifetimeSupplyAndEmissionAllocationAreConserved();
        afterInvariant();
    }

    function test_completedScheduleSurvivesBurnAndOutageWithoutReopening() public {
        core.settle(core.settledThroughRound() + 1, 2_000_000, 0);
        handler.checkpoint();
        assertTrue(controller.completed());
        uint256 finalEmission = controller.cumulativeEmission();
        handler.claim(0, 0, 0);
        handler.burn(0, 0, true);
        handler.outage(true);
        handler.deposit(1, 0, 1 ether);
        handler.checkpoint();
        assertEq(controller.cumulativeEmission(), finalEmission);
        afterInvariant();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_repeatedRoundTripsNeverCreatePrincipal(uint8 kindSeed, uint96 amount, uint8 repetitions) public {
        uint256 kind = kindSeed % 3;
        uint256 balanceBefore = handler.principalBalance(kind, actors[0]);
        uint256 sharesBefore = farms[kind].sharesOf(actors[0]);
        uint256 count = bound(repetitions, 1, 32);
        for (uint256 i; i < count; ++i) {
            handler.roundTrip(kind, 0, amount);
        }
        assertLe(handler.principalBalance(kind, actors[0]), balanceBefore);
        assertEq(farms[kind].sharesOf(actors[0]), sharesBefore);
        assertEq(handler.successfulDeposits(), 12 + count, "round trips must exercise successful deposits");
        assertEq(handler.successfulWithdrawals(), count, "round trips must exercise successful withdrawals");
        invariant_allAssetAndRewardLiabilitiesAreBacked();
        invariant_lifetimeSupplyAndEmissionAllocationAreConserved();
    }

    function test_oneWeiAndMaximumGeneratedRoundTripsAcrossAllAdapters() public {
        for (uint256 kind; kind < 3; ++kind) {
            handler.roundTrip(kind, 0, 1);
            handler.roundTrip(kind, 1, type(uint256).max);
        }
        assertEq(handler.successfulWithdrawals(), 6);
        afterInvariant();
    }
}
