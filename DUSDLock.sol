// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct LockEntry {
    address owner;
    uint256 amount;
    uint256 withdrawn;
    uint256 lockedUntil;
    uint256 initialRewardsPerDeposit;
    uint256 claimedRewards;
}

contract DUSDLock {

    event DepositAdded(address depositer, uint256 amount, uint256 newTVL);
    event Withdrawal(address user, uint256 withdrawnFunds, uint256 newTVL);
    event RewardsAdded(uint256 addedRewards, uint256 blocksSinceLastRewards, uint256 currentTVL);
    event RewardsClaimed(address user, uint256 claimedRewards);

    mapping(address => LockEntry[]) public investments;

    //lockup period in seconds
    uint256 public immutable lockupPeriod;
    uint256 public immutable totalInvestCap;
    
    address owner;
    IERC20 public immutable coin;
    bool public exitCriteriaTriggered;

    uint256 public totalInvest;
    uint256 public totalWithdrawn;
    uint256 public totalRewards;
    uint256 public rewardsPerDeposit;

    uint256 public lastRewardsBlock;

    constructor(uint256 lockupTime, uint256 _totalCap, IERC20 lockedCoin) {
        owner= msg.sender;
        lockupPeriod= lockupTime;
        totalInvestCap= _totalCap;
        coin= lockedCoin;
        exitCriteriaTriggered= false;
    }

    function triggerExitCriteria() external {
        require(msg.sender == owner,"only owner allowed");
        exitCriteriaTriggered= true;
    }

    function currentTvl() public view returns(uint256 tvl) {
        tvl= totalInvest-totalWithdrawn;
    }


    function availableRewards(address addr,uint batch) public view returns(uint256 rew) {
        LockEntry[] storage entries= investments[addr];
        require(entries.length > batch,"DUSDLock: batch not found for this address");
        uint256 addedRewPerDeposit= rewardsPerDeposit - entries[batch].initialRewardsPerDeposit;
        uint256 remainingFunds= entries[batch].amount - entries[batch].withdrawn;
        uint256 totalRewardsForFunds= addedRewPerDeposit*remainingFunds/1e18;
        if(totalRewardsForFunds > entries[batch].claimedRewards) {
            return totalRewardsForFunds - totalRewardsForFunds;
        } else {
            return  0;
        }
    }

    function batchesInAddress(address addr) external view returns(uint count) {
        count= investments[addr].length;
    }

    function earliestUnlock(address addr) external view returns(uint256 timestamp,uint batchId) {
        LockEntry[] storage entries= investments[addr];
        timestamp = block.timestamp + lockupPeriod;
        batchId = 0;
        for(uint i= 0; i < entries.length;i++) {
            if(entries[i].lockedUntil < timestamp) {
                timestamp= entries[i].lockedUntil;
                batchId= i;
            }
        }
    }

    function lockup(uint256 funds) external {
        require(totalInvest+funds <= totalInvestCap,"DUSDLock: Total invest cap reached");
        coin.transferFrom(msg.sender,address(this),funds);
        LockEntry[] storage entries= investments[msg.sender];
        
        entries.push(LockEntry(msg.sender,funds,0,block.timestamp+lockupPeriod,rewardsPerDeposit,0));
        totalInvest += funds;

        emit DepositAdded(msg.sender, funds, currentTvl());
    }

    function withdraw(uint batchId) external returns(uint256 withdrawAmount) {
        LockEntry[] storage entries= investments[msg.sender];
        require(entries.length > batchId,"DUSDLock: batch not found for this address");
        require(availableRewards(msg.sender,batchId) == 0,"DUSDLock: claim rewards before withdraw");
        
        LockEntry storage entry= entries[batchId];
        require(entry.lockedUntil < block.timestamp || exitCriteriaTriggered,"DUSDLock: can not withdraw before lockup ended");
        require(entry.withdrawn == 0,"DUSDLock: already withdrawn");

        withdrawAmount= entry.amount;
        totalWithdrawn += withdrawAmount;
        entry.withdrawn+= withdrawAmount;
        coin.transfer(msg.sender, withdrawAmount);

        emit Withdrawal(msg.sender, withdrawAmount, currentTvl());
    }

    function claimRewards(uint batchId) external returns(uint256 claimed) {
        claimed= availableRewards(msg.sender,batchId);
        require(claimed > 0,"DUSDLock: no rewards to claim");
        LockEntry storage entry= investments[msg.sender][batchId];
        entry.claimedRewards += claimed;
        coin.transfer(msg.sender, claimed);

        emit RewardsClaimed(msg.sender, claimed);
    }

    function addRewards(uint256 rewardAmount) external {
        require(totalInvest-totalWithdrawn > 0,"can not distribute rewards on empty TVL");
        coin.transferFrom(msg.sender, address(this), rewardAmount);
        totalRewards += rewardAmount;

        rewardsPerDeposit += (rewardAmount * 1e18)/(totalInvest-totalWithdrawn);

        emit RewardsAdded(rewardAmount, block.number-lastRewardsBlock, totalInvest-totalWithdrawn);
        lastRewardsBlock= block.number;
    }

}