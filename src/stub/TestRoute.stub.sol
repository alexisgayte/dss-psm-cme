pragma solidity 0.6.7;

import "ds-math/math.sol";
import "ds-token/token.sol";

contract TestRoute {

    uint public amountOut;
    bool public hasBeenCalled = false;

    function swapTokensForExactTokens(uint _amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts){
        hasBeenCalled = true;
        amounts = new uint[](2);
        amounts[0] = 1;
        amounts[1] = _amountOut;
        amountOut = _amountOut;

    }
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = 1;
        amounts[1] = amountIn;
    }

    function reset() external {
        hasBeenCalled = false;
        amountOut = 0;
    }

}