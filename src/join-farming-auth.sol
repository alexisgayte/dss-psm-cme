pragma solidity 0.6.7;

import "dss/lib.sol";
import "ds-math/math.sol";

interface VatLike {
    function slip(bytes32, address, int256) external;
    function gem(bytes32, address) external view returns (int256);
    function urns(bytes32, address) external view returns (uint256, uint256);
}

interface LTKLike {
    function mint(uint mintAmount) external returns (uint);
    function borrow(uint borrowAmount) external returns (uint);
    function repayBorrow(uint repayAmount) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function borrowBalanceStored(address account) external view returns (uint);
    function balanceOfUnderlying(address owner) external returns (uint);
    function accrueInterest() external returns (uint);
}

interface GemLike {
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address guy, uint wad) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
}

interface CalLike {
    function call() external;
}

interface ComLike {
    function enterMarkets(address[] calldata cTokens) external returns (uint[] memory);
    function claimComp(address[] calldata holders, address[] calldata cTokens, bool borrowers, bool suppliers) external;
    function getAccountLiquidity(address) external returns (uint,uint,uint);
    function markets(address cTokenAddress) external view returns (bool, uint256);
}

interface RouteLike {
    function swapTokensForExactTokens(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}


contract FarmingAuthGemJoin is LibNote, DSMath {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external note auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'DssPsmCme/Locked');unlocked = 0;_;unlocked = 1;}

    // --- Data ---
    VatLike public vat;
    bytes32 public ilk;
    GemLike public gem;
    uint256 public dec;
    uint256 public live;  // Access Flag
    LTKLike public ltk;
    uint256 public total;  // total gems

    CalLike public excessDelegator;
    GemLike public bonusToken;
    uint256 public gemTo18ConversionFactor;
    RouteLike public route;
    uint256 public bonusAuctionMaxAmount;
    uint256 public bonusAuctionDuration;
    uint256 public lastBonusAuctionTimestamp;
    uint256 public excessMargin;

    uint256 public cfTarget;
    uint256 public cfMax;
    ComLike public lender;

    // --- Events ---
    event Rely(address indexed user);
    event Deny(address indexed user);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);
    event Delegate(address indexed sender, address indexed delegator, uint256 bonus, uint256 gem);

    // --- Init ---
    constructor(address vat_, bytes32 ilk_, address gem_, address ltk_, address bonusToken_, address lender_) public {
        gem = GemLike(gem_);
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        ilk = ilk_;
        ltk = LTKLike(ltk_);
        excessDelegator = CalLike(0);
        bonusToken = GemLike(bonusToken_);
        lender = ComLike(lender_);

        dec = gem.decimals();
        require(dec <= 18, "FarmingAuthGemJoin/decimals-18-or-higher");
        gemTo18ConversionFactor = 10 ** (18 - dec);

        total = 0;
        bonusAuctionDuration = 3600;
        bonusAuctionMaxAmount = 500;
        excessMargin = 500;

        address[] memory ctokens = new address[](1);
        ctokens[0] = ltk_;
        uint256[] memory errors = new uint[](1);
        errors = ComLike(lender_).enterMarkets(ctokens);
        require(errors[0] == 0);
        require(gem.approve(address(ltk), uint256(-1)), "FarmingAuthGemJoin/failed-approve-repayBorrow");
    }

    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "excess_delegator") excessDelegator = CalLike(data);
        else if (what == "route") route = RouteLike(data);
        else revert("FarmingAuthGemJoin/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "cf_target")  {
            require(data < WAD , "DssPsmCme/more-100-percent");
            cfTarget = data;
        }
        else if (what == "cf_max") {
            require(data < WAD , "DssPsmCme/more-100-percent");
            cfMax = data;
        }
        else if (what == "bonus_auction_max_amount") bonusAuctionMaxAmount = data;
        else if (what == "bonus_auction_duration") bonusAuctionDuration = data;
        else if (what == "excess_margin") excessMargin = data;
        else revert("FarmingAuthGemJoin/file-unrecognized-param");

        emit File(what, data);
    }

    function cage() external note auth {
        live = 0;
    }

    // --- Primary Functions ---
    // --- harvest ---
    function harvest() external lock note auth {
        address[] memory ctokens = new address[](1);
        address[] memory users   = new address[](1);
        ctokens[0] = address(ltk);
        users  [0] = address(this);

        lender.claimComp(users, ctokens, true, true);
        _harvest();
        _checkLiquidityIssue();
    }

    function _harvest() private {

        uint256 _gemsAdjusted = mul(total, 1001)/1000; // we keep 0.1% for dust
        uint256 _actualUnderlying = sub(ltk.balanceOfUnderlying(address(this)), ltk.borrowBalanceStored(address(this)));

        if (_actualUnderlying < _gemsAdjusted) {
            _recover(_actualUnderlying, _gemsAdjusted);
        } else {
            _callDelegator(_actualUnderlying, _gemsAdjusted);
        }
    }

    function _recover(uint256 actualUnderlying_, uint256 gemsAdjusted_) private {

        uint256 _balance = bonusToken.balanceOf(address(this));
        if ((block.timestamp - lastBonusAuctionTimestamp) > bonusAuctionDuration && _balance > 0) {
            lastBonusAuctionTimestamp = block.timestamp;
            uint256 _missingUnderlying = sub(gemsAdjusted_, actualUnderlying_);
            _missingUnderlying = add(_missingUnderlying, excessMargin);

            address[] memory path = new address[](2);
            path[0] = address(bonusToken);
            path[1] = address(gem);

            uint256[] memory _amountOut =  route.getAmountsOut(_balance, path);
            uint256 _buyGemAmount = min(_missingUnderlying, _amountOut[_amountOut.length - 1]);
            _buyGemAmount = min(bonusAuctionMaxAmount, _buyGemAmount);
            require(bonusToken.approve(address(route), _buyGemAmount), "FarmingAuthGemJoin/failed-approve-bonus-token");
            route.swapTokensForExactTokens(_buyGemAmount, uint(0), path, address(this), block.timestamp + 3600);
            require(ltk.mint(_buyGemAmount) == 0, "FarmingAuthGemJoin/failed-mint");

            _updateLeverage(0);
        }

    }

    function _callDelegator(uint256 actualUnderlying_, uint256 gemsAdjusted_) private {
        if (address(excessDelegator) != address(0)) {
            uint256 _balance = bonusToken.balanceOf(address(this));
            uint256 _excessUnderlying = 0;
            uint256 _gemsAdjustedMargin = add(gemsAdjusted_, excessMargin);

            if (actualUnderlying_ > _gemsAdjustedMargin) {
                _excessUnderlying = sub(actualUnderlying_, _gemsAdjustedMargin);

                _updateLeverage(_excessUnderlying);

                require(ltk.redeemUnderlying(_excessUnderlying) == 0, "FarmingAuthGemJoin/failed-redemmUnderlying-excess");
                require(gem.transfer(address(excessDelegator), _excessUnderlying), "FarmingAuthGemJoin/failed-transfer-excess");
            }

            if (_balance > 0) {
                require(bonusToken.transfer(address(excessDelegator), _balance), "FarmingAuthGemJoin/failed-transfer-bonus-token");
            }

            if (actualUnderlying_ > _gemsAdjustedMargin || _balance > 0) {
                emit Delegate(msg.sender, address(excessDelegator), _balance, _excessUnderlying);
            }
        }
    }

    // --- Join method ---
    function join(address guy, uint256 wad) public note auth lock {
        require(live == 1, "FarmingAuthGemJoin/not-live");
        uint256 wad18 = mul(wad, 10 ** (18 - dec));
        require(int256(wad18) >= 0, "FarmingAuthGemJoin/overflow");
        vat.slip(ilk, guy, int256(wad18));
        total = add(total, wad);

        require(gem.transferFrom(guy, address(this), wad), "FarmingAuthGemJoin/failed-transfer");
        require(ltk.mint(wad) == 0, "FarmingAuthGemJoin/failed-mint");

        _updateLeverage(0);
        _checkLiquidityIssue();
    }

    function exit(address guy, uint256 wad) public note lock {
        uint256 wad18 = mul(wad, gemTo18ConversionFactor);
        require(int256(wad18) >= 0, "FarmingAuthGemJoin/overflow");
        vat.slip(ilk, msg.sender, -int256(wad18));
        total = sub(total, wad);

        _updateLeverage(wad);

        require(ltk.redeemUnderlying(wad) == 0, "FarmingAuthGemJoin/failed-redemmUnderlying");
        require(gem.transfer(guy, wad), "FarmingAuthGemJoin/failed-transfer");

        _checkLiquidityIssue();
    }

    function _updateLeverage(uint256 adjustmentAmount_) private {

        uint256 _balanceUnderlying = ltk.balanceOfUnderlying(address(this));
        uint256 _borrowBalance = ltk.borrowBalanceStored(address(this));
        uint256 _actualUnderlying = sub(_balanceUnderlying, _borrowBalance);

        require(_actualUnderlying >= adjustmentAmount_, "FarmingAuthGemJoin/error-adjustment");
        _actualUnderlying = sub(_actualUnderlying, adjustmentAmount_);

        uint256 _futureUnderlyingBalance = mul(_actualUnderlying, WAD) / sub( WAD , coefficientTarget());

        if(_borrowBalance > _futureUnderlyingBalance) {
            _unwind(add(_futureUnderlyingBalance, adjustmentAmount_), _balanceUnderlying, _borrowBalance);
        } else {
            _wind(add(_futureUnderlyingBalance, adjustmentAmount_), _balanceUnderlying, _borrowBalance);
        }
    }

    function _wind(uint256 totalUnderlying_, uint256 balanceUnderlying_, uint256 borrowBalanceStored_) private {
        uint256 _maxCollateralFactor = maxCollateralFactor();
        uint256 _borrowBalanceStored = borrowBalanceStored_;
        uint256 _balanceUnderlying = balanceUnderlying_;

        while (_balanceUnderlying < totalUnderlying_) {

            uint256 _compBorrow = sub(wmul(_balanceUnderlying, _maxCollateralFactor), _borrowBalanceStored);
            _compBorrow = mul(_compBorrow, 99) / 100;

            uint256 _futureUnderlying = add(_balanceUnderlying, _compBorrow);
            if ( _futureUnderlying > totalUnderlying_) {
                _compBorrow = sub(totalUnderlying_, _balanceUnderlying);
            }

            require(ltk.borrow(_compBorrow) == 0, "FarmingAuthGemJoin/failed-borrow");
            require(ltk.mint(_compBorrow) == 0, "FarmingAuthGemJoin/failed-mint");

            _balanceUnderlying = add(_balanceUnderlying, _compBorrow);
            _borrowBalanceStored = add(_borrowBalanceStored, _compBorrow);
        }
    }

    function _unwind(uint256 totalUnderlying_, uint256 balanceUnderlying_, uint256 borrowBalanceStored_) private {
        uint256 _maxCollateralFactor = maxCollateralFactor();
        uint256 _borrowBalanceStored = borrowBalanceStored_;
        uint256 _balanceUnderlying = balanceUnderlying_;

        while (_balanceUnderlying > totalUnderlying_) {

            uint256 _compRedeem = sub(wmul(_balanceUnderlying, _maxCollateralFactor), _borrowBalanceStored);
            _compRedeem = mul(_compRedeem, 99) / 100;

            uint256 _future_redeem = sub(_balanceUnderlying, _compRedeem);
            if (_future_redeem < totalUnderlying_) {
                _compRedeem = sub(_balanceUnderlying, totalUnderlying_);
            }

            require(ltk.redeemUnderlying(_compRedeem) == 0, "FarmingAuthGemJoin/failed-redeem");
            require(ltk.repayBorrow(_compRedeem) == 0, "FarmingAuthGemJoin/failed-repay");

            _balanceUnderlying = sub(_balanceUnderlying, _compRedeem);
            _borrowBalanceStored = sub(_borrowBalanceStored, _compRedeem);
        }
    }

    function _checkLiquidityIssue() private {

        (uint error, uint liquidity, uint shortfall) = lender.getAccountLiquidity(address(this));

        require(error == 0, "join the Discord");
        require(shortfall == 0, "account underwater");
        require(liquidity > 0, "account has excess collateral");

    }

    function maxCollateralFactor() public view returns (uint256) {
        (, uint256 maxColFactor) = ComLike(lender).markets(address(ltk));
        return min(maxColFactor, cfMax);
    }

    function coefficientTarget() public view returns (uint256) {
        return min(mul(maxCollateralFactor(), 98) / 100, cfTarget);
    }

}