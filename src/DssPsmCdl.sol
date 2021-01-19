pragma solidity 0.6.7;

import { GemJoinAbstract } from "dss-interfaces/dss/GemJoinAbstract.sol";
import { DaiJoinAbstract } from "dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "dss-interfaces/dss/VatAbstract.sol";

// Peg Stability Module Compound Dai Leverage
// Allows governance to leverage Dai using leverage join

contract DssPsmCdl {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'DssPsmCdl/Locked');unlocked = 0;_;unlocked = 1;}

    VatAbstract         immutable public vat;
    DaiJoinAbstract     immutable public daiJoin;
    GemJoinAbstract     immutable public leverageJoin;
    DaiAbstract         immutable public dai;
    bytes32             immutable public leverageIlk;

    // --- Events ---
    event Rely(address indexed user);
    event Deny(address indexed user);
    event File(bytes32 indexed what, uint256 data);

    event LeverageDai(address indexed owner, uint256 value);
    event DeleverageDai(address indexed owner, uint256 value);

    // --- Init ---
    constructor(address leverageJoin_, address daiJoin_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);

        GemJoinAbstract leverageJoin__ = leverageJoin = GemJoinAbstract(leverageJoin_);
        DaiJoinAbstract daiJoin__      = daiJoin      = DaiJoinAbstract(daiJoin_);
        VatAbstract vat__              = vat          = VatAbstract(address(daiJoin__.vat()));
        DaiAbstract dai__              = dai          = DaiAbstract(address(daiJoin__.dai()));
        leverageIlk                    = leverageJoin__.ilk();

        require(dai__.approve(leverageJoin_, uint256(-1)), "DssPsmCdl/failed-approve");
        require(dai__.approve(daiJoin_, uint256(-1)), "DssPsmCdl/failed-approve");

        vat__.hope(daiJoin_);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    function rad(uint256 wad) internal pure returns (uint256) {
        return mul(wad, 10 ** 27);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Primary Functions auth ---
    function leverage(uint amount) external lock auth {

        emit LeverageDai(msg.sender, amount);

        // flash mint
        vat.suck(address(this), address(this), rad(amount));
        daiJoin.exit(address(this), amount);

        leverageJoin.join(address(this), amount);
        vat.frob(leverageIlk, address(this), address(this), address(this), int256(amount), int256(amount));

        vat.heal(rad(amount));

    }

    function deleverage(uint amount) external lock auth {

        emit DeleverageDai(msg.sender, amount);

        // flash mint
        vat.suck(address(this), address(this), rad(amount));

        vat.frob(leverageIlk, address(this), address(this), address(this), -int256(amount), -int256(amount));
        leverageJoin.exit(address(this), amount);
        daiJoin.join(address(this), amount);

        vat.heal(rad(amount));
    }

}
