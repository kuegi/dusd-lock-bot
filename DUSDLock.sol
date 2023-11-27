// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct LockEntry {
    uint256 amount;
    uint256 lockedUntil;
}

contract DUSDLock {

    mapping(address => LockEntry[]) public investments;
    mapping(address => uint256) public rewards;
    address[] private allAddresses;

    //lockup period in seconds
    uint256 public lockupPeriod;
    
    address owner;
    IERC20 public coin;
    bool public exitCriteriaTriggered;

    uint256 totalInvest;


    constructor(uint256 lockupTime,IERC20 lockedCoin) {
        owner= msg.sender;
        lockupPeriod= lockupTime;
        coin= lockedCoin;
        exitCriteriaTriggered= false;
    }

    function triggerExitCriteria() external {
        require(msg.sender == owner,"only owner allowed");
        exitCriteriaTriggered= true;
    }

    function nrAddresses() public view returns(uint256 amount) {
        amount= allAddresses.length;
    }

    function getAddress(uint256 index) public view returns(address addr) {
        addr= allAddresses[index];
    }

    function availableRewards(address addr) public view returns(uint256 rew) {
        rew = rewards[addr];
    }

    function activeInvest(address addr) public view returns(uint256 invest) {
        LockEntry[] storage entries= investments[addr];
        invest= 0;
        for(uint i= 0; i < entries.length;i++) {
            invest += entries[i].amount;
        }
    }

    function earliestUnlock(address addr) public view returns(uint256 timestamp) {
        LockEntry[] storage entries= investments[addr];
        timestamp = block.timestamp + lockupPeriod;
        for(uint i= 0; i < entries.length;i++) {
            if(entries[i].lockedUntil < timestamp) {
                timestamp= entries[i].lockedUntil;
            }
        }
    }

    function lockup(uint256 funds) external {
        coin.transferFrom(msg.sender,address(this),funds);
        LockEntry[] storage entries= investments[msg.sender];
        if(entries.length == 0) {
            allAddresses.push(msg.sender);
        }
        entries.push(LockEntry(funds,block.timestamp+lockupPeriod));
        totalInvest += funds;
    }

    function withdraw() external returns(uint256 foundWithdrawable) {
        LockEntry[] storage entries= investments[msg.sender];
        foundWithdrawable= 0;
        for(uint i= 0; i < entries.length;i++){
            LockEntry storage entry= entries[i];
            if(entry.lockedUntil < block.timestamp || exitCriteriaTriggered) {
                foundWithdrawable+= entry.amount;
                entry.amount= 0;
            }
        } 
        if(foundWithdrawable > 0) {
            totalInvest -= foundWithdrawable;
            coin.transfer(msg.sender, foundWithdrawable);
        }
    }

    function claimRewards() public returns(uint256 claimed) {
        claimed= rewards[msg.sender];
        if(claimed > 0) {
            rewards[msg.sender]= 0;
            coin.transfer(msg.sender, claimed);
        }
    }

    //ment to be called by BBB sending rewards in, but can be called by anyone who wants to incentivize
    function addRewards(uint256 rewardAmount) external {
        coin.transferFrom(msg.sender, address(this), rewardAmount);
        uint256 distributedRewards= 0;
        for(uint i= 0; i < allAddresses.length;i++) {
            address addr= allAddresses[i];
            uint256 invest= activeInvest(addr);
            uint256 rewardPart= (invest*rewardAmount)/totalInvest;
            distributedRewards+= rewardPart;
            rewards[addr] += rewardPart;
        }
        require(distributedRewards <= rewardAmount,"floating error in the wrong direction");
    }

}