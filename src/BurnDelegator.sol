pragma solidity 0.6.7;

interface PsmLike {
    function sellGem(address, uint256) external;
}

interface GemLike {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function approve(address guy, uint wad) external returns (bool);
    function burn(address guy, uint wad) external;
}

interface RouteLike {
    function swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}


contract BurnDelegator {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'BurnDelegator/re-entrance');unlocked = 0;_;unlocked = 1;}

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "psm") psm = PsmLike(data);
        else if (what == "route") route = RouteLike(data);
        else revert("BurnDelegator/file-unrecognized-param");

        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "bonus_auction_max_amount") bonusAuctionMaxAmount = data;
        else if (what == "bonus_auction_duration") bonusAuctionDuration = data;
        else if (what == "dai_auction_max_amount") daiAuctionMaxAmount = data;
        else if (what == "dai_auction_duration") daiAuctionDuration = data;
        else revert("BurnDelegator/file-unrecognized-param");

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
    GemLike public immutable mkr;
    GemLike public immutable dai;
    GemLike public immutable usdc;
    GemLike public immutable bonusToken;
    RouteLike public route;
    PsmLike public psm;

    uint256 public bonusAuctionMaxAmount;
    uint256 public bonusAuctionDuration;
    uint256 public daiAuctionMaxAmount;
    uint256 public daiAuctionDuration;
    uint256 public lastDaiAuctionTimestamp;
    uint256 public lastBonusAuctionTimestamp;

    // constructor
    constructor(address mkr_, address dai_, address usdc_, address bonusToken_) public {
        wards[msg.sender] = 1;
        live = 1;

        mkr = GemLike(mkr_);
        dai = GemLike(dai_);
        usdc = GemLike(usdc_);
        bonusToken = GemLike(bonusToken_);

        bonusAuctionDuration = 3600;
        bonusAuctionMaxAmount = 500;
        daiAuctionDuration = 3600;
        daiAuctionMaxAmount = 500;
    }


    // --- Primary Functions ---

    function call() external {

    }

    function processDai() external lock {
        uint256 _amountDai = dai.balanceOf(address(this));
        if ((block.timestamp - lastDaiAuctionTimestamp) > daiAuctionDuration && _amountDai > 0) {
            lastDaiAuctionTimestamp = block.timestamp;
            require(dai.approve(address(route), _amountDai), "BurnDelegator/failed-approve-dai-token");

            address[] memory path = new address[](2);
            path[0] = address(dai);
            path[1] = address(mkr);

            uint256[] memory _amountOut =  route.getAmountsOut(_amountDai, path);
            uint256 _buyMrkAmount = min(daiAuctionMaxAmount, _amountOut[_amountOut.length - 1]);
            route.swapTokensForExactTokens(_buyMrkAmount, uint(0), path, address(this), block.timestamp + 3600);
            mkr.burn(address(this), mkr.balanceOf(address(this)));
        }

    }

    function processComp() external lock {
        uint256 _amountBonus = bonusToken.balanceOf(address(this));

        if ((block.timestamp - lastBonusAuctionTimestamp) > bonusAuctionDuration && _amountBonus > 0) {
            lastBonusAuctionTimestamp = block.timestamp;
            require(bonusToken.approve(address(route), _amountBonus), "BurnDelegator/failed-approve-bonus-token");

            address[] memory path = new address[](2);
            path[0] = address(bonusToken);
            path[1] = address(dai);

            uint256[] memory _amountOut =  route.getAmountsOut(_amountBonus, path);
            uint256 _buyDaiAmount = min(bonusAuctionMaxAmount, _amountOut[_amountOut.length - 1]);
            route.swapTokensForExactTokens(_buyDaiAmount, uint(0), path, address(this), block.timestamp + 3600);
        }

    }

    function processUsdc() external lock {
        uint256 _amountUsdc = usdc.balanceOf(address(this));

        if ( _amountUsdc > 0){
            require(usdc.approve(address(psm), _amountUsdc), "BurnDelegator/failed-approve-psm");
            psm.sellGem(address(this), _amountUsdc);
        }

    }
}