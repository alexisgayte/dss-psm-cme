pragma solidity 0.6.7;

interface HarvestAbstract {
    function harvest() external;
}

// Harvest for join
contract LendingHarvest {

    // --- Lock ---
    uint private unlocked = 1;
    modifier lock() {require(unlocked == 1, 'DssPsmCme/Locked');unlocked = 0;_;unlocked = 1;}

    // --- Data ---
    HarvestAbstract immutable public lendingJoin;

    // --- Init ---
    constructor(address lendingJoin_) public {
        lendingJoin = HarvestAbstract(lendingJoin_);
    }

    // --- Primary Functions ---
    function harvest() external lock {
        lendingJoin.harvest();
    }
}
