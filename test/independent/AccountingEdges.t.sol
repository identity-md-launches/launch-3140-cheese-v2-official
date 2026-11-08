// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {CheeseBase} from "../CheeseBase.t.sol";
import {CheeseFarmSIMD} from "../../src/farms/CheeseFarmSIMD.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract NonCanonicalTreasuryToken is ERC20 {
    address immutable badRecipient;

    constructor(address treasury) ERC20("Local test double", "TEST") {
        badRecipient = treasury;
    }

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }

    function transfer(address to, uint256 n) public override returns (bool) {
        if (to == badRecipient) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return super.transfer(to, n);
    }
}

contract AccountingEdgesTest is CheeseBase {
    /// Malformed Treasury responses defer the fee without obstructing the user's payout.
    function test_nonCanonicalTreasuryBoolDefersFeeAndAllowsSIMDExit() public {
        NonCanonicalTreasuryToken asset = new NonCanonicalTreasuryToken(treasury);
        CheeseFarmSIMD farm = new CheeseFarmSIMD(owner, address(controller));
        vm.startPrank(owner);
        controller.addPool(address(farm), 100);
        farm.setAsset(address(asset));
        vm.stopPrank();
        activateWithHistory(0);
        asset.mint(alice, 100 ether);
        vm.startPrank(alice);
        asset.approve(address(farm), 100 ether);
        farm.deposit(100 ether);
        uint256 shares = farm.sharesOf(alice);
        (bool ok,) = address(farm).call(abi.encodeCall(farm.withdraw, (shares)));
        assertTrue(ok, "Treasury refusal must not block principal");
        assertEq(farm.sharesOf(alice), 0);
        assertEq(asset.balanceOf(alice), 85 ether);
        assertEq(farm.treasuryOwed(), 15 ether);
        assertEq(asset.balanceOf(address(farm)), 15 ether);
        vm.stopPrank();
        vm.prank(owner);
        controller.setTreasury(carol);
        farm.payTreasury();
        assertEq(farm.treasuryOwed(), 0);
        assertEq(asset.balanceOf(carol), 15 ether);
    }

    /// Independently checks integer conservation and the last-depositor sweep across a wide range.
    function testFuzz_independentWithdrawalConservation(uint96 a, uint96 b, uint16 fraction) public {
        uint256 first = bound(uint256(a), 1000, 1e24);
        uint256 second = bound(uint256(b), 1000, 1e24);
        vm.deal(alice, first);
        vm.deal(bob, second);
        activateWithHistory(0);
        depositEth(alice, first);
        depositEth(bob, second);
        uint256 shares = ethFarm.sharesOf(alice) * bound(uint256(fraction), 1, 10000) / 10000;
        uint256 backing = ethFarm.totalAssets();
        uint256 supply = ethFarm.totalShares();
        uint256 gross = shares * (backing + 1) / (supply + 1000);
        uint256 fee = gross * 15 / 100;
        uint256 retained = gross * 14 / 100;
        // the retained share is capped at 15/85 of the assets backing the remaining shares
        uint256 remainingAssets = (supply - shares) * (backing + 1) / (supply + 1000);
        uint256 cap = remainingAssets * 1500 / 8500;
        if (retained > cap) retained = cap;
        uint256 oldTreasury = treasury.balance;
        vm.prank(alice);
        assertEq(ethFarm.withdraw(shares), gross - fee);
        assertEq(treasury.balance - oldTreasury, fee - retained);
        assertEq(ethFarm.totalAssets(), backing - gross + retained);
        if (ethFarm.sharesOf(alice) > 0) withdrawAll(ethFarm, alice);
        uint256 lastBacking = ethFarm.totalAssets();
        uint256 beforeLast = treasury.balance;
        uint256 paid = withdrawAll(ethFarm, bob);
        assertEq(treasury.balance - beforeLast, lastBacking - paid);
        assertEq(ethFarm.totalAssets(), 0);
        assertEq(address(ethFarm).balance, 0);
    }
}
