pragma solidity =0.6.7 >=0.5.12;

import "lib/dss-interfaces/src/dapp/DSPauseAbstract.sol";
import "lib/dss-interfaces/src/dapp/DSTokenAbstract.sol";
import "lib/dss-interfaces/src/dss/CatAbstract.sol";
import "lib/dss-interfaces/src/dss/GemJoinAbstract.sol";
import "lib/dss-interfaces/src/dss/IlkRegistryAbstract.sol";
import "lib/dss-interfaces/src/dss/JugAbstract.sol";
import "lib/dss-interfaces/src/dss/MedianAbstract.sol";
import "lib/dss-interfaces/src/dss/OsmAbstract.sol";
import "lib/dss-interfaces/src/dss/OsmMomAbstract.sol";
import "lib/dss-interfaces/src/dss/FlipperMomAbstract.sol";
import "lib/dss-interfaces/src/dss/SpotAbstract.sol";
import "lib/dss-interfaces/src/dss/VatAbstract.sol";
import "lib/dss-interfaces/src/dss/ChainlogAbstract.sol";
import "lib/dss-interfaces/src/dss/FlipAbstract.sol";

import "lib/dss/lib/ds-value/src/value.sol";
import "lib/dss/src/flip.sol";

import "../DssPsmCme.sol";
import {LendingAuthGemJoin} from "../join-lending-auth.sol";
import { BurnDelegator } from "../BurnDelegator.sol";

interface PsmCmeAbstract {
    function wards(address) external returns (uint256);
    function vat() external returns (address);
    function gemJoin() external returns (address);
    function leverageGemJoin() external returns (address);
    function dai() external returns (address);
    function daiJoin() external returns (address);
    function ilk() external returns (bytes32);
    function leverageIlk() external returns (bytes32);
    function vow() external returns (address);
    function tin() external returns (uint256);
    function tout() external returns (uint256);
    function file(bytes32 what, uint256 data) external;
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
}

interface DelegatorAbstract {
    function file(bytes32 what, uint256 data) external;
    function file(bytes32 what, address data) external;
    function call() external;
    function processDai() external;
    function processComp() external;
    function processUsdc() external;
}



contract SpellAction {
    // Office hours enabled if true
    bool constant public officeHours = true;

    // MAINNET ADDRESSES
    //
    // The contracts in this list should correspond to MCD core contracts, verify
    //  against the current release list at:
    //     https://changelog.makerdao.com/releases/mainnet/active/contracts.json
    ChainlogAbstract constant CHANGELOG = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // PSM-USDC-A
    address constant CUSDC              = 0x39AA39c021dfbaE8faC545936693aC917d5E7563;
    address constant CDAI               = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    address constant UNISWAP_ROUTER_V2  = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;


    bytes32 constant ILK_PSM_LENDER_USDC_A     = "PSM-LENDER-USDC-A";
    bytes32 constant ILK_PSM_LENDER_DAI_A      = "PSM-LENDER-DAI-A";

// decimals & precision
    uint256 constant THOUSAND = 10 ** 3;
    uint256 constant MILLION  = 10 ** 6;
    uint256 constant WAD      = 10 ** 18;
    uint256 constant RAY      = 10 ** 27;
    uint256 constant RAD      = 10 ** 45;

    // Many of the settings that change weekly rely on the rate accumulator
    // described at https://docs.makerdao.com/smart-contract-modules/rates-module
    // To check this yourself, use the following rate calculation (example 8%):
    //
    // $ bc -l <<< 'scale=27; e( l(1.08)/(60 * 60 * 24 * 365) )'
    //
    // A table of rates can be found at
    //    https://ipfs.io/ipfs/QmefQMseb3AiTapiAKKexdKHig8wroKuZbmLtPLv4u2YwW
    //
    uint256 constant ZERO_PERCENT_RATE            = 1000000000000000000000000000;

    modifier limited {
        if (officeHours) {
            uint day = (block.timestamp / 1 days + 3) % 7;
            require(day < 5, "Can only be cast on a weekday");
            uint hour = block.timestamp / 1 hours % 24;
            require(hour >= 14 && hour < 21, "Outside office hours");
        }
        _;
    }

    function execute() external limited {

        // Bump version
        CHANGELOG.setVersion("1.2.4");

        // Create Psm cme / lender join / delegator
        {
            address MCD_VAT         = CHANGELOG.getAddress("MCD_VAT");
            address MCD_JUG         = CHANGELOG.getAddress("MCD_JUG");
            address USDC            = CHANGELOG.getAddress("USDC");
            address COMP            = CHANGELOG.getAddress("COMP");
            address MCD_DAI         = CHANGELOG.getAddress("MCD_DAI");
            address MCD_JOIN_DAI    = CHANGELOG.getAddress("MCD_JOIN_DAI");
            address MCD_VOW         = CHANGELOG.getAddress("MCD_VOW");
            address MCD_PSM_USDC_A  = CHANGELOG.getAddress("MCD_PSM_USDC_A");
            address MCD_GOV         = CHANGELOG.getAddress("MCD_GOV");


            address MCD_JOIN_LENDER_BURN_DELEGATOR = address(new BurnDelegator(address(MCD_GOV), address(MCD_DAI), address(USDC), address(COMP)));
            address MCD_JOIN_LENDER_USDC_A = address(new LendingAuthGemJoin(address(MCD_VAT), ILK_PSM_LENDER_USDC_A, address(USDC), address(CUSDC), address(COMP)));
            address MCD_JOIN_LENDER_DAI_A = address(new LendingAuthGemJoin(address(MCD_VAT), ILK_PSM_LENDER_DAI_A, address(MCD_DAI), address(CDAI), address(COMP)));
            address MCD_PSM_CME_COMP = address(new DssPsmCme(address(MCD_JOIN_LENDER_USDC_A), address(MCD_JOIN_LENDER_DAI_A), address(MCD_JOIN_DAI), address(MCD_VOW)));

            require(GemJoinAbstract(MCD_JOIN_LENDER_USDC_A).vat() == MCD_VAT, "join-vat-not-match");
            require(GemJoinAbstract(MCD_JOIN_LENDER_USDC_A).ilk() == ILK_PSM_LENDER_USDC_A, "join-ilk-not-match");
            require(GemJoinAbstract(MCD_JOIN_LENDER_USDC_A).gem() == USDC, "join-gem-not-match");
            require(GemJoinAbstract(MCD_JOIN_LENDER_USDC_A).dec() == DSTokenAbstract(USDC).decimals(), "join-dec-not-match");

            require(GemJoinAbstract(MCD_JOIN_LENDER_DAI_A).vat() == MCD_VAT, "join-vat-not-match");
            require(GemJoinAbstract(MCD_JOIN_LENDER_DAI_A).ilk() == ILK_PSM_LENDER_DAI_A, "join-ilk-not-match");
            require(GemJoinAbstract(MCD_JOIN_LENDER_DAI_A).gem() == MCD_DAI, "join-gem-not-match");
            require(GemJoinAbstract(MCD_JOIN_LENDER_DAI_A).dec() == DSTokenAbstract(MCD_DAI).decimals(), "join-dec-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).vat() == MCD_VAT, "psm-vat-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).dai() == MCD_DAI, "psm-dai-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).daiJoin() == MCD_JOIN_DAI, "psm-dai-join-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).ilk() == ILK_PSM_LENDER_USDC_A, "psm-ilk-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).leverageIlk() == ILK_PSM_LENDER_DAI_A, "psm-ilk-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).vow() == MCD_VOW, "psm-vow-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).gemJoin() == MCD_JOIN_LENDER_USDC_A, "psm-gem-join-not-match");
            require(PsmCmeAbstract(MCD_PSM_CME_COMP).leverageGemJoin() == MCD_JOIN_LENDER_DAI_A, "psm-leverage-gem-join-not-match");

            // Allow new Join to modify Vat registry
            VatAbstract(MCD_VAT).rely(address(MCD_JOIN_LENDER_USDC_A));
            VatAbstract(MCD_VAT).rely(address(MCD_JOIN_LENDER_DAI_A));

            // link and authorized Join lender to excessDelegator
            LendingAuthGemJoin(MCD_JOIN_LENDER_BURN_DELEGATOR).rely(address(MCD_JOIN_LENDER_USDC_A));
            LendingAuthGemJoin(MCD_JOIN_LENDER_BURN_DELEGATOR).rely(address(MCD_JOIN_LENDER_DAI_A));
            LendingAuthGemJoin(MCD_JOIN_LENDER_USDC_A).file("excessDelegator", address(MCD_JOIN_LENDER_BURN_DELEGATOR));
            LendingAuthGemJoin(MCD_JOIN_LENDER_DAI_A).file("excessDelegator", address(MCD_JOIN_LENDER_BURN_DELEGATOR));

            // Allow PSM-CME to join
            LendingAuthGemJoin(MCD_JOIN_LENDER_USDC_A).rely(address(MCD_PSM_CME_COMP));
            LendingAuthGemJoin(MCD_JOIN_LENDER_DAI_A).rely(address(MCD_PSM_CME_COMP));
            // Set PSM-CME param
            DssPsmCme(MCD_PSM_CME_COMP).file("tin", 1 * WAD / 1000);
            DssPsmCme(MCD_PSM_CME_COMP).file("tout", 1 * WAD / 1000);

            // set Delegator param
            DelegatorAbstract(MCD_JOIN_LENDER_BURN_DELEGATOR).file("psm", address(MCD_PSM_USDC_A));
            DelegatorAbstract(MCD_JOIN_LENDER_BURN_DELEGATOR).file("route", address(UNISWAP_ROUTER_V2));

            VatAbstract(MCD_VAT).init(ILK_PSM_LENDER_USDC_A);
            VatAbstract(MCD_VAT).init(ILK_PSM_LENDER_DAI_A);
            JugAbstract(MCD_JUG).init(ILK_PSM_LENDER_USDC_A);
            JugAbstract(MCD_JUG).init(ILK_PSM_LENDER_DAI_A);


            CHANGELOG.setAddress("MCD_JOIN_LENDER_BURN_DELEGATOR", MCD_JOIN_LENDER_BURN_DELEGATOR);
            CHANGELOG.setAddress("MCD_JOIN_LENDER_USDC_A", MCD_JOIN_LENDER_USDC_A);
            CHANGELOG.setAddress("MCD_JOIN_LENDER_DAI_A", MCD_JOIN_LENDER_DAI_A);
            CHANGELOG.setAddress("MCD_PSM_CME_COMP", MCD_PSM_CME_COMP);
            CHANGELOG.setAddress("UNISWAP_ROUTER_V2", UNISWAP_ROUTER_V2);

        }

        // create flip for Join lender USDC and DAI
        {
            address MCD_VAT         = CHANGELOG.getAddress("MCD_VAT");
            address MCD_CAT         = CHANGELOG.getAddress("MCD_CAT");
            address MCD_SPOT        = CHANGELOG.getAddress("MCD_SPOT");
            address MCD_END         = CHANGELOG.getAddress("MCD_END");
            address PIP_USDC        = CHANGELOG.getAddress("PIP_USDC");
            address FLIPPER_MOM     = CHANGELOG.getAddress("FLIPPER_MOM");
            address ILK_REGISTRY    = CHANGELOG.getAddress("ILK_REGISTRY");

            address MCD_JOIN_LENDER_USDC_A       = CHANGELOG.getAddress("MCD_JOIN_LENDER_USDC_A");
            address MCD_JOIN_LENDER_DAI_A        = CHANGELOG.getAddress("MCD_JOIN_LENDER_DAI_A");

            address MCD_FLIP_PSM_CME_USDC_A = address(new Flipper(MCD_VAT, MCD_CAT, ILK_PSM_LENDER_USDC_A));
            address MCD_FLIP_PSM_CME_DAI_A = address(new Flipper(MCD_VAT, MCD_CAT, ILK_PSM_LENDER_DAI_A));
            address PIP_DAI = address(new DSValue());


            require(FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).vat() == MCD_VAT, "flip-vat-not-match");
            require(FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).cat() == MCD_CAT, "flip-cat-not-match");
            require(FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).ilk() == ILK_PSM_LENDER_USDC_A, "flip-ilk-not-match");
            require(FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).vat() == MCD_VAT, "flip-vat-not-match");
            require(FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).cat() == MCD_CAT, "flip-cat-not-match");
            require(FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).ilk() == ILK_PSM_LENDER_DAI_A, "flip-ilk-not-match");


            // Set the USDC/DAI PIP in the Spotter
            SpotAbstract(MCD_SPOT).file(ILK_PSM_LENDER_USDC_A, "pip", PIP_USDC);
            SpotAbstract(MCD_SPOT).file(ILK_PSM_LENDER_DAI_A, "pip", PIP_DAI);

            // Set the PSM-USDC-A Flipper in the Cat
            CatAbstract(MCD_CAT).file(ILK_PSM_LENDER_USDC_A, "flip", MCD_FLIP_PSM_CME_USDC_A);
            CatAbstract(MCD_CAT).file(ILK_PSM_LENDER_DAI_A, "flip", MCD_FLIP_PSM_CME_DAI_A);


            // Update PSM-USDC-A spot value in Vat
            SpotAbstract(MCD_SPOT).poke(ILK_PSM_LENDER_USDC_A);
            SpotAbstract(MCD_SPOT).poke(ILK_PSM_LENDER_DAI_A);

            // Allow list PSM - USDC
            CatAbstract(MCD_CAT).rely(MCD_FLIP_PSM_CME_USDC_A);
            FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).rely(MCD_CAT);
            FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).rely(MCD_END);
            FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).rely(FLIPPER_MOM);
            // Disallow Cat to kick auctions in PSM-USDC-A Flipper
            // !!!!!!!! Only for certain collaterals that do not trigger liquidations like USDC-A)
            FlipperMomAbstract(FLIPPER_MOM).deny(MCD_FLIP_PSM_CME_USDC_A);

            // Allow list PSM - DAI
            CatAbstract(MCD_CAT).rely(MCD_FLIP_PSM_CME_DAI_A);
            FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).rely(MCD_CAT);
            FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).rely(MCD_END);
            FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).rely(FLIPPER_MOM);
            // Disallow Cat to kick auctions in PSM-USDC-A Flipper
            FlipperMomAbstract(FLIPPER_MOM).deny(MCD_FLIP_PSM_CME_DAI_A);

            IlkRegistryAbstract(ILK_REGISTRY).add(address(MCD_JOIN_LENDER_USDC_A));
            IlkRegistryAbstract(ILK_REGISTRY).add(address(MCD_JOIN_LENDER_DAI_A));

            CHANGELOG.setAddress("MCD_FLIP_PSM_CME_DAI_A", MCD_FLIP_PSM_CME_DAI_A);
            CHANGELOG.setAddress("MCD_FLIP_PSM_CME_USDC_A", MCD_FLIP_PSM_CME_USDC_A);
            CHANGELOG.setAddress("PIP_DAI", PIP_DAI);

        }

        {
            address MCD_VAT                   = CHANGELOG.getAddress("MCD_VAT");
            address MCD_CAT                   = CHANGELOG.getAddress("MCD_CAT");
            address MCD_JUG                   = CHANGELOG.getAddress("MCD_JUG");
            address MCD_FLIP_PSM_CME_USDC_A   = CHANGELOG.getAddress("MCD_FLIP_PSM_CME_USDC_A");
            address MCD_FLIP_PSM_CME_DAI_A    = CHANGELOG.getAddress("MCD_FLIP_PSM_CME_DAI_A");
            address MCD_SPOT                  = CHANGELOG.getAddress("MCD_SPOT");

            // Set PSM-LENDER-USDC-A generic param
            VatAbstract(MCD_VAT).file(ILK_PSM_LENDER_USDC_A, "line", 500 * THOUSAND * RAD);
            CatAbstract(MCD_CAT).file(ILK_PSM_LENDER_USDC_A, "dunk", 50 * THOUSAND * RAD);
            CatAbstract(MCD_CAT).file(ILK_PSM_LENDER_USDC_A, "chop", 113 * WAD / 100);
            JugAbstract(MCD_JUG).file(ILK_PSM_LENDER_USDC_A, "duty", ZERO_PERCENT_RATE);
            FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).file("beg", 103 * WAD / 100);
            FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).file("ttl", 6 hours);
            FlipAbstract(MCD_FLIP_PSM_CME_USDC_A).file("tau", 6 hours);
            SpotAbstract(MCD_SPOT).file(ILK_PSM_LENDER_USDC_A, "mat", 100 * RAY / 100);

            // Set the PSM-LENDER-DAI-A generic param
            VatAbstract(MCD_VAT).file(ILK_PSM_LENDER_DAI_A, "line", 500 * THOUSAND * RAD);
            CatAbstract(MCD_CAT).file(ILK_PSM_LENDER_DAI_A, "dunk", 50 * THOUSAND * RAD);
            CatAbstract(MCD_CAT).file(ILK_PSM_LENDER_DAI_A, "chop", 113 * WAD / 100);
            JugAbstract(MCD_JUG).file(ILK_PSM_LENDER_DAI_A, "duty", ZERO_PERCENT_RATE);
            FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).file("beg", 103 * WAD / 100);
            FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).file("ttl", 6 hours);
            FlipAbstract(MCD_FLIP_PSM_CME_DAI_A).file("tau", 6 hours);
            SpotAbstract(MCD_SPOT).file(ILK_PSM_LENDER_DAI_A, "mat", 100 * RAY / 100);


            // Set the global debt ceiling
            // + 500K for PSM-CMS-USDC-A + 500K for PSM-CMS-DAI-A
            VatAbstract(MCD_VAT).file("Line",
                VatAbstract(MCD_VAT).Line()
                + 500 * THOUSAND * RAD
                + 500 * THOUSAND * RAD
            );

        }

    }
}

contract DssPsmCompMixExposureLenderJoinSpell {
    ChainlogAbstract constant CHANGELOG =
    ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // TODO add back the immutable
    DSPauseAbstract  public pause;
    address          public action;
    bytes32          public tag;
    uint256          public expiration;
    uint256         public eta;
    bytes           public sig;
    bool            public done;

    // Provides a descriptive tag for bot consumption
    // This should be modified weekly to provide a summary of the actions
    // Hash: seth keccak -- "$(wget https://raw.githubusercontent.com/makerdao/community/ed4b0067a116ff03c0556d5e95dca69773ee7fe4/governance/votes/Community%20Executive%20vote%20-%20December%2020%2C%202020.md -q -O - 2>/dev/null)"
    string constant public description =
    "2020-12-20 MakerDAO Executive Spell | Hash: 0xe9f640a65d72e16bc75bffad53c5cb9e292df53c70a94c2b8975b47f196946b5";

    function officeHours() external view returns (bool) {
        return SpellAction(action).officeHours();
    }

    constructor() public {
        pause = DSPauseAbstract(CHANGELOG.getAddress("MCD_PAUSE"));
        sig = abi.encodeWithSignature("execute()");
        bytes32 _tag;
        address _action = action = address(new SpellAction());
        assembly { _tag := extcodehash(_action) }
        tag = _tag;
        expiration = block.timestamp + 30 days;
    }

    function nextCastTime() external view returns (uint256 castTime) {
        require(eta != 0, "DSSSpell/spell-not-scheduled");
        castTime = block.timestamp > eta ? block.timestamp : eta; // Any day at XX:YY

        if (SpellAction(action).officeHours()) {
            uint256 day    = (castTime / 1 days + 3) % 7;
            uint256 hour   = castTime / 1 hours % 24;
            uint256 minute = castTime / 1 minutes % 60;
            uint256 second = castTime % 60;

            if (day >= 5) {
                castTime += (6 - day) * 1 days;                 // Go to Sunday XX:YY
                castTime += (24 - hour + 14) * 1 hours;         // Go to 14:YY UTC Monday
                castTime -= minute * 1 minutes + second;        // Go to 14:00 UTC
            } else {
                if (hour >= 21) {
                    if (day == 4) castTime += 2 days;           // If Friday, fast forward to Sunday XX:YY
                    castTime += (24 - hour + 14) * 1 hours;     // Go to 14:YY UTC next day
                    castTime -= minute * 1 minutes + second;    // Go to 14:00 UTC
                } else if (hour < 14) {
                    castTime += (14 - hour) * 1 hours;          // Go to 14:YY UTC same day
                    castTime -= minute * 1 minutes + second;    // Go to 14:00 UTC
                }
            }
        }
    }

    function schedule() external {
        require(block.timestamp <= expiration, "DSSSpell/spell-has-expired");
        require(eta == 0, "DSSSpell/spell-already-scheduled");
        eta = block.timestamp + DSPauseAbstract(pause).delay();
        pause.plot(action, tag, sig, eta);
    }

    function cast() external {
        require(!done, "DSSSpell/spell-already-cast");
        done = true;
        pause.exec(action, tag, sig, eta);
    }
}