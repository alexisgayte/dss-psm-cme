pragma solidity 0.6.7;

import "ds-math/math.sol";
import "ds-token/token.sol";

contract TestRoute {

    uint public amountOut;
    bool public hasBeenCalled = false;

    function swapTokensForExactTokens(uint _amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts){
        hasBeenCalled = true;
        amounts = new uint[](2);
        amounts[0] = _amountOut;
        amounts[1] = _amountOut;
        amountOut = _amountOut;

        DSToken(path[0]).transferFrom(msg.sender,address(this), _amountOut);
        DSToken(path[1]).mint(msg.sender, _amountOut);

    }
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    function reset() external {
        hasBeenCalled = false;
        amountOut = 0;
    }

}