// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CheeseEmissionController} from "src/CheeseEmissionController.sol";
import {CheeseFarmETH} from "src/farms/CheeseFarmETH.sol";

contract RefusesEth {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice The owner can freeze all ETH-farm principal: withdraw pushes the Treasury's cut first and reverts the
///         whole withdrawal when that push fails. With ownership renounced the freeze cannot be undone.
///         Fails on the current code with NativeTransferFailed; passes once a failed Treasury payment no longer
///         blocks the withdrawer (for example a pull balance for the Treasury).
contract TreasuryFreezeTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    CheeseEmissionController internal controller;
    CheeseFarmETH internal farm;

    function setUp() public {
        // No Core read happens before activate(), so any non-zero address serves.
        controller = new CheeseEmissionController(owner, address(0xC0DE), makeAddr("treasury"));
        farm = new CheeseFarmETH(owner, address(controller));
        vm.deal(alice, 10 ether);
    }

    function test_ownerCannotFreezePrincipalThroughTreasury() public {
        vm.prank(alice);
        farm.deposit{value: 10 ether}();

        RefusesEth bad = new RefusesEth();
        vm.startPrank(owner);
        controller.setTreasury(address(bad));
        controller.renounceOwnership();
        vm.stopPrank();

        uint256 shares = farm.sharesOf(alice);
        vm.prank(alice);
        uint256 paid = farm.withdraw(shares);
        assertEq(paid, 8.5 ether, "85% paid");
        assertEq(alice.balance, 8.5 ether, "alice received her 85%");
    }
}