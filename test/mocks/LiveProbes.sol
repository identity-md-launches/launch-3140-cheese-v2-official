// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ILiveFarm {
    function deposit() external payable returns (uint256);
    function withdraw(uint256) external returns (uint256);
    function sharesOf(address) external view returns (uint256);
}
contract LiveReceiverProbe {
    address public immutable operator = msg.sender;
    address public farm;
    bool public rejectETH;
    bool public attack;
    bool public attempted;
    bool public reentrySucceeded;
    modifier onlyOperator() { require(msg.sender == operator, "operator only"); _; }
    function configure(address f, bool rejecting, bool attacking) external onlyOperator {
        farm=f; rejectETH=rejecting; attack=attacking; attempted=false; reentrySucceeded=false;
    }
    function deposit(address f) external payable onlyOperator { ILiveFarm(f).deposit{value:msg.value}(); }
    function withdraw(address f,uint256 shares) external onlyOperator { ILiveFarm(f).withdraw(shares); }
    function recover() external onlyOperator { (bool ok,)=operator.call{value:address(this).balance}("");require(ok); }
    receive() external payable {
        require(!rejectETH,"controlled rejection");
        if(attack) { attempted=true; (reentrySucceeded,)=farm.call(abi.encodeWithSignature("withdraw(uint256)",1)); }
    }
}
contract LiveMaliciousToken is ERC20 {
    address public immutable operator = msg.sender;
    address public immutable treasury;
    uint8 public mode;
    address public reentryFarm;
    bool public attempted;
    bool public reentrySucceeded;
    modifier onlyOperator() { require(msg.sender == operator,"operator only"); _; }
    constructor(address t) ERC20("CHEESE TEST malicious asset","TEST-BAD") { treasury=t; }
    function mint(address to,uint256 amount) external onlyOperator { _mint(to,amount); }
    function setMode(uint8 m,address farm) external onlyOperator { mode=m;reentryFarm=farm;attempted=false;reentrySucceeded=false; }
    function transfer(address to,uint256 amount) public override returns(bool) {
        bool result=super.transfer(to,amount);
        uint256 m=mode;
        if(m==10) { attempted=true;(reentrySucceeded,)=reentryFarm.call(abi.encodeWithSignature("withdraw(uint256)",1));return result; }
        if(to!=treasury)return result;
        assembly {
            switch m
            case 1 { mstore(0,0) return(0,32) }
            case 2 { mstore(0,2) return(0,32) }
            case 3 { mstore(0,1) return(1,31) }
            case 4 { mstore(0,1) mstore(32,0) return(0,64) }
            case 5 { revert(0,0) }
            case 6 { for {} 1 {} {} }
            case 7 { return(0,0) }
            case 8 { return(0,0x200000) }
            case 9 { revert(0,0x200000) }
        }
        return result;
    }
}
contract LiveForcedETH {
    constructor(address payable target) payable { selfdestruct(target); }
}
