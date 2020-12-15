# MIP32: Peg Stability Module - Compound Mix Exposure

## Preamble
```
MIP#: 32
Title: Peg Stability Module - Compound Mix Exposure
Author(s): Alexis
Contributors: None
Type: Technical
Status: Request for Comments (RFC)
Date Proposed: 2020-12-18
Date Ratified: <yyyy-mm-dd>
Dependencies: PSM
Replaces: n/a
License: AGPL3+
```
## References

* The proposed [dss-psm-cme](https://github.com/alexisgayte/dss-psm-cme) implementation

## Sentence Summary

This proposal provides a smart contract implementation of a Peg Stability Module extends.

## Paragraph Summary

The extension acts exactly as the PSM but with a leverage on Dai. With the current `join` this would have no benefit.  
Therefore, it comes with a "lending gem join".  

**The join** is generic to maker and can be plug to any lender using the interface, but more specifically to `compound`.
The join takes in input a collateral and lend it, on the join `exit` it acts on the opposite way. It can be applied to Dai or any compound collaterals.

However, if we want to use it as a leverage gem, it needs to be Dai to Dai.

Optional fees `tin` and `tout` can be activated as well which send a fraction of the trade into the `vow`.

This PSM will have X2 leverage on the input USDC via compound. We will have 2 urns one `cDai` and one `cUsdc`.
 

## Component Summary

**MIP32a1: PSM extension:** Very simple modification of the existent PSM.

**MIP32a2: Lending Join:** The join is based on existing join-5-auth.

## Motivation

Currently usdc inside the PSM are inefficient and need to be diversified. 
Using `cDai` and `cUsdc` will bring this diversification.

## Specification

### MIP32a1: Proposed code

duplicated PSM main code:
```

        gemJoin.join(address(this), gemAmt, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        daiJoin.exit(address(this), gemAmt18);

        leverageGemJoin.join(address(this), gemAmt18, address(this));
        vat.frob(leverageIlk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        leverageDaiJoin.exit(usr, daiAmt);

        vat.move(address(this), vow, mul(fee, RAY));
```

vs

```
        gemJoin.join(address(this), gemAmt, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        vat.move(address(this), vow, mul(fee, RAY));
        daiJoin.exit(usr, daiAmt);

```

![dss-psm-cme](https://github.com/alexisgayte/dss-psm-cme/blob/master/dss-psm-cme.png?raw=true)

#### Test cases

see [DssPsmCme.t.sol](https://github.com/alexisgayte/dss-psm-cme/blob/master/src/DssPsmCme.t.sol)

### MIP32a2: Proposed code

The code is very generic here as well, however there is an exotic method `callDelegator` to siphon off the bonus token.
The delegator can be set up by governance.

```
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

```
see [DssPsmCmeLending.t.sol](https://github.com/alexisgayte/dss-psm-cme/blob/master/src/DssPsmCmeLending.t.sol)

see [join-lending-auth.t.sol](https://github.com/alexisgayte/dss-psm-cme/blob/master/src/join-lending-auth.t.sol)

![lending-join](https://github.com/alexisgayte/dss-psm-cme/blob/master/lending-join.png?raw=true)


### MIP32b1: Security considerations

Need to be considered.

### MIP32b2: Licensing
   - [AGPL3+](https://www.gnu.org/licenses/agpl-3.0.en.html)