// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseToken} from "src/CheeseToken.sol";
import {CheeseFarm} from "src/CheeseFarm.sol";
import {CheeseFarmERC20} from "src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "src/farms/CheeseFarmSIMD.sol";
import {MockSqueekCore} from "../mocks/MockSqueekCore.sol";

/// @dev Test-only recipient. A broken Treasury must not stop another account's principal withdrawal.
contract SequenceTreasury {
    bool public rejects;

    function setRejects(bool value) external {
        rejects = value;
    }

    receive() external payable {
        require(!rejects, "test Treasury refuses ETH");
    }
}

/// @dev A test asset, never a substitute for the unverified live sIMD address. It mutates balances before
/// returning false to a blocked Treasury, so every deferred payment must roll the mutation back.
contract SequenceAsset is ERC20 {
    mapping(address => bool) public rejects;

    constructor() ERC20("Sequence test asset", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejects(address to, bool value) external {
        rejects[to] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return !rejects[to];
    }
}

/// @notice Closed set of actors and assets, with ghost cash flows measured from actual balance changes.
/// Expected failure paths are checked explicitly. Unexpected reverts fail the invariant campaign.
contract ReserveHandler is Test {
    struct ExitSnapshot {
        uint256 held;
        uint256 shares;
        uint256 principal;
        uint256 userBalance;
        uint256 treasuryBalance;
        uint256 owed;
        uint256 gross;
        uint256 preview;
    }

    CheeseEmissionController public controller;
    CheeseToken public cheese;
    MockSqueekCore public core;
    SequenceAsset public asset;
    CheeseFarm[3] public farms; // 0: CHEESE, 1: ETH, 2: test-only sIMD adapter asset
    SequenceTreasury[2] public treasuries;
    address[4] public actors;
    address public owner;

    uint256[3] public deposited;
    uint256[3] public paidUsers;
    uint256[3] public paidTreasury;
    uint256[3] public donated;
    uint256[3] public skimmed;
    uint256[3] public rewardsPaid;
    uint256 public burned;
    uint256 public successfulDeposits;
    uint256 public successfulWithdrawals;
    uint256 public successfulClaims;
    uint256 public deferredWithdrawals;
    uint256 public failedDeposits;
    uint256 public successfulTreasuryPayments;
    uint256 public lastEmission;
    uint256 public accountingSteps;
    bool public sawCompletion;

    constructor(
        CheeseEmissionController controller_,
        MockSqueekCore core_,
        SequenceAsset asset_,
        SequenceTreasury[2] memory treasuries_,
        address[4] memory actors_
    ) {
        controller = controller_;
        cheese = CheeseToken(controller_.token());
        core = core_;
        asset = asset_;
        owner = controller_.owner();
        treasuries = treasuries_;
        actors = actors_;
        for (uint256 i; i < 3; ++i) {
            (address farm,,,,) = controller_.getPoolAllocation(i);
            farms[i] = CheeseFarm(farm);
        }
    }

    function principalBalance(uint256 kind, address who) public view returns (uint256) {
        if (kind == 0) return cheese.balanceOf(who);
        if (kind == 1) return who.balance;
        return asset.balanceOf(who);
    }

    function treasuryBalance(uint256 kind) public view returns (uint256) {
        return principalBalance(kind, address(treasuries[0])) + principalBalance(kind, address(treasuries[1]));
    }

    function _blocked(uint256 kind) internal view returns (bool) {
        if (kind == 0) return false;
        return SequenceTreasury(payable(controller.treasury())).rejects();
    }

    function _expectPaymentFailure(uint256 kind, uint256 amount) internal {
        if (kind == 1) {
            vm.expectRevert(
                abi.encodeWithSelector(CheeseFarm.NativeTransferFailed.selector, controller.treasury(), amount)
            );
        } else {
            vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(asset)));
        }
    }

    function _observe() internal {
        ++accountingSteps;
        uint256 emission = controller.cumulativeEmission();
        assertGe(emission, lastEmission, "scheduled emission regressed");
        lastEmission = emission;
        if (sawCompletion) assertTrue(controller.completed(), "completed schedule reopened");
        sawCompletion = controller.completed();
    }

    function deposit(uint256 kindSeed, uint256 actorSeed, uint256 rawAmount) public {
        uint256 kind = kindSeed % 3;
        CheeseFarm farm = farms[kind];
        address who = actors[actorSeed % 4];
        uint256 balance = principalBalance(kind, who);
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance > 10_000 ether ? 10_000 ether : balance);
        uint256 sharesBefore = farm.sharesOf(who);
        uint256 assetsBefore = farm.totalAssets();
        uint256 oldPending = sharesBefore == 0 ? farm.pendingRewards(who) : 0;
        bytes4 expectedFailure;
        if (farm.depositsPaused()) expectedFailure = CheeseFarm.DepositsArePaused.selector;
        else if (controller.emissionsPaused()) expectedFailure = CheeseFarm.EmissionsPausedDepositsClosed.selector;
        else if (core.unavailable() && !controller.completed()) expectedFailure = CheeseFarm.SyncRequired.selector;
        else if (farm.convertToShares(amount) == 0) expectedFailure = CheeseFarm.ZeroShares.selector;

        vm.startPrank(who);
        if (kind == 0) cheese.approve(address(farm), amount);
        if (kind == 2) asset.approve(address(farm), amount);
        if (expectedFailure != bytes4(0)) vm.expectRevert(expectedFailure);
        uint256 shares;
        if (kind == 0) shares = CheeseFarmERC20(address(farm)).deposit(amount);
        else if (kind == 1) shares = CheeseFarmETH(payable(address(farm))).deposit{value: amount}();
        else shares = CheeseFarmSIMD(address(farm)).deposit(amount);
        vm.stopPrank();

        if (expectedFailure != bytes4(0)) {
            ++failedDeposits;
            assertEq(farm.sharesOf(who), sharesBefore, "failed deposit changed shares");
            assertEq(farm.totalAssets(), assetsBefore, "failed deposit changed backing");
            assertEq(principalBalance(kind, who), balance, "failed deposit spent principal");
        } else {
            deposited[kind] += balance - principalBalance(kind, who);
            ++successfulDeposits;
            assertGt(shares, 0, "paid for zero shares");
            assertEq(farm.sharesOf(who), sharesBefore + shares);
            assertEq(farm.totalAssets(), assetsBefore + amount, "deposit fee must be zero");
            if (sharesBefore == 0) {
                assertEq(farm.pendingRewards(who), oldPending, "new shares inherited past emission");
            }
        }
        _observe();
    }

    function withdraw(uint256 kindSeed, uint256 actorSeed, uint256 rawShares, bool all) public {
        uint256 kind = kindSeed % 3;
        CheeseFarm farm = farms[kind];
        address who = actors[actorSeed % 4];
        ExitSnapshot memory s;
        s.held = farm.sharesOf(who);
        if (s.held == 0) return;
        s.shares = all ? s.held : bound(rawShares, 1, s.held);
        s.principal = farm.totalAssets();
        s.userBalance = principalBalance(kind, who);
        s.treasuryBalance = treasuryBalance(kind);
        s.owed = farm.treasuryOwed();
        (s.gross, s.preview,,) = farm.previewWithdraw(s.shares);
        vm.prank(who);
        uint256 paid = farm.withdraw(s.shares);
        uint256 actualPaid = principalBalance(kind, who) - s.userBalance;
        uint256 sentTreasury = treasuryBalance(kind) - s.treasuryBalance;
        uint256 deferred = farm.treasuryOwed() - s.owed;
        paidUsers[kind] += actualPaid;
        paidTreasury[kind] += sentTreasury;
        ++successfulWithdrawals;
        if (deferred != 0) ++deferredWithdrawals;
        assertEq(paid, actualPaid, "withdrawal return value differs from cash received");
        assertEq(paid, s.preview, "withdrawal preview changed without a principal change");
        assertEq(s.gross - paid, s.gross * 15 / 100, "15 percent gross withdrawal fee");
        assertEq(farm.sharesOf(who), s.held - s.shares);
        assertEq(s.principal - farm.totalAssets(), actualPaid + sentTreasury + deferred, "principal cash flow");
        if (farm.totalShares() == 0) {
            assertEq(farm.totalAssets(), 0, "last exit leaves no principal");
            assertEq(sentTreasury + deferred, s.principal - paid, "last exit fee and dust belong to Treasury");
        } else {
            assertEq(sentTreasury + deferred, s.gross - paid - s.gross * 14 / 100, "14 percent retained fee");
        }
        _observe();
    }

    function roundTrip(uint256 kindSeed, uint256 actorSeed, uint256 amount) public {
        uint256 kind = kindSeed % 3;
        address who = actors[actorSeed % 4];
        uint256 cashBefore = principalBalance(kind, who);
        uint256 sharesBefore = farms[kind].sharesOf(who);
        deposit(kind, actorSeed, amount);
        uint256 newShares = farms[kind].sharesOf(who) - sharesBefore;
        if (newShares != 0) withdraw(kind, actorSeed, newShares, false);
        assertEq(farms[kind].sharesOf(who), sharesBefore, "round trip changed preexisting shares");
        assertLe(principalBalance(kind, who), cashBefore, "deposit/withdraw manufactured principal");
    }

    function claim(uint256 kindSeed, uint256 actorSeed, uint256 recipientSeed) public {
        uint256 kind = kindSeed % 3;
        CheeseFarm farm = farms[kind];
        address who = actors[actorSeed % 4];
        address recipient = actors[recipientSeed % 4];
        uint256 principal = farm.totalAssets();
        uint256 shares = farm.totalShares();
        uint256 promised = farm.pendingRewards(who);
        uint256 beforeRecipient = cheese.balanceOf(recipient);
        vm.prank(who);
        uint256 paid = farm.claim(recipient);
        assertEq(cheese.balanceOf(recipient) - beforeRecipient, paid, "reward delivery");
        assertEq(paid, promised, "reward reserve must cover the full entitlement");
        assertEq(farm.pendingRewards(who), 0, "claim must consume the entitlement");
        assertEq(farm.totalAssets(), principal, "claim touched principal");
        assertEq(farm.totalShares(), shares, "claim touched shares");
        rewardsPaid[kind] += paid;
        ++successfulClaims;
        _observe();
    }

    function donate(uint256 kindSeed, uint256 actorSeed, uint256 rawAmount) public {
        uint256 kind = kindSeed % 3;
        CheeseFarm farm = farms[kind];
        address who = actors[actorSeed % 4];
        uint256 available = principalBalance(kind, who);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available > 100 ether ? 100 ether : available);
        uint256 principal = farm.totalAssets();
        uint256 price = farm.convertToShares(1 ether);
        uint256 beforeBalance = principalBalance(kind, address(farm));
        if (kind == 1) {
            // Model forced ETH (which bypasses receive); this is explicitly a new external cash inflow.
            vm.deal(address(farm), address(farm).balance + amount);
        } else {
            vm.prank(who);
            if (kind == 0) cheese.transfer(address(farm), amount);
            else asset.transfer(address(farm), amount);
        }
        donated[kind] += principalBalance(kind, address(farm)) - beforeBalance;
        assertEq(farm.totalAssets(), principal, "donation moved accounted principal");
        assertEq(farm.convertToShares(1 ether), price, "donation changed the share price");
    }

    function skim(uint256 kindSeed) public {
        uint256 kind = kindSeed % 3;
        CheeseFarm farm = farms[kind];
        uint256 extra = farm.surplus();
        uint256 beforeTreasury = treasuryBalance(kind);
        uint256 principal = farm.totalAssets();
        uint256 reserve = farm.rewardReserve();
        uint256 owed = farm.treasuryOwed();
        if (extra == 0) vm.expectRevert(CheeseFarm.NothingToSkim.selector);
        else if (_blocked(kind)) _expectPaymentFailure(kind, extra);
        vm.prank(owner);
        farm.skimSurplus();
        uint256 received = treasuryBalance(kind) - beforeTreasury;
        skimmed[kind] += received;
        if (extra != 0 && !_blocked(kind)) assertEq(received, extra, "skim delivered only surplus");
        else assertEq(received, 0, "failed skim moved funds");
        assertEq(farm.totalAssets(), principal);
        assertEq(farm.rewardReserve(), reserve);
        assertEq(farm.treasuryOwed(), owed, "skim touched deferred fees");
    }

    function payTreasury(uint256 kindSeed) public {
        uint256 kind = kindSeed % 3;
        CheeseFarm farm = farms[kind];
        uint256 amount = farm.treasuryOwed();
        uint256 beforeTreasury = treasuryBalance(kind);
        if (amount == 0) vm.expectRevert(CheeseFarm.NothingOwedToTreasury.selector);
        else if (_blocked(kind)) _expectPaymentFailure(kind, amount);
        farm.payTreasury();
        uint256 received = treasuryBalance(kind) - beforeTreasury;
        paidTreasury[kind] += received;
        if (amount != 0 && !_blocked(kind)) {
            assertEq(received, amount, "fee payment did not arrive");
            assertEq(farm.treasuryOwed(), 0);
            ++successfulTreasuryPayments;
        } else {
            assertEq(received, 0);
            assertEq(farm.treasuryOwed(), amount, "failed fee payment lost liability");
        }
    }

    function rotateTreasury(bool second, bool broken) public {
        SequenceTreasury recipient = treasuries[second ? 1 : 0];
        recipient.setRejects(broken);
        asset.setRejects(address(recipient), broken);
        vm.prank(owner);
        controller.setTreasury(address(recipient));
    }

    function burn(uint256 actorSeed, uint256 rawAmount, bool all) public {
        address who = actors[actorSeed % 4];
        uint256 balance = cheese.balanceOf(who);
        uint256 amount = all ? balance : bound(rawAmount, 0, balance);
        uint256 minted = cheese.totalMinted();
        uint256 supply = cheese.totalSupply();
        vm.prank(who);
        cheese.burn(amount);
        burned += amount;
        assertEq(cheese.totalMinted(), minted, "burn reopened lifetime allowance");
        assertEq(cheese.totalSupply(), supply - amount);
    }

    function transfer(uint256 actorSeed, uint256 recipientSeed, uint256 rawAmount) public {
        address who = actors[actorSeed % 4];
        address recipient = actors[recipientSeed % 4];
        uint256 amount = bound(rawAmount, 0, cheese.balanceOf(who));
        uint256 supply = cheese.totalSupply();
        uint256 beforeTotal = cheese.balanceOf(who) + (who == recipient ? 0 : cheese.balanceOf(recipient));
        vm.prank(who);
        cheese.transfer(recipient, amount);
        assertEq(cheese.balanceOf(who) + (who == recipient ? 0 : cheese.balanceOf(recipient)), beforeTotal);
        assertEq(cheese.totalSupply(), supply);
    }

    function advance(uint32 blocks_) public {
        core.settle(core.settledThroughRound() + 1, uint64(bound(blocks_, 0, 60_000)), 0);
    }

    function checkpoint() public {
        controller.checkpoint();
        _observe();
    }

    function outage(bool unavailable) public {
        core.setUnavailable(unavailable);
    }

    function pause(bool emissionPause, uint256 kindSeed, bool value) public {
        vm.startPrank(owner);
        if (!emissionPause) {
            farms[kindSeed % 3].setDepositsPaused(value);
        } else if (controller.emissionsPaused() != value) {
            if (value) controller.pauseEmissions();
            else controller.unpauseEmissions();
        }
        vm.stopPrank();
        _observe();
    }

    function reweight(uint256 kindSeed, uint16 rawWeight) public {
        uint256 id = kindSeed % 3;
        (, uint16 previous,,,) = controller.getPoolAllocation(id);
        uint16 weight = uint16(bound(rawWeight, 0, 1000 - controller.totalWeight() + previous));
        if (controller.emissionsPaused()) {
            vm.expectRevert(CheeseEmissionController.EmissionsArePaused.selector);
        } else if (core.unavailable() && !controller.completed()) {
            vm.expectRevert(CheeseEmissionController.SyncRequired.selector);
        }
        vm.prank(owner);
        controller.setPoolWeight(id, weight);
        _observe();
    }

    function togglePool(uint256 kindSeed, bool enable) public {
        uint256 id = kindSeed % 3;
        (,, bool enabled,,) = controller.getPoolAllocation(id);
        if (enable == enabled) return;
        if (controller.emissionsPaused()) {
            vm.expectRevert(CheeseEmissionController.EmissionsArePaused.selector);
        } else if (core.unavailable() && !controller.completed()) {
            vm.expectRevert(CheeseEmissionController.SyncRequired.selector);
        }
        vm.prank(owner);
        if (enable) controller.enablePool(id);
        else controller.disablePool(id);
        _observe();
    }

    /// @dev Called only by afterInvariant, excluded from random selectors. Proves that every generated
    /// state can exit in full during a Core outage AND a refusing Treasury, then settle fees after repair.
    function closeAll() external {
        core.setUnavailable(true);
        rotateTreasury(false, true);
        for (uint256 kind; kind < 3; ++kind) {
            for (uint256 actor; actor < 4; ++actor) {
                withdraw(kind, actor, 0, true);
                claim(kind, actor, actor);
            }
            assertEq(farms[kind].totalShares(), 0);
            assertEq(farms[kind].totalAssets(), 0);
        }
        rotateTreasury(true, false);
        for (uint256 kind; kind < 3; ++kind) {
            payTreasury(kind);
            skim(kind);
            assertEq(farms[kind].treasuryOwed(), 0);
            assertEq(farms[kind].surplus(), 0);
        }
    }
}
