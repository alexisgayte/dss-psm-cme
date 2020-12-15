// SPDX-License-Identifier: AGPL-3.0-or-later

/// join-5-auth.sol -- Non-standard token adapters

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

pragma solidity ^0.6.7;

import "dss/lib.sol";

interface VatLike {
    function slip(bytes32, address, int256) external;
}

interface LTKLike {
    function mint(uint mintAmount) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
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
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    VatLike public vat;
    bytes32 public ilk;
    GemLike public gem;
    uint256 public dec;
    uint256 public live;  // Access Flag
    LTKLike public ltk;

    CalLike public bonus_delegator;
    GemLike public bonus_token;
    uint256 public duration;
    uint256 public last_timestamp;

    event Delegate(uint256 balance);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);

    constructor(address vat_, bytes32 ilk_, address gem_, address ltk_) public {
        gem = GemLike(gem_);
        dec = gem.decimals();
        require(dec < 18, "GemJoin5/decimals-18-or-higher");
        wards[msg.sender] = 1;
        live = 1;
        vat = VatLike(vat_);
        ilk = ilk_;
        ltk = LTKLike(ltk_);
        bonus_delegator = CalLike(0);
        last_timestamp = block.timestamp;

    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "bonusDelegator") bonus_delegator = CalLike(data);
        else if (what == "bonusToken") bonus_token = GemLike(data);
        else revert("LendingAuthGemJoin/file-unrecognized-param");

        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "duration") duration = data;
        else revert("LendingAuthGemJoin/file-unrecognized-param");

        emit File(what, data);
    }

    function cage() external note auth {
        live = 0;
    }

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "LendingAuthGemJoin/overflow");
    }

    function join(address urn, uint256 wad, address _msgSender) public note auth {
        require(live == 1, "LendingAuthGemJoin/not-live");
        uint256 wad18 = mul(wad, 10 ** (18 - dec));
        require(int256(wad18) >= 0, "LendingAuthGemJoin/overflow");
        vat.slip(ilk, urn, int256(wad18));

        require(gem.transferFrom(_msgSender, address(this), wad), "LendingAuthGemJoin/failed-transfer");
        gem.approve(address(ltk), wad);
        assert(ltk.mint(wad) == 0);
        _callDelegator();
    }

    function exit(address guy, uint256 wad) public note {
        uint256 wad18 = mul(wad, 10 ** (18 - dec));
        require(int256(wad18) >= 0, "LendingAuthGemJoin/overflow");
        vat.slip(ilk, msg.sender, -int256(wad18));

        require(ltk.redeemUnderlying(wad) == 0, "LendingAuthGemJoin/failed-redemmUnderlying");
        require(gem.transfer(guy, wad), "LendingAuthGemJoin/failed-transfer");
        _callDelegator();
    }

    function _callDelegator() private {
        if (address(bonus_token) != address(0) && address(bonus_delegator) != address(0)) {
            uint256 balance = bonus_token.balanceOf(address(this));
            if (block.timestamp - last_timestamp > duration && balance > 0) {
                last_timestamp = block.timestamp;
                require(block.timestamp !=0, "LendingAuthGemJoin/failed-transfer");
                bonus_token.transfer(address(bonus_delegator), balance);
                bonus_delegator.call();
                emit Delegate(balance);
            }
        }
    }
}