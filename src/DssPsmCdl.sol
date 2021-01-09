pragma solidity 0.6.7;

import { DaiJoinAbstract } from "dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "dss-interfaces/dss/VatAbstract.sol";


interface AuthLendingGemJoinAbstract {
    function dec() external view returns (uint256);
    function vat() external view returns (address);
    function ilk() external view returns (bytes32);
    function join(address, uint256, address) external;
    function exit(address, uint256) external;
    function harvest() external;
}

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
    AuthLendingGemJoinAbstract immutable public daiLendingJoin;
    AuthLendingGemJoinAbstract immutable public daiLendingLeverageJoin;
    DaiAbstract         immutable public dai;
    DaiJoinAbstract     immutable public daiJoin;
    bytes32             immutable public daiLendingLeverageIlk;
    bytes32             immutable public daiLendingIlk;

// --- Events ---
    event Rely(address indexed user);
    event Deny(address indexed user);
    event File(bytes32 indexed what, uint256 data);

    event LeverageLendingDai(address indexed owner, uint256 value);
    event LeverageLendingLeverageDai(address indexed owner, uint256 value);
    event DeLeverageLendingDai(address indexed owner, uint256 value);
    event DeLeverageLendingLeverageDai(address indexed owner, uint256 value);
    // --- Init ---
    constructor(address daiLendingJoin_, address daiLendingLeverageJoin_, address daiJoin_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);

        AuthLendingGemJoinAbstract daiLendingJoin__ = daiLendingJoin = AuthLendingGemJoinAbstract(daiLendingJoin_);
        AuthLendingGemJoinAbstract daiLendingLeverageJoin__ = daiLendingLeverageJoin = AuthLendingGemJoinAbstract(daiLendingLeverageJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(daiJoin__.vat()));
        DaiAbstract dai__ = dai = DaiAbstract(address(daiJoin__.dai()));
        daiLendingIlk = daiLendingJoin__.ilk();
        daiLendingLeverageIlk = daiLendingLeverageJoin__.ilk();

        require(dai__.approve(daiLendingJoin_, uint256(-1)), "DssPsmCdl/failed-approve");
        require(dai__.approve(daiLendingLeverageJoin_, uint256(-1)), "DssPsmCdl/failed-approve");
        require(dai__.approve(daiJoin_, uint256(-1)), "DssPsmCdl/failed-approve");
        vat__.hope(daiJoin_);
    }

    // --- Primary Functions auth ---
    function leverageLendingVault(uint amount) external lock auth {

        // flash mint
        dai.mint(address(this), amount);

        emit LeverageLendingDai(msg.sender, amount);

        daiLendingJoin.join(address(this), amount, address(this));
        vat.frob(daiLendingIlk, address(this), address(this), address(this), int256(amount), int256(amount));
        daiJoin.exit(address(this), amount);

        dai.burn(address(this), amount);
    }

    function leverageLendingLeverageVault(uint amount) external lock auth {

        // flash mint
        dai.mint(address(this), amount);

        emit LeverageLendingLeverageDai(msg.sender, amount);

        daiLendingLeverageJoin.join(address(this), amount, address(this));
        vat.frob(daiLendingLeverageIlk, address(this), address(this), address(this), int256(amount), int256(amount));
        daiJoin.exit(address(this), amount);

        dai.burn(address(this), amount);
    }

    function deleverageLendingVault(uint amount) external lock auth {

        // flash mint
        dai.mint(address(this), amount);

        emit DeLeverageLendingDai(msg.sender, amount);

        daiJoin.join(address(this), amount);
        vat.frob(daiLendingIlk, address(this), address(this), address(this), -int256(amount), -int256(amount));
        daiLendingJoin.exit(address(this), amount);

        dai.burn(address(this), amount);
    }

    function deleverageLendingLeverageVault(uint amount) external lock auth {

        // flash mint
        dai.mint(address(this), amount);

        emit DeLeverageLendingLeverageDai(msg.sender, amount);

        daiJoin.join(address(this), amount);
        vat.frob(daiLendingLeverageIlk, address(this), address(this), address(this), -int256(amount), -int256(amount));
        daiLendingLeverageJoin.exit(address(this), amount);

        dai.burn(address(this), amount);
    }

}
