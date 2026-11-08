// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CheeseBase} from "../CheeseBase.t.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarm} from "src/CheeseFarm.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "src/farms/CheeseFarmSIMD.sol";

contract RegistrationFailureProbe {
    address public immutable emissionController;
    bool public registered;
    bool public reject = true;
    uint256 public poolId;
    error RegistrationRejected();

    constructor(address controller) {
        emissionController = controller;
    }

    function allowRegistration() external {
        reject = false;
    }

    function onPoolRegistered(uint256 id) external {
        require(msg.sender == emissionController);
        if (reject) revert RegistrationRejected();
        registered = true;
        poolId = id;
    }
}

contract PrincipalReceiverProbe {
    CheeseFarmETH public immutable farm;
    bool public accepts;

    constructor(CheeseFarmETH farm_) {
        farm = farm_;
    }

    function deposit() external payable {
        farm.deposit{value: msg.value}();
    }

    function allowReceipt() external {
        accepts = true;
    }

    function withdrawAll() external returns (uint256) {
        return farm.withdraw(farm.sharesOf(address(this)));
    }

    function claim() external returns (uint256) {
        return farm.claim(address(this));
    }

    receive() external payable {
        require(accepts, "test user refuses ETH");
    }
}

contract FailedPullAsset is ERC20 {
    bool public reject = true;

    constructor(address recipient) ERC20("Failed pull test asset", "TEST") {
        _mint(recipient, 100 ether);
    }

    function allowPull() external {
        reject = false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return !reject;
    }
}

/// @notice Error paths must roll back every affected contract, not just throw the right error.
contract AtomicRollbackTest is CheeseBase {
    function _controllerState() internal view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                controller.lastHeight(),
                controller.cumulativeEmission(),
                controller.emissionPerPoint(),
                controller.reserveUnminted(),
                controller.totalMinted(),
                controller.forfeitedEmission(),
                controller.activeWeight(),
                controller.totalWeight(),
                controller.poolCount(),
                cheese.totalSupply()
            )
        );
        for (uint256 i; i < controller.poolCount(); ++i) {
            (address farm, uint16 weight, bool enabled, uint256 pending, uint256 minted) =
                controller.getPoolAllocation(i);
            state = keccak256(abi.encode(state, farm, weight, enabled, pending, minted));
        }
    }

    function test_failedBatchRollsBackCheckpointAndEarlierWeightReductions() public {
        activateWithHistory(700);
        depositEth(alice, 1 ether);
        advanceBlocks(40);
        bytes32 beforeState = _controllerState();
        uint256[] memory ids = new uint256[](3);
        uint16[] memory weights = new uint16[](3);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = 2;
        weights[0] = 0;
        weights[1] = 1000;
        weights[2] = 1;
        // Reductions to 0 and 1 happen first; the final increase would allocate 1001 points.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.WeightExceedsTotal.selector, 1000, 999));
        controller.batchSetPoolWeights(ids, weights);
        assertEq(_controllerState(), beforeState, "failed batch leaked its checkpoint or partial weights");
        (bool readable,, uint256 pending) = controller.pendingCheckpoint();
        assertTrue(readable);
        assertGt(pending, 0, "failed transaction consumed certified emission");
        (bool synced, uint256 emitted) = controller.checkpoint();
        assertTrue(synced);
        assertEq(emitted, pending, "subsequent checkpoint must still price the full interval");
    }

    function test_failedRegistrationDoesNotReserveIndexPointsOrCheckpoint() public {
        activateWithHistory(0);
        advanceBlocks(40);
        RegistrationFailureProbe candidate = new RegistrationFailureProbe(address(controller));
        bytes32 beforeState = _controllerState();
        vm.prank(owner);
        vm.expectRevert(RegistrationFailureProbe.RegistrationRejected.selector);
        controller.addPool(address(candidate), 100);
        assertEq(_controllerState(), beforeState);
        assertFalse(candidate.registered());
        vm.expectRevert(abi.encodeWithSelector(CheeseEmissionController.PoolNotFound.selector, type(uint256).max));
        controller.poolIdOf(address(candidate));
        candidate.allowRegistration();
        vm.prank(owner);
        assertEq(controller.addPool(address(candidate), 100), 3);
        assertEq(candidate.poolId(), 3);
        assertEq(controller.poolIdOf(address(candidate)), 3);
        (,,, uint256 pending,) = controller.getPoolAllocation(3);
        assertEq(pending, 0, "new registration inherited the failed attempt's historical interval");
    }

    function test_refusingUserRollsBackMintFeesAndSharesWithoutBlockingOtherUsers() public {
        activateWithHistory(0);
        PrincipalReceiverProbe receiver = new PrincipalReceiverProbe(ethFarm);
        vm.deal(address(this), 5 ether);
        receiver.deposit{value: 5 ether}();
        depositEth(bob, 5 ether);
        advanceBlocks(40);
        bytes32 beforeState = _controllerState();
        uint256 beforeTreasury = treasury.balance;
        uint256 shares = ethFarm.sharesOf(address(receiver));
        vm.expectRevert(abi.encodeWithSelector(CheeseFarm.NativeTransferFailed.selector, address(receiver), 4.25 ether));
        receiver.withdrawAll();
        assertEq(_controllerState(), beforeState, "failed payout must undo the reward mint and checkpoint");
        assertEq(ethFarm.sharesOf(address(receiver)), shares);
        assertEq(ethFarm.totalAssets(), 10 ether);
        assertEq(address(ethFarm).balance, 10 ether);
        assertEq(treasury.balance, beforeTreasury, "Treasury push before user payout must also roll back");
        assertEq(ethFarm.rewardReserve(), 0);
        assertEq(cheese.balanceOf(address(ethFarm)), 0);
        assertEq(ethFarm.accRewardPerShare(), 0);
        assertEq(withdrawAll(ethFarm, bob), 4.25 ether, "other users still have immediate withdrawals");
        receiver.allowReceipt();
        assertGt(receiver.withdrawAll(), 4.25 ether, "remaining user receives retained fee compounding");
        uint256 expected = ethFarm.pendingRewards(address(receiver));
        assertGt(expected, 0);
        assertEq(receiver.claim(), expected);
        assertEq(receiver.claim(), 0, "retry must not duplicate the failed mint");
        assertEq(ethFarm.totalShares(), 0);
        assertEq(ethFarm.totalAssets(), 0);
    }

    function test_falseTransferFromRollsBackAllowanceBalancesAndForfeiture() public {
        FailedPullAsset token = new FailedPullAsset(alice);
        CheeseFarmSIMD farm = new CheeseFarmSIMD(owner, address(controller));
        vm.startPrank(owner);
        farm.setAsset(address(token));
        controller.addPool(address(farm), 100);
        vm.stopPrank();
        activateWithHistory(0);
        advanceBlocks(40);
        bytes32 beforeState = _controllerState();
        vm.startPrank(alice);
        token.approve(address(farm), 100 ether);
        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(token)));
        farm.deposit(100 ether);
        vm.stopPrank();
        assertEq(_controllerState(), beforeState, "failed deposit consumed forfeitable emission");
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(farm)), 0);
        assertEq(token.allowance(alice, address(farm)), 100 ether);
        assertEq(farm.totalAssets(), 0);
        assertEq(farm.totalShares(), 0);
        assertEq(farm.pendingRewards(alice), 0);
        token.allowPull();
        vm.prank(alice);
        farm.deposit(100 ether);
        assertEq(farm.totalAssets(), 100 ether);
        assertEq(farm.pendingRewards(alice), 0, "retry must not inherit past emission");
        assertGt(controller.forfeitedEmission(), 0);
        assertEq(controller.totalMinted(), 0);
    }
}
