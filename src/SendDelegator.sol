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
        if (what == "max_bonus_auction_amount") max_bonus_auction_amount = data;
        else if (what == "max_dai_auction_amount") max_dai_auction_amount = data;
        else if (what == "bonus_auction_duration") bonus_auction_duration = data;
        else if (what == "dai_auction_duration") dai_auction_duration = data;
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
    address public immutable dai_reserve;
    address public immutable bonus_reserve;
    PsmLike public psm;
    GemLike public immutable dai;
    GemLike public immutable usdc;
    GemLike public immutable bonus_token;
    RouteLike public route;

    uint256 public max_bonus_auction_amount;
    uint256 public max_dai_auction_amount;
    uint256 public bonus_auction_duration;
    uint256 public dai_auction_duration;
    uint256 public last_dai_auction_timestamp;
    uint256 public last_bonus_auction_timestamp;

    // constructor
    constructor(address dai_reserve_, address bonus_reserve_, address dai_, address usdc_, address bonus_token_) public {
        wards[msg.sender] = 1;
        live = 1;

        dai_reserve = dai_reserve_;
        bonus_reserve = bonus_reserve_;
        dai = GemLike(dai_);
        usdc = GemLike(usdc_);
        bonus_token = GemLike(bonus_token_);

        bonus_auction_duration = 3600;
        max_bonus_auction_amount = 500;
        dai_auction_duration = 3600;
        max_dai_auction_amount = 500;
    }


    // --- Primary Functions ---

    function call() external {

    }

    function processDai() external lock {
        uint256 _amount_dai = dai.balanceOf(address(this));
        if ((block.timestamp - last_dai_auction_timestamp) > dai_auction_duration && _amount_dai > 0){
            last_dai_auction_timestamp = block.timestamp;
            uint256 _send_dai_amount = min(max_dai_auction_amount, _amount_dai);
            require(dai.approve(dai_reserve, _send_dai_amount), "SendDelegator/failed-approve-dai");
            require(dai.transfer(dai_reserve, _send_dai_amount), "SendDelegator/failed-transfer-dai");
        }
    }

    function processComp() external lock {
        uint256 _amount_bonus = bonus_token.balanceOf(address(this));

        if ((block.timestamp - last_bonus_auction_timestamp) > bonus_auction_duration && _amount_bonus > 0) {
            last_bonus_auction_timestamp = block.timestamp;
            uint256 _send_bonus_amount = min(max_bonus_auction_amount, _amount_bonus);
            require(bonus_token.approve(bonus_reserve, _send_bonus_amount), "SendDelegator/failed-approve-comp");
            require(bonus_token.transfer(bonus_reserve, _send_bonus_amount), "SendDelegator/failed-transfer-comp");
        }

    }

    function processUsdc() external lock {
        uint256 _amount_usdc = usdc.balanceOf(address(this));

        if ( _amount_usdc > 0){
            require(usdc.approve(address(psm), _amount_usdc), "SendDelegator/failed-approve-psm");
            psm.sellGem(address(this), _amount_usdc);
        }

    }
}