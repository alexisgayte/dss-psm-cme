
import "ds-token/token.sol";
import "./TestCToken.stub.sol";

contract TestComptroller {

    uint256 WAD = 10 ** 18;

    TestCToken cToken;
    uint reward;
    uint accountLiquidity;
    DSToken bonusToken;

    constructor(TestCToken cToken_, DSToken bonusToken_) public {
        reward = 0;
        cToken = cToken_;
        bonusToken = bonusToken_;
        accountLiquidity = 10;

    }

    function enterMarkets(address[] calldata cTokens) external returns (uint[] memory) {
        uint[] memory amounts = new uint[](2);
        amounts[0] = 0;
        return amounts;
    }

    function claimComp(address[] calldata holders, address[] calldata cTokens, bool borrowers, bool suppliers) external {
        bonusToken.mint(holders[0], reward);
    }

    function getAccountLiquidity(address) external returns (uint,uint,uint) {
        return (0, accountLiquidity, 0) ;
    }

    function markets(address cTokenAddress) external view returns (bool, uint256) {
        return (true, 75* WAD / 100);
    }

    function setReward(uint256 reward_) external {
        reward = reward_;
    }

    function setAccountLiquidity(uint256 accountLiquidity_) external {
        accountLiquidity = accountLiquidity_;
    }
}