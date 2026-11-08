// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {LiveMockSqueekCore} from "./mocks/LiveMockSqueekCore.sol";
import {LiveReceiverProbe,LiveMaliciousToken} from "./mocks/LiveProbes.sol";
contract LiveFixturesTest is Test {
    function test_FaultsAreControllableAndOperatorRestricted() public {
        LiveMockSqueekCore c=new LiveMockSqueekCore(uint64(block.timestamp));
        vm.prank(address(123));vm.expectRevert();c.setFault(2);
        c.settle(1,10,0);assertEq(c.state().blockHeight,10);
        for(uint8 i=1;i<=5;i++){
            c.setFault(i);(bool ok,bytes memory data)=address(c).staticcall{gas:500000}(abi.encodeWithSignature("state()"));
            assertTrue(!ok || data.length!=256);
            c.setFault(0);assertEq(c.state().blockHeight,10);
        }
    }
    function test_ProbeAndTokenOperatorChecks() public {
        LiveReceiverProbe p=new LiveReceiverProbe();LiveMaliciousToken t=new LiveMaliciousToken(address(456));
        vm.prank(address(123));vm.expectRevert();p.configure(address(0),false,false);
        vm.prank(address(123));vm.expectRevert();t.setMode(2,address(0));
        t.mint(address(this),10);assertTrue(t.transfer(address(456),1));
    }
}
