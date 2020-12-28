// SPDX-License-Identifier: AGPL-3.0-or-later

/// join-lending-auth.sol -- Non-standard token adapters

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2018-2020 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

import "dss/lib.sol";

interface VatLike {
    function slip(bytes32, address, int256) external;
    function gem(bytes32, address) external view returns (int256);
    function urns(bytes32, address) external view returns (uint256, uint256);
}

interface LTKLike {
    function mint(uint mintAmount) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function balanceOfUnderlying(address owner) external returns (uint);
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

// Authed GemJoin for a token that has a lower precision than 18 and it has decimals (like USDC)

contract LendingAuthGemJoin is LibNote{
    // --- Auth ---
    mapping (address => uint256) public wards;
    address[] private wards_address;
    function rely(address usr) external note auth {
        wards[usr] = 1;
        wards_address.push(usr);
    }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    VatLike public immutable vat;
    bytes32 public immutable ilk;
    GemLike public gem;
    uint256 public dec;
    uint256 public live;  // Access Flag
    LTKLike public immutable ltk;

    CalLike public excess_delegator;
    GemLike public immutable bonus_token;
    uint256 public immutable gemTo18ConversionFactor;

    event File(bytes32 indexed what, address data);

    constructor(address vat_, bytes32 ilk_, address gem_, address ltk_, address bonus_token_) public {
        gem = GemLike(gem_);
        dec = gem.decimals();
        require(dec <= 18, "LendingAuthGemJoin/decimals-18-or-higher");
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        ilk = ilk_;
        ltk = LTKLike(ltk_);
        excess_delegator = CalLike(0);
        bonus_token = GemLike(bonus_token_);
        gemTo18ConversionFactor = 10 ** (18 - dec);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "excessDelegator") excess_delegator = CalLike(data);
        else revert("LendingAuthGemJoin/file-unrecognized-param");

        emit File(what, data);
    }

    function cage() external note auth {
        live = 0;
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "LendingAuthGemJoin/overflow");
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, "LendingAuthGemJoin/underflow");
    }


    // --- harvest ---
    function sumGemsStored() view public returns (uint256 sum_){
        sum_ = 0;
        uint256 ink;
        for (uint i = 0; i < wards_address.length; i++) {
            (ink,) = vat.urns(ilk, wards_address[i]);
            sum_ = add(sum_, ink);
            sum_ = add(sum_, vat.gem(ilk, wards_address[i]));
        }
    }

    function harvest() external note auth {
        if (address(excess_delegator) != address(0)) {
            uint256 balance = bonus_token.balanceOf(address(this));
            uint256 gems = sumGemsStored();
            uint256 wgems = gems / WAD;
            uint256 wunderlying = mul(ltk.balanceOfUnderlying(address(this)), gemTo18ConversionFactor) / WAD;

            if (balance > 0) {
                require(bonus_token.transfer(address(excess_delegator), balance), "LendingAuthGemJoin/failed-transfer-bonus-token");
            }

            if (wunderlying > wgems) {
                uint256 wexcess_underlying = sub(wunderlying, wgems);
                uint256 excess_underlying = mul(wexcess_underlying, WAD ) / gemTo18ConversionFactor;
                require(ltk.redeemUnderlying(excess_underlying) == 0, "LendingAuthGemJoin/failed-redemmUnderlying-excess");
                require(gem.transfer(address(excess_delegator), excess_underlying), "LendingAuthGemJoin/failed-transfer-excess");
            }

            if (balance > 0 || wunderlying > wgems) {
                excess_delegator.call();
            }
        }
    }

    // --- Join ---

    function join(address urn, uint256 wad, address _msgSender) external note auth {
        require(live == 1, "LendingAuthGemJoin/not-live");
        uint256 wad18 = mul(wad, gemTo18ConversionFactor);
        require(int256(wad18) >= 0, "LendingAuthGemJoin/overflow");
        vat.slip(ilk, urn, int256(wad18));

        require(gem.transferFrom(_msgSender, address(this), wad), "LendingAuthGemJoin/failed-transfer-join");
        require(gem.approve(address(ltk), wad), "LendingAuthGemJoin/failed-approve-mint");
        require(ltk.mint(wad) == 0, "LendingAuthGemJoin/failed-mint");
    }

    function exit(address guy, uint256 wad) external note {
        uint256 wad18 = mul(wad, gemTo18ConversionFactor);
        require(int256(wad18) >= 0, "LendingAuthGemJoin/overflow");
        vat.slip(ilk, msg.sender, -int256(wad18));

        require(ltk.redeemUnderlying(wad) == 0, "LendingAuthGemJoin/failed-redemmUnderlying-exit");
        require(gem.transfer(guy, wad), "LendingAuthGemJoin/failed-transfer-exit");
    }

}