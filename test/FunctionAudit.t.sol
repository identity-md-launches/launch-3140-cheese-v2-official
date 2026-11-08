// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheeseBase} from "./CheeseBase.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CheeseToken} from "../src/CheeseToken.sol";
import {CheeseEmissionController} from "../src/CheeseEmissionController.sol";
import {CheeseFarm} from "../src/CheeseFarm.sol";
import {CheeseFarmERC20} from "../src/farms/CheeseFarmERC20.sol";
import {CheeseFarmETH} from "../src/farms/CheeseFarmETH.sol";
import {CheeseFarmSIMD} from "../src/farms/CheeseFarmSIMD.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";

contract FunctionAuditTest is CheeseBase {
    function test_SkimSurplusETHAndSIMDPreservesReserves() public {
        depositEth(alice, 1 ether); depositSimd(alice, 100);
        vm.deal(address(this), 1 ether);
        new ForceDonation{value: 1 ether}(payable(address(ethFarm)));
        simd.mint(address(simdFarm), 17);
        uint256 oldETH=treasury.balance; uint256 oldSIMD=simd.balanceOf(treasury);
        assertEq(ethFarm.surplus(),1 ether); assertEq(simdFarm.surplus(),17);
        vm.prank(owner); ethFarm.skimSurplus();
        vm.prank(owner); simdFarm.skimSurplus();
        assertEq(treasury.balance-oldETH,1 ether); assertEq(simd.balanceOf(treasury)-oldSIMD,17);
        assertEq(ethFarm.totalAssets(),1 ether); assertEq(simdFarm.totalAssets(),100);
        assertEq(ethFarm.surplus(),0); assertEq(simdFarm.surplus(),0);
        vm.prank(owner); vm.expectRevert(); ethFarm.skimSurplus();
        vm.prank(owner); vm.expectRevert(); simdFarm.skimSurplus();
    }
    function test_ZeroReceivedAndMaximumInputBoundaries() public {
        vm.mockCall(address(simd),abi.encodeWithSignature("transferFrom(address,address,uint256)",alice,address(simdFarm),1),abi.encode(true));
        vm.prank(alice); vm.expectRevert(CheeseFarm.ZeroShares.selector); simdFarm.deposit(1);
        vm.clearMockedCalls();
        CheeseFarm[3] memory ff=farms();
        for(uint256 i;i<3;++i){
            vm.prank(alice); vm.expectRevert(); ff[i].withdraw(type(uint256).max);
            vm.expectRevert(); ff[i].previewWithdraw(type(uint256).max);
            vm.expectRevert(); ff[i].convertToShares(type(uint256).max);
            assertEq(ff[i].convertToAssets(type(uint256).max),type(uint256).max/1000);
            assertEq(ff[i].pendingRewards(address(0)),0);
        }
        vm.prank(alice); vm.expectRevert(); cheeseFarm.deposit(type(uint256).max);
        vm.prank(alice); vm.expectRevert(); simdFarm.deposit(type(uint256).max);
        vm.expectRevert(); cheese.transferFrom(address(0),bob,0);
    }
    function test_UnreadableAnchorPreviewAndMalformedConfiguration() public {
        vm.prank(owner); controller.activate();
        (bool beforeReadable,uint64 beforeHeight,uint256 beforeEmission)=controller.pendingCheckpoint();
        assertTrue(beforeReadable); assertEq(beforeHeight,0); assertEq(beforeEmission,0);
        uint64 anchor=controller.startRound()-1; core.settle(anchor,100,0);
        vm.mockCallRevert(address(core),abi.encodeWithSelector(core.roundPage.selector,anchor,anchor,uint256(0)),hex"aa");
        (bool ok,,uint256 emission)=controller.pendingCheckpoint(); assertFalse(ok); assertEq(emission,0);
        vm.clearMockedCalls();
        CheeseEmissionController other=new CheeseEmissionController(owner,address(core),treasury);
        CheeseToken t=new CheeseToken(team,treasury,liquidity,address(other));
        vm.prank(owner); other.bindToken(address(t));
        bytes memory invalidPayload=abi.encode(core.configuration());
        assembly { mstore(add(invalidPayload,64),not(0)) }
        vm.mockCall(address(core),abi.encodeWithSelector(core.configuration.selector),invalidPayload);
        vm.prank(owner); vm.expectRevert(CheeseEmissionController.SqueekCoreUnavailable.selector); other.activate();
        assertFalse(other.activated());
    }
    function farms() internal view returns (CheeseFarm[3] memory f) {
        f = [CheeseFarm(address(cheeseFarm)), CheeseFarm(address(ethFarm)), CheeseFarm(address(simdFarm))];
    }
    function test_AllConstructorZeroArguments() public {
        vm.expectRevert(); new CheeseEmissionController(address(0), address(core), treasury);
        vm.expectRevert(); new CheeseEmissionController(owner, address(0), treasury);
        vm.expectRevert(); new CheeseEmissionController(owner, address(core), address(0));
        vm.expectRevert(); new CheeseToken(team, address(0), liquidity, address(controller));
        vm.expectRevert(); new CheeseToken(team, treasury, address(0), address(controller));
        vm.expectRevert(); new CheeseFarmERC20(address(0), address(controller), address(cheese));
        vm.expectRevert(); new CheeseFarmERC20(owner, address(0), address(cheese));
        vm.expectRevert(); new CheeseFarmERC20(owner, address(controller), address(0));
        vm.expectRevert(); new CheeseFarmETH(address(0), address(controller));
        vm.expectRevert(); new CheeseFarmETH(owner, address(0));
        vm.expectRevert(); new CheeseFarmSIMD(address(0), address(controller));
        vm.expectRevert(); new CheeseFarmSIMD(owner, address(0));
    }
    function test_AllOwnershipAcceptCancelRenounceAndUnauthorized() public {
        Ownable2Step[4] memory targets = [Ownable2Step(address(controller)), Ownable2Step(address(cheeseFarm)), Ownable2Step(address(ethFarm)), Ownable2Step(address(simdFarm))];
        for (uint256 i; i < targets.length; ++i) {
            Ownable2Step t = targets[i];
            assertEq(t.owner(), owner); assertEq(t.pendingOwner(), address(0));
            vm.prank(alice); vm.expectRevert(); t.transferOwnership(bob);
            vm.prank(alice); vm.expectRevert(); t.renounceOwnership();
            vm.prank(alice); vm.expectRevert(); t.acceptOwnership();
            vm.prank(owner); t.transferOwnership(alice); assertEq(t.pendingOwner(), alice);
            vm.prank(owner); t.transferOwnership(address(0)); assertEq(t.pendingOwner(), address(0));
            vm.prank(alice); vm.expectRevert(); t.acceptOwnership();
            vm.prank(owner); t.transferOwnership(bob);
            vm.prank(bob); t.acceptOwnership(); assertEq(t.owner(), bob); assertEq(t.pendingOwner(), address(0));
            vm.prank(owner); vm.expectRevert(); t.transferOwnership(alice);
            vm.prank(bob); t.renounceOwnership(); assertEq(t.owner(), address(0));
        }
        // Role separation: transferring/renouncing ownership does not silently replace the guardian.
        assertEq(controller.guardian(), owner);
    }
    function test_ERC20TransfersApprovalsFailuresAndInfiniteAllowance() public {
        giveCheese(alice, 10 ether);
        vm.startPrank(alice);
        assertTrue(cheese.transfer(bob, 0));
        assertTrue(cheese.transfer(alice, 1 ether)); assertEq(cheese.balanceOf(alice), 10 ether);
        vm.expectRevert(); cheese.transfer(address(0), 0);
        vm.expectRevert(); cheese.transfer(bob, type(uint256).max);
        vm.expectRevert(); cheese.approve(address(0), 1);
        cheese.approve(bob, 2 ether); assertEq(cheese.allowance(alice, bob), 2 ether);
        vm.stopPrank();
        vm.prank(carol); vm.expectRevert(); cheese.transferFrom(alice, carol, 1);
        vm.prank(bob); assertTrue(cheese.transferFrom(alice, bob, 1 ether));
        assertEq(cheese.allowance(alice, bob), 1 ether);
        vm.prank(alice); cheese.approve(bob, type(uint256).max);
        vm.prank(bob); cheese.transferFrom(alice, bob, 1 ether);
        assertEq(cheese.allowance(alice, bob), type(uint256).max);
        vm.prank(bob); vm.expectRevert(); cheese.transferFrom(alice, address(0), 1);
        vm.prank(alice); cheese.approve(bob, 0);
        vm.prank(bob); vm.expectRevert(); cheese.transferFrom(alice, bob, 1);
        vm.prank(alice); cheese.burn(0);
        vm.prank(alice); vm.expectRevert(); cheese.burn(type(uint256).max);
        vm.prank(address(controller)); cheese.mintEmission(alice, 0);
        assertEq(cheese.totalMinted(), cheese.PREMINT());
    }
    function permitSignature(uint256 key, address account, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", cheese.DOMAIN_SEPARATOR(), keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), account, spender, value, nonce, deadline
        ))));
        // Artificial, deterministic local test key; never a user wallet or transaction signature.
        return vm.sign(key, digest);
    }
    function test_PermitSuccessDeadlineBoundaryReplayInvalidAndDomain() public {
        address account = vm.addr(0xA11CE);
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = permitSignature(0xA11CE, account, bob, type(uint256).max, 0, deadline);
        cheese.permit(account, bob, type(uint256).max, deadline, v, r, s);
        assertEq(cheese.nonces(account), 1); assertEq(cheese.allowance(account, bob), type(uint256).max);
        vm.expectRevert(); cheese.permit(account, bob, type(uint256).max, deadline, v, r, s);
        assertEq(cheese.nonces(account), 1);
        vm.expectRevert(); cheese.permit(account, bob, 0, block.timestamp - 1, 27, 0, 0);
        vm.expectRevert(); cheese.permit(account, bob, 0, deadline, 0, 0, 0);
        (v,r,s) = permitSignature(0xB0B, account, bob, 1, 1, deadline);
        vm.expectRevert(); cheese.permit(account, bob, 1, deadline, v, r, s);
        (v,r,s) = permitSignature(0xA11CE, account, address(0), 1, 1, deadline);
        vm.expectRevert(); cheese.permit(account, address(0), 1, deadline, v, r, s);
        assertEq(cheese.nonces(account), 1);
        {
        (bytes1 fields,string memory name,string memory version,uint256 chain,address verifier,bytes32 salt,uint256[] memory extensions)=cheese.eip712Domain();
        assertEq(fields, hex"0f"); assertEq(name,"CHEESE"); assertEq(version,"1"); assertEq(chain,block.chainid);
        assertEq(verifier,address(cheese)); assertEq(salt,bytes32(0)); assertEq(extensions.length,0);
        }
        bytes32 oldDomain=cheese.DOMAIN_SEPARATOR(); vm.chainId(block.chainid+1); assertTrue(cheese.DOMAIN_SEPARATOR()!=oldDomain);
        (v,r,s) = permitSignature(0xA11CE, account, bob, 0, 1, deadline);
        cheese.permit(account,bob,0,deadline,v,r,s); assertEq(cheese.nonces(account),2); assertEq(cheese.allowance(account,bob),0);
    }
    function test_PermitRejectsHighS() public {
        address account=vm.addr(0xA11CE); uint256 deadline=block.timestamp;
        (uint8 v,bytes32 r,bytes32 s)=permitSignature(0xA11CE,account,bob,1,0,deadline);
        bytes32 highS=bytes32(uint256(0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141)-uint256(s));
        vm.expectRevert(); cheese.permit(account,bob,1,deadline,v==27?28:27,r,highS);
        assertEq(cheese.nonces(account),0);
    }
    function test_AllFarmAdminAndViewsBeforeAndAfterDeposits() public {
        CheeseFarm[3] memory ff=farms();
        for(uint256 i;i<3;++i){
            CheeseFarm f=ff[i];
            assertEq(f.emissionController(),address(controller)); assertEq(address(f.cheese()),address(cheese));
            assertTrue(f.registered()); assertEq(f.poolId(),i); assertEq(f.surplus(),0);
            assertEq(f.assetsOf(alice),0); assertEq(f.convertToShares(1),1000); assertEq(f.convertToAssets(1000),1);
            assertEq(f.pendingRewards(alice),0); assertEq(f.claimedOf(alice),0);
            (uint256 gross,uint256 paid,uint256 retained,uint256 fee)=f.previewWithdraw(0);
            assertEq(gross+paid+retained+fee,0);
            vm.prank(alice); vm.expectRevert(); f.setDepositsPaused(true);
            vm.prank(alice); vm.expectRevert(); f.skimSurplus();
            vm.prank(owner); vm.expectRevert(); f.skimSurplus();
            vm.prank(owner); f.setDepositsPaused(true); assertTrue(f.depositsPaused());
            vm.prank(owner); f.setDepositsPaused(true);
            vm.prank(owner); f.setDepositsPaused(false); assertFalse(f.depositsPaused());
            vm.prank(alice); vm.expectRevert(); f.onPoolRegistered(5);
            vm.prank(address(controller)); vm.expectRevert(); f.onPoolRegistered(5);
            vm.prank(alice); vm.expectRevert(); f.claim(address(0));
            vm.prank(alice); assertEq(f.claim(alice),0);
            vm.expectRevert(); f.payTreasury();
            vm.expectRevert(); f.transferTreasuryToken(simd,alice,1);
        }
        activateWithHistory(100);
        depositCheese(alice,100); depositEth(alice,100); depositSimd(alice,100);
        advanceBlocks(1);
        for(uint256 i;i<3;++i){
            CheeseFarm f=ff[i]; assertGt(f.pendingRewards(alice),0);
            vm.prank(owner); f.setDepositsPaused(true);
            uint256 shares=f.sharesOf(alice); vm.prank(alice); assertEq(f.withdraw(shares),85);
            assertEq(f.totalAssets(),0); assertEq(f.totalShares(),0);
            vm.prank(alice); uint256 reward=f.claim(bob); assertGt(reward,0); assertEq(f.claimedOf(alice),reward);
            vm.prank(alice); assertEq(f.claim(bob),0);
        }
    }
    function test_SIMDConfigurationEveryBoundary() public {
        CheeseFarmSIMD f=new CheeseFarmSIMD(owner,address(controller));
        assertEq(address(f.asset()),address(0)); assertEq(f.surplus(),0);
        vm.prank(alice); vm.expectRevert(); f.setAsset(address(simd));
        vm.startPrank(owner);
        vm.expectRevert(); f.setAsset(address(0));
        vm.expectRevert(); f.setAsset(alice);
        f.setAsset(address(simd)); assertEq(address(f.asset()),address(simd));
        vm.expectRevert(); f.setAsset(address(cheese)); vm.stopPrank();
    }
    function test_ControllerAdditionalBoundaryCases() public {
        vm.expectRevert(); controller.currentRound();
        vm.expectRevert(); controller.poolIdOf(alice);
        vm.expectRevert(); controller.getPoolAllocation(type(uint256).max);
        vm.expectRevert(); controller.previewPoolEmission(3);
        vm.startPrank(owner);
        vm.expectRevert(); controller.unpauseEmissions();
        vm.expectRevert(); controller.addPool(address(0),0);
        vm.expectRevert(); controller.addPool(alice,0);
        vm.expectRevert(); controller.setPoolWeight(0,type(uint16).max);
        vm.expectRevert(); controller.setPoolWeight(type(uint256).max,0);
        controller.setPoolWeight(0,400); // same weight is a no-op
        controller.disablePool(0);
        vm.expectRevert(); controller.disablePool(0);
        controller.setPoolWeight(0,0); assertEq(controller.totalWeight(),400);
        assertEq(controller.previewPoolEmission(0),0);
        controller.enablePool(0);
        vm.expectRevert(); controller.enablePool(0);
        controller.pauseEmissions(); vm.expectRevert(); controller.pauseEmissions(); controller.unpauseEmissions();
        vm.stopPrank();
        vm.expectRevert(); controller.pullRewards(type(uint256).max,true);
        assertEq(controller.issued(type(uint64).max),referenceIssued(3*H));
        assertEq(controller.fundedBlocks(),0);
        activateWithHistory(0); depositEth(alice,100);
        advanceBlocks(type(uint64).max); controller.checkpoint();
        assertTrue(controller.completed()); assertEq(controller.lastHeight(),type(uint64).max);
        assertLe(controller.cumulativeEmission(),controller.MINING_ALLOWANCE());
        assertEq(withdrawAll(ethFarm,alice),85);
        vm.prank(alice); assertGt(ethFarm.claim(alice),0);
    }
    function test_ControllerBeforeGenesisAndDecodeHelpers() public {
        vm.warp(GENESIS-1); vm.prank(owner); controller.activate(); assertEq(controller.currentRound(),0); assertEq(controller.startRound(),1);
        vm.warp(GENESIS); assertEq(controller.currentRound(),1);
        ISqueekCore.CoreState memory s=core.state(); assertEq(controller.decodeCoreState(abi.encode(s)).blockHeight,0);
        ISqueekCore.CoreConfiguration memory c=core.configuration(); assertEq(controller.decodeCoreConfiguration(abi.encode(c)).roundDuration,600);
        ISqueekCore.RoundPage memory p; p.certifiedThroughRound=1; p.rounds=new ISqueekCore.RoundCheckpoint[](0);
        assertEq(controller.decodeRoundPage(abi.encode(p)).certifiedThroughRound,1);
        vm.expectRevert(); controller.decodeCoreState(hex"01");
        vm.expectRevert(); controller.decodeCoreConfiguration(hex"01");
        vm.expectRevert(); controller.decodeRoundPage(hex"01");
    }
    function test_UnknownSelectorsAndNativeReceiveRejectionAllFive() public {
        address[5] memory targets=[address(controller),address(cheese),address(cheeseFarm),address(ethFarm),address(simdFarm)];
        vm.deal(address(this),5);
        for(uint256 i;i<5;++i){
            (bool ok,)=targets[i].call(hex"deadbeef"); assertFalse(ok);
            (ok,)=targets[i].call{value:1}(""); assertFalse(ok);
        }
    }
}

contract ForceDonation {
    constructor(address payable target) payable { selfdestruct(target); }
}
