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

contract LendingAuthGemJoin is LibNote {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth note { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth note { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'DssPsmCme/Locked');unlocked = 0;_;unlocked = 1;}

    // --- Data ---
    VatLike public immutable vat;
    bytes32 public immutable ilk;
    GemLike public gem;
    uint256 public dec;
    uint256 public live;  // Access Flag
    LTKLike public immutable ltk;
    uint256 public total;  // total gems

    CalLike public excessDelegator;
    GemLike public immutable bonusToken;
    uint256 public immutable gemTo18ConversionFactor;

    // --- Event ---
    event Rely(address indexed user);
    event Deny(address indexed user);
    event File(bytes32 indexed what, address data);
    event Delegate(address indexed sender, address indexed delegator, uint256 bonus, uint256 gem);

    // --- Init ---
    constructor(address vat_, bytes32 ilk_, address gem_, address ltk_, address bonusToken_) public {
        gem = GemLike(gem_);
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        ilk = ilk_;
        ltk = LTKLike(ltk_);
        excessDelegator = CalLike(0);
        bonusToken = GemLike(bonusToken_);
        dec = gem.decimals();
        total = 0;
        require(dec <= 18, "LendingAuthGemJoin/decimals-18-or-higher");
        gemTo18ConversionFactor = 10 ** (18 - dec);
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

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "excess_delegator") excessDelegator = CalLike(data);
        else revert("LendingAuthGemJoin/file-unrecognized-param");

        emit File(what, data);
    }

    function cage() external note auth {
        live = 0;
    }


    // --- harvest ---
    function harvest() external note lock auth {
        if (address(excessDelegator) != address(0)) {
            uint256 _balance = bonusToken.balanceOf(address(this));
            uint256 _total = total;
            uint256 _underlying = ltk.balanceOfUnderlying(address(this));
            uint256 _excessUnderlying = 0;

            if (_balance > 0) {
                require(bonusToken.transfer(address(excessDelegator), _balance), "LendingAuthGemJoin/failed-transfer-bonus-token");
            }

            if (_underlying > _total) {
                _excessUnderlying = sub(_underlying, _total);
                require(ltk.redeemUnderlying(_excessUnderlying) == 0, "LendingAuthGemJoin/failed-redemmUnderlying-excess");
                require(gem.transfer(address(excessDelegator), _excessUnderlying), "LendingAuthGemJoin/failed-transfer-excess");
            }

            if (_balance > 0 || _underlying > _total) {
                emit Delegate(msg.sender, address(excessDelegator), _balance, _excessUnderlying);
            }
        }
    }

    // --- Join ---
    function join(address guy, uint256 wad) external note auth {
        require(live == 1, "LendingAuthGemJoin/not-live");
        uint256 wad18 = mul(wad, gemTo18ConversionFactor);
        require(int256(wad18) >= 0, "LendingAuthGemJoin/overflow");
        vat.slip(ilk, guy, int256(wad18));

        total = add(total, wad);

        require(gem.transferFrom(guy, address(this), wad), "LendingAuthGemJoin/failed-transfer-join");
        require(gem.approve(address(ltk), wad), "LendingAuthGemJoin/failed-approve-mint");
        require(ltk.mint(wad) == 0, "LendingAuthGemJoin/failed-mint");
    }

    function exit(address guy, uint256 wad) external note {
        uint256 wad18 = mul(wad, gemTo18ConversionFactor);
        require(int256(wad18) >= 0, "LendingAuthGemJoin/overflow");
        vat.slip(ilk, msg.sender, -int256(wad18));

        total = sub(total, wad);

        require(ltk.redeemUnderlying(wad) == 0, "LendingAuthGemJoin/failed-redemmUnderlying-exit");
        require(gem.transfer(guy, wad), "LendingAuthGemJoin/failed-transfer-exit");
    }

}