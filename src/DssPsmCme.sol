pragma solidity 0.6.7;

import { DaiJoinAbstract } from "dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "dss-interfaces/dss/VatAbstract.sol";
import { VowAbstract } from "dss-interfaces/dss/VowAbstract.sol";


interface AuthLendingGemJoinAbstract {
    function dec() external view returns (uint256);
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function join(address, uint256, address) external;
    function exit(address, uint256) external;
    function harvest() external;
}

// Peg Stability Module With Dai Leverage
// Allows anyone to go between Dai and the Gem by pooling the liquidity
// An optional fee is charged for incoming and outgoing transfers

contract DssPsmCme {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'DssPsmCme/Locked');unlocked = 0;_;unlocked = 1;}


    VatAbstract immutable public vat;
    AuthLendingGemJoinAbstract immutable public gemJoin;
    AuthLendingGemJoinAbstract immutable public leverageGemJoin;
    DaiAbstract         immutable public dai;
    DaiJoinAbstract     immutable public daiJoin;
    DaiJoinAbstract     immutable public leverageDaiJoin;
    bytes32             immutable public ilk;
    bytes32             immutable public leverageIlk;
    VowAbstract         immutable public vow;

    uint256             immutable internal to18ConversionFactor;

    uint256             public tin;         // toll in [wad]
    uint256             public tout;        // toll out [wad]

    // --- Events ---
    event Rely(address indexed user);
    event Deny(address indexed user);
    event File(bytes32 indexed what, uint256 data);
    event SellGem(address indexed owner, uint256 value, uint256 fee);
    event BuyGem(address indexed owner, uint256 value, uint256 fee);

    // --- Init ---
    constructor(address gemJoin_, address daiJoin_, address leverageGemJoin_, address leverageDaiJoin_,  address vow_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        AuthLendingGemJoinAbstract gemJoin__ = gemJoin = AuthLendingGemJoinAbstract(gemJoin_);
        AuthLendingGemJoinAbstract leverageGemJoin__ = leverageGemJoin = AuthLendingGemJoinAbstract(leverageGemJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        leverageDaiJoin = DaiJoinAbstract(leverageDaiJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(gemJoin__.vat()));
        DaiAbstract dai__ = dai = DaiAbstract(address(daiJoin__.dai()));
        ilk = gemJoin__.ilk();
        leverageIlk = leverageGemJoin__.ilk();
        vow = VowAbstract(vow_);
        to18ConversionFactor = 10 ** (18 - gemJoin__.dec());
        require(dai__.approve(daiJoin_, uint256(-1)), "DssPsmCme/failed-approve");
        require(dai__.approve(leverageDaiJoin_, uint256(-1)), "DssPsmCme/failed-approve");
        require(dai__.approve(leverageGemJoin_, uint256(-1)), "DssPsmCme/failed-approve");
        vat__.hope(daiJoin_);
        vat__.hope(leverageDaiJoin_);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function file(bytes32 what, uint256 data) external auth {
        if (what == "tin") {
            require(data < WAD , "DssPsmCme/more-100-percent");
            tin = data;
        }
        else if (what == "tout") {
            require(data < WAD , "DssPsmCme/more-100-percent");
            tout = data;
        }
        else revert("DssPsmCme/file-unrecognized-param");

        emit File(what, data);
    }

    // --- Primary Functions ---
    function _harvest() private {
        leverageGemJoin.harvest();
        gemJoin.harvest();
    }

    function harvest() external lock {
        _harvest();
    }

    function sellGem(address usr, uint256 gemAmt) external lock {
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);
        uint256 prefee = mul(gemAmt18, tin);
        require(int256(prefee) >= 0, "DssPsmCme/overflow-fee-sell-gem");
        uint256 fee = prefee / WAD;
        uint256 daiAmt = sub(gemAmt18, fee);

        emit SellGem(usr, gemAmt, fee);

        gemJoin.join(address(this), gemAmt, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        daiJoin.exit(address(this), gemAmt18);

        leverageGemJoin.join(address(this), gemAmt18, address(this));
        vat.frob(leverageIlk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        leverageDaiJoin.exit(usr, daiAmt);

        vat.move(address(this), address(vow), mul(fee, RAY));
        _harvest();

    }

    function buyGem(address usr, uint256 gemAmt) external lock {
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);
        uint256 prefee = mul(gemAmt18, tout);
        require(int256(prefee) >= 0, "DssPsmCme/overflow-fee-buy-gem");
        uint256 fee = prefee / WAD;
        uint256 daiAmt = add(gemAmt18, fee);

        emit BuyGem(usr, gemAmt, fee);

        require(dai.transferFrom(msg.sender, address(this), daiAmt), "DssPsmCme/failed-transfer");

        leverageDaiJoin.join(address(this), gemAmt18);
        vat.frob(leverageIlk, address(this), address(this), address(this), -int256(gemAmt18), -int256(gemAmt18));
        leverageGemJoin.exit(address(this), gemAmt18);

        daiJoin.join(address(this), daiAmt);
        vat.frob(ilk, address(this), address(this), address(this), -int256(gemAmt18), -int256(gemAmt18));
        gemJoin.exit(usr, gemAmt);

        vat.move(address(this), address(vow), mul(fee, RAY));
        _harvest();

    }

}
