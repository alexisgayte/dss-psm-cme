pragma solidity 0.6.7;

import { DaiJoinAbstract } from "dss-interfaces/dss/DaiJoinAbstract.sol";
import { GemJoinAbstract } from "dss-interfaces/dss/GemJoinAbstract.sol";
import { DaiAbstract } from "dss-interfaces/dss/DaiAbstract.sol";
import { GemAbstract } from "dss-interfaces/ERC/GemAbstract.sol";
import { VatAbstract } from "dss-interfaces/dss/VatAbstract.sol";
import { VowAbstract } from "dss-interfaces/dss/VowAbstract.sol";


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


    VatAbstract         immutable public vat;
    VowAbstract         immutable public vow;
    bytes32             immutable public ilk;
    bytes32             immutable public leverageIlk;
    GemJoinAbstract     immutable public gemJoin;
    GemJoinAbstract     immutable public leverageGemJoin;
    DaiJoinAbstract     immutable public daiJoin;
    GemAbstract         immutable public token;
    DaiAbstract         immutable public dai;

    uint256             immutable internal to18ConversionFactor;

    uint256             public tin;         // toll in [wad]
    uint256             public tout;        // toll out [wad]
    uint256             public price;       // price [wad]

// --- Events ---
    event Rely(address indexed user);
    event Deny(address indexed user);
    event File(bytes32 indexed what, uint256 data);
    event Sell(address indexed owner, uint256 value, uint256 fee);
    event Buy(address indexed owner, uint256 value, uint256 fee);

    // --- Init ---
    constructor(address gemJoin_, address leverageGemJoin_, address daiJoin_, address vow_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        GemJoinAbstract gemJoin__ = gemJoin = GemJoinAbstract(gemJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        GemJoinAbstract leverageGemJoin__ = leverageGemJoin = GemJoinAbstract(leverageGemJoin_);
        VatAbstract vat__   = vat   = VatAbstract(address(gemJoin__.vat()));
        DaiAbstract dai__   = dai   = DaiAbstract(address(daiJoin__.dai()));
        GemAbstract token__ = token = GemAbstract(address(gemJoin__.gem()));
        ilk = gemJoin__.ilk();
        leverageIlk = leverageGemJoin__.ilk();
        vow = VowAbstract(vow_);
        to18ConversionFactor = 10 ** (18 - gemJoin__.dec());
        require(dai__.approve(daiJoin_, uint256(-1)), "DssPsmCme/failed-approve");
        require(dai__.approve(leverageGemJoin_, uint256(-1)), "DssPsmCme/failed-approve");
        require(token__.approve(gemJoin_, uint256(-1)), "DssPsmCme/failed-approve");
        vat__.hope(daiJoin_);
        price = 1*WAD;
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

    function sell(address usr, uint256 gemAmt) external lock {
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);
        uint256 fee = mul(gemAmt18, tin) / WAD;
        uint256 daiAmt = sub(gemAmt18, fee);

        emit Sell(usr, gemAmt, fee);

        require(token.transferFrom(msg.sender, address(this), gemAmt), "DssPsmCme/failed-sell-transfer");

        gemJoin.join(address(this), gemAmt);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        daiJoin.exit(address(this), gemAmt18);

        leverageGemJoin.join(address(this), gemAmt18);
        vat.frob(leverageIlk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        daiJoin.exit(usr, daiAmt);

        vat.move(address(this), address(vow), mul(fee, RAY));

    }

    function buy(address usr, uint256 gemAmt) external lock {
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);
        uint256 fee = mul(gemAmt18, tout) / WAD;
        uint256 daiAmt = add(gemAmt18, fee);

        emit Buy(usr, gemAmt, fee);

        require(dai.transferFrom(msg.sender, address(this), daiAmt), "DssPsmCme/failed-buy-transfer");

        daiJoin.join(address(this), gemAmt18);
        vat.frob(leverageIlk, address(this), address(this), address(this), -int256(gemAmt18), -int256(gemAmt18));
        leverageGemJoin.exit(address(this), gemAmt18);

        daiJoin.join(address(this), daiAmt);
        vat.frob(ilk, address(this), address(this), address(this), -int256(gemAmt18), -int256(gemAmt18));
        gemJoin.exit(usr, gemAmt);

        vat.move(address(this), address(vow), mul(fee, RAY));
    }

}
