pragma solidity 0.6.7;

import "ds-math/math.sol";
import "ds-token/token.sol";

contract TestCToken is DSMath, DSAuth {

    DSToken underlyingToken;
    uint reward;
    uint feesIncome;
    DSToken bonusToken;
    uint accountBorrows;

    event Borrow(address indexed user, uint256 amount, uint256 totalAmount);
    event Repay(address indexed user, uint256 amount, uint256 totalAmount);

    constructor(bytes32 symbol_, uint256 decimals_, DSToken underlyingToken_, DSToken bonusToken_) public {
        decimals = decimals_;
        underlyingToken = underlyingToken_;
        bonusToken = bonusToken_;
        symbol = symbol_;
    }

    function mint(uint256 mintAmount) external returns (uint256){
        mint(msg.sender, mintAmount);
        underlyingToken.transferFrom(msg.sender, address(this), mintAmount);
        bonusToken.mint(msg.sender, reward);
        return 0;
    }

    function borrow(uint borrowAmount) external returns (uint){
        accountBorrows = add(accountBorrows, borrowAmount);

        emit Borrow(msg.sender, borrowAmount, accountBorrows);
        underlyingToken.approve(msg.sender, borrowAmount);
        underlyingToken.transferFrom(address(this), msg.sender, borrowAmount);
        return 0;
    }

    function repayBorrow(uint repayAmount) external returns (uint){
        accountBorrows = sub(accountBorrows, repayAmount);

        emit Repay(msg.sender, repayAmount, accountBorrows);

        underlyingToken.transferFrom(msg.sender, address(this), repayAmount);
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256){
        burn(msg.sender, redeemAmount);
        underlyingToken.transferFrom(address(this), msg.sender, redeemAmount);
        bonusToken.mint(msg.sender, reward);
        return 0;
    }

    function balanceOfUnderlying(address usr) external returns (uint256){
        return balanceOf[usr];
    }

    function borrowBalanceStored(address usr) public view returns (uint256) {
        return accountBorrows;
    }


    function setReward(uint256 reward_) external {
        reward = reward_;
    }

    function addFeeIncome(address usr, uint256 feesIncome_) external {
        mint(usr, feesIncome_);
        underlyingToken.mint(address(this), feesIncome_);
    }

    //// TokenDS

    bool                                              public  stopped;
    uint256                                           public  totalSupply;
    mapping (address => uint256)                      public  balanceOf;
    mapping (address => mapping (address => uint256)) public  allowance;
    bytes32                                           public  symbol;
    uint256                                           public  decimals = 18; // standard token precision. override to customize
    bytes32                                           public  name = "";     // Optional token name

    event Approval(address indexed src, address indexed guy, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);
    event Mint(address indexed guy, uint wad);
    event Burn(address indexed guy, uint wad);

    function approve(address guy) external returns (bool) {
        return approve(guy, uint(-1));
    }

    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;

        emit Approval(msg.sender, guy, wad);

        return true;
    }

    function transfer(address dst, uint wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad) public returns (bool){
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= wad, "ds-token-insufficient-approval");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
        }

        require(balanceOf[src] >= wad, "ds-token-insufficient-balance");
        balanceOf[src] = sub(balanceOf[src], wad);
        balanceOf[dst] = add(balanceOf[dst], wad);

        emit Transfer(src, dst, wad);

        return true;
    }

    function mint(address guy, uint wad) public {
        balanceOf[guy] = add(balanceOf[guy], wad);
        totalSupply = add(totalSupply, wad);
        emit Mint(guy, wad);
    }

    function burn(address guy, uint wad) public {
        if (guy != msg.sender && allowance[guy][msg.sender] != uint(-1)) {
            require(allowance[guy][msg.sender] >= wad, "ds-token-insufficient-approval");
            allowance[guy][msg.sender] = sub(allowance[guy][msg.sender], wad);
        }

        require(balanceOf[guy] >= wad, "ds-token-insufficient-balance");
        balanceOf[guy] = sub(balanceOf[guy], wad);
        totalSupply = sub(totalSupply, wad);
        emit Burn(guy, wad);
    }

}