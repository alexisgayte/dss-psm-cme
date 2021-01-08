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


contract LendingLeverageAuthGemJoin is LibNote, DSMath {
    // --- Auth ---
    mapping (address => uint256) public wards;
    address[] private wards_address;
    function rely(address usr) external note auth {
        wards[usr] = 1;
        wards_address.push(usr);
    }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'DssPsmCme/Locked');unlocked = 0;_;unlocked = 1;}

    VatLike public vat;
    bytes32 public ilk;
    GemLike public gem;
    GemLike public dai;
    uint256 public dec;
    uint256 public live;  // Access Flag
    LTKLike public ltk;

    CalLike public excess_delegator;
    GemLike public bonus_token;
    uint256 public gemTo18ConversionFactor;
    RouteLike public route;
    uint256 public max_bonus_auction_amount;
    uint256 public bonus_auction_duration;
    uint256 public last_bonus_auction_timestamp;

    uint256 public cf_target;
    uint256 public cf_max;
    ComLike public lender;

    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);
    event Delegate(address indexed sender, address indexed delegator, uint256 bonus, uint256 gem);

    constructor(address vat_, bytes32 ilk_, address gem_, address ltk_, address bonus_token_, address lender_, address dai_) public {
        gem = GemLike(gem_);
        dec = gem.decimals();
        require(dec < 18, "LendingLeverageAuthGemJoin/decimals-18-or-higher");
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);

        ilk = ilk_;
        ltk = LTKLike(ltk_);
        excess_delegator = CalLike(0);
        bonus_token = GemLike(bonus_token_);
        lender = ComLike(lender_);
        dai = GemLike(dai_);
        gemTo18ConversionFactor = 10 ** (18 - dec);

        bonus_auction_duration = 3600;
        max_bonus_auction_amount = 500;

        address[] memory ctokens = new address[](1);
        ctokens[0] = ltk_;
        uint256[] memory errors = new uint[](1);
        errors = ComLike(lender_).enterMarkets(ctokens);
        require(errors[0] == 0);

        require(gem.approve(address(ltk), uint256(-1)), "LendingLeverageAuthGemJoin/failed-approve-repayBorrow");
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "excess_delegator") excess_delegator = CalLike(data);
        else if (what == "route") route = RouteLike(data);
        else revert("LendingLeverageAuthGemJoin/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "cf_target")  {
            require(data < WAD , "DssPsmCme/more-100-percent");
            cf_target = data;
        }
        else if (what == "cf_max") {
            require(data < WAD , "DssPsmCme/more-100-percent");
            cf_max = data;
        }
        else if (what == "max_bonus_auction_amount") max_bonus_auction_amount = data;
        else if (what == "bonus_auction_duration") bonus_auction_duration = data;
        else revert("LendingLeverageAuthGemJoin/file-unrecognized-param");

        emit File(what, data);
    }

    function cage() external note auth {
        live = 0;
    }

    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }

    // --- harvest ---
    function harvest() external lock auth {
        address[] memory ctokens = new address[](1);
        address[] memory users   = new address[](1);
        ctokens[0] = address(ltk);
        users  [0] = address(this);

        lender.claimComp(users, ctokens, true, true);
        _callDelegator();
        _checkLiquidityIssue();
    }

    function sumGemsStored() view public returns (uint256 sum_){
        sum_ = 0;
        uint256 ink;
        for (uint i = 0; i < wards_address.length; i++) {
            (ink,) = vat.urns(ilk, wards_address[i]);
            sum_ = add(sum_, ink);
            sum_ = add(sum_, vat.gem(ilk, wards_address[i]));
        }
    }

    function _callDelegator() private {
        if (address(excess_delegator) != address(0)) {
            uint256 balance = bonus_token.balanceOf(address(this));
            uint256 gems = sumGemsStored();
            uint256 wgemsAdjusted = (mul(gems, add( 1 * WAD, 1 * WAD / 1000)) / WAD) / WAD; // we keep 0.1% for dust
            uint256 actualUnderlying = sub(ltk.balanceOfUnderlying(address(this)), ltk.borrowBalanceStored(address(this)));
            uint256 wunderlying = mul(actualUnderlying, gemTo18ConversionFactor) / WAD;
            uint256 excess_underlying = 0;

            if (wunderlying < wgemsAdjusted) {
                if ((block.timestamp - last_bonus_auction_timestamp) > bonus_auction_duration && balance > 0) {
                    last_bonus_auction_timestamp = block.timestamp;
                    uint256 wmissing_underlying = sub(wgemsAdjusted, wunderlying);
                    uint256 missing_underlying = mul(wmissing_underlying, WAD ) / gemTo18ConversionFactor;

                    address[] memory path = new address[](2);
                    path[0] = address(bonus_token);
                    path[1] = address(gem);

                    uint256[] memory _amount_out =  route.getAmountsOut(balance, path);
                    uint256 _buy_dai_amount = min(missing_underlying, _amount_out[_amount_out.length - 1]);
                    _buy_dai_amount = min(max_bonus_auction_amount, _buy_dai_amount);
                    require(bonus_token.approve(address(route), _buy_dai_amount), "LendingLeverageAuthGemJoin/failed-approve-bonus-token");
                    route.swapTokensForExactTokens(_buy_dai_amount, uint(0), path, address(this), block.timestamp + 3600);
                    require(ltk.mint(_buy_dai_amount) == 0, "LendingLeverageAuthGemJoin/failed-mint");

                    _updateLeverage(0);

                    balance = bonus_token.balanceOf(address(this));
                }
            } else {
                if (wunderlying > wgemsAdjusted) {
                    uint256 wexcess_underlying = sub(wunderlying, wgemsAdjusted);
                    excess_underlying = mul(wexcess_underlying, WAD ) / gemTo18ConversionFactor;

                    _updateLeverage(excess_underlying);

                    require(ltk.redeemUnderlying(excess_underlying) == 0, "LendingLeverageAuthGemJoin/failed-redemmUnderlying-excess");
                    require(gem.transfer(address(excess_delegator), excess_underlying), "LendingLeverageAuthGemJoin/failed-transfer-excess");
                }

                if (balance > 0) {
                    require(bonus_token.transfer(address(excess_delegator), balance), "LendingLeverageAuthGemJoin/failed-transfer-bonus-token");
                }

                if (balance > 0 || wunderlying > wgemsAdjusted) {
                    emit Delegate(msg.sender, address(excess_delegator), balance, excess_underlying);
                    excess_delegator.call();
                }
            }
        }
    }

    // --- Join method ---

    function join(address urn, uint256 wad, address _msgSender) public note auth lock {
        require(live == 1, "LendingLeverageAuthGemJoin/not-live");
        uint256 wad18 = mul(wad, 10 ** (18 - dec));
        require(int256(wad18) >= 0, "LendingLeverageAuthGemJoin/overflow");
        vat.slip(ilk, urn, int256(wad18));

        require(gem.transferFrom(_msgSender, address(this), wad), "LendingLeverageAuthGemJoin/failed-transfer");
        require(ltk.mint(wad) == 0, "LendingLeverageAuthGemJoin/failed-mint");

        _updateLeverage(0);
        _checkLiquidityIssue();
    }

    function exit(address guy, uint256 wad) public note lock {
        uint256 wad18 = mul(wad, gemTo18ConversionFactor);
        require(int256(wad18) >= 0, "LendingLeverageAuthGemJoin/overflow");
        vat.slip(ilk, msg.sender, -int256(wad18));

        _updateLeverage(wad);

        require(ltk.redeemUnderlying(wad) == 0, "LendingLeverageAuthGemJoin/failed-redemmUnderlying");
        require(gem.transfer(guy, wad), "LendingLeverageAuthGemJoin/failed-transfer");

        _checkLiquidityIssue();
    }

    function _updateLeverage(uint256 adjustment_amount) private {

        uint256 _balance_underlying = ltk.balanceOfUnderlying(address(this));
        uint256 _borrow_balance = ltk.borrowBalanceStored(address(this));
        uint256 _actual_underlying = sub(_balance_underlying, _borrow_balance);

        require(_actual_underlying >= adjustment_amount, "LendingLeverageAuthGemJoin/error-adjustment");
        _actual_underlying = sub(_actual_underlying, adjustment_amount);

        uint256 _future_underlying_balance = mul(_actual_underlying, WAD) / sub( WAD , coefficientTarget());

        if(_borrow_balance > _future_underlying_balance) {
            _unwind(add(_future_underlying_balance, adjustment_amount), _balance_underlying, _borrow_balance);
        } else {
            _wind(add(_future_underlying_balance, adjustment_amount), _balance_underlying, _borrow_balance);
        }
    }

    function _wind(uint256 total_underlying, uint256 _balance_underlying, uint256 _borrow_balance_stored) private {
        uint256 _max_collateral_factor = maxCollateralFactor();

        while (_balance_underlying < total_underlying) {

            uint256 _comp_borrow = sub(wmul(_balance_underlying, _max_collateral_factor), _borrow_balance_stored);
            _comp_borrow = mul(_comp_borrow, 99) / 100;

            uint256 future_underlying = add(_balance_underlying, _comp_borrow);
            if ( future_underlying > total_underlying) {
                _comp_borrow = sub(total_underlying, _balance_underlying);
            }

            require(ltk.borrow(_comp_borrow) == 0, "LendingLeverageAuthGemJoin/failed-borrow");
            require(ltk.mint(_comp_borrow) == 0, "LendingLeverageAuthGemJoin/failed-mint");

            _balance_underlying = add(_balance_underlying, _comp_borrow);
            _borrow_balance_stored = add(_borrow_balance_stored, _comp_borrow);
        }
    }

    function _unwind(uint256 total_underlying, uint256 _balance_underlying, uint256 _borrow_balance_stored) private {
        uint256 _max_collateral_factor = maxCollateralFactor();

        while (_balance_underlying > total_underlying) {

            uint256 _comp_redeem = sub(wmul(_balance_underlying, _max_collateral_factor), _borrow_balance_stored);
            _comp_redeem = mul(_comp_redeem, 99) / 100;

            uint256 _future_redeem = sub(_balance_underlying, _comp_redeem);
            if (_future_redeem < total_underlying) {
                _comp_redeem = sub(_balance_underlying, total_underlying);
            }

            require(ltk.redeemUnderlying(_comp_redeem) == 0, "LendingLeverageAuthGemJoin/failed-redeem");
            require(ltk.repayBorrow(_comp_redeem) == 0, "LendingLeverageAuthGemJoin/failed-repay");

            _balance_underlying = sub(_balance_underlying, _comp_redeem);
            _borrow_balance_stored = sub(_borrow_balance_stored, _comp_redeem);
        }
    }

    function _checkLiquidityIssue() private {

        uint256 _balance_underlying = ltk.balanceOfUnderlying(address(this));
        uint256 _borrow_balance_stored = ltk.borrowBalanceStored(address(this));
        (uint error, uint liquidity, uint shortfall) = lender.getAccountLiquidity(address(this));

        require(error == 0, "join the Discord");
        require(shortfall == 0, "account underwater");
        require(liquidity > 0, "account has excess collateral");

    }

    function maxCollateralFactor() public view returns (uint256) {
        (, uint256 maxColFactor) = ComLike(lender).markets(address(ltk));
        return min(maxColFactor, cf_max);
    }

    function coefficientTarget() public view returns (uint256) {
        return min(maxCollateralFactor() * 98 / 100, cf_target);
    }

}