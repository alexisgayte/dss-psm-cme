pragma solidity 0.6.7;

interface PsmLike {
    function sellGem(address, uint256) external;
}

interface GemLike {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function approve(address guy, uint wad) external returns (bool);
}

interface RouteLike {
    function swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}


contract SendDelegator {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'SendDelegator/re-entrance');unlocked = 0;_;unlocked = 1;}

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "psm") psm = PsmLike(data);
        else if (what == "route") route = RouteLike(data);
        else revert("SendDelegator/file-unrecognized-param");

        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "maxBonusAuctionAmount") maxBonusAuctionAmount = data;
        else if (what == "maxDaiAuctionAmount") maxDaiAuctionAmount = data;
        else if (what == "bonusAuctionDuration") bonusAuctionDuration = data;
        else if (what == "daiAuctionDuration") daiAuctionDuration = data;
        else revert("SendDelegator/file-unrecognized-param");

        emit File(what, data);
    }

    function cage() external auth {
        live = 0;
    }

    uint256 public live;

    event File(bytes32 indexed what, bool data);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);
    event Rely(address indexed user);
    event Deny(address indexed user);
    event RelyCall(address indexed user);
    event DenyCall(address indexed user);

    // --- Math ---
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        return x <= y ? x : y;
    }

    // primary variable
    address public immutable daiReserve;
    address public immutable bonusReserve;
    PsmLike public psm;
    GemLike public immutable dai;
    GemLike public immutable usdc;
    GemLike public immutable bonusToken;
    RouteLike public route;

    uint256 public maxBonusAuctionAmount;
    uint256 public maxDaiAuctionAmount;
    uint256 public bonusAuctionDuration;
    uint256 public daiAuctionDuration;
    uint256 public lastDaiAuctionTimestamp;
    uint256 public lastBonusAuctionTimestamp;

    // constructor
    constructor(address daiReserve_, address bonusReserve_, address dai_, address usdc_, address bonusToken_) public {
        wards[msg.sender] = 1;
        live = 1;

        daiReserve = daiReserve_;
        bonusReserve = bonusReserve_;
        dai = GemLike(dai_);
        usdc = GemLike(usdc_);
        bonusToken = GemLike(bonusToken_);

        bonusAuctionDuration = 3600;
        maxBonusAuctionAmount = 500;
        daiAuctionDuration = 3600;
        maxDaiAuctionAmount = 500;
    }


    // --- Primary Functions ---

    function call() external {

    }

    function processDai() external lock {
        uint256 _amountDai = dai.balanceOf(address(this));
        if ((block.timestamp - lastDaiAuctionTimestamp) > daiAuctionDuration && _amountDai > 0){
            lastDaiAuctionTimestamp = block.timestamp;
            uint256 _sendDaiAmount = min(maxDaiAuctionAmount, _amountDai);
            require(dai.approve(daiReserve, _sendDaiAmount), "SendDelegator/failed-approve-dai");
            require(dai.transfer(daiReserve, _sendDaiAmount), "SendDelegator/failed-transfer-dai");
        }
    }

    function processComp() external lock {
        uint256 _amountBonus = bonusToken.balanceOf(address(this));

        if ((block.timestamp - lastBonusAuctionTimestamp) > bonusAuctionDuration && _amountBonus > 0) {
            lastBonusAuctionTimestamp = block.timestamp;
            uint256 _sendBonusAmount = min(maxBonusAuctionAmount, _amountBonus);
            require(bonusToken.approve(bonusReserve, _sendBonusAmount), "SendDelegator/failed-approve-comp");
            require(bonusToken.transfer(bonusReserve, _sendBonusAmount), "SendDelegator/failed-transfer-comp");
        }

    }

    function processUsdc() external lock {
        uint256 _amountUsdc = usdc.balanceOf(address(this));

        if ( _amountUsdc > 0){
            require(usdc.approve(address(psm), _amountUsdc), "SendDelegator/failed-approve-psm");
            psm.sellGem(address(this), _amountUsdc);
        }

    }
}