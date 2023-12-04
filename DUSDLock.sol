// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct LockEntry {
    uint256 amount;
    uint256 lockedUntil;
}

contract DUSDLock {

    event DepositAdded(address depositer, uint256 amount, uint256 newTVL);
    event Withdrawal(address user, uint256 withdrawnFunds, uint256 newTVL);
    event RewardsAdded(uint256 addedRewards, uint256 blocksSinceLastRewards, uint256 currentTVL);
    event RewardsClaimed(address user, uint256 claimedRewards);

    mapping(address => LockEntry[]) public investments;
    mapping(address => uint256) activeInvestPerAddress;
    mapping(address => uint256) rewards;
    address[] private allAddresses;

    //lockup period in seconds
    uint256 public immutable lockupPeriod;
    uint256 public immutable totalInvestCap;
    
    address owner;
    IERC20 public immutable coin;
    bool public exitCriteriaTriggered;

    uint256 public totalInvest;
    uint256 public totalAvailableRewards;

    uint256 totalRewardsToDistribute;
    uint256 indexToStartNextRewardBatch;
    uint256 lastRewardsBlock;

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

    function nrAddresses() public view returns(uint256 amount) {
        amount= allAddresses.length;
    }

    function getAddress(uint256 index) public view returns(address addr) {
        addr= allAddresses[index];
    }

    function availableRewards(address addr) public view returns(uint256 rew) {
        rew = rewards[addr];
    }

    function investmentsOfAddress(address addr) public view returns(uint count) {
        count= investments[addr].length;
    }

    function activeInvest(address addr) public view returns(uint256 invest) {
        return activeInvestPerAddress[addr];
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
        require(totalInvest+funds <= totalInvestCap,"Total invest cap reached");
        require(indexToStartNextRewardBatch == 0,"can't add funds during reward distribution");
        coin.transferFrom(msg.sender,address(this),funds);
        LockEntry[] storage entries= investments[msg.sender];
        if(entries.length == 0) {
            allAddresses.push(msg.sender);
        }
        entries.push(LockEntry(funds,block.timestamp+lockupPeriod));
        activeInvestPerAddress[msg.sender] += funds;
        totalInvest += funds;

        emit DepositAdded(msg.sender, funds, totalInvest);
    }

    function withdraw() external returns(uint256 foundWithdrawable) {
        require(indexToStartNextRewardBatch == 0,"can't remove funds during reward distribution");
        LockEntry[] storage entries= investments[msg.sender];
        foundWithdrawable= 0;
        for(uint i= 0; i < entries.length;i++){
            LockEntry storage entry= entries[i];
            if(entry.lockedUntil < block.timestamp || exitCriteriaTriggered) {
                foundWithdrawable+= entry.amount;
                entry.amount= 0;
            }
        } 
        if(foundWithdrawable > 0 && activeInvestPerAddress[msg.sender] >= foundWithdrawable) {
            totalInvest -= foundWithdrawable;
            activeInvestPerAddress[msg.sender] -= foundWithdrawable;
            coin.transfer(msg.sender, foundWithdrawable);

            emit Withdrawal(msg.sender, foundWithdrawable, totalInvest);
        }
    }

    function claimRewards() public returns(uint256 claimed) {
        claimed= rewards[msg.sender];
        if(claimed > 0) {
            rewards[msg.sender]= 0;
            coin.transfer(msg.sender, claimed);
            totalAvailableRewards -= claimed;

            emit RewardsClaimed(msg.sender, claimed);
        }
    }

    function needRewardDistribution() external view returns(bool) {
        return totalRewardsToDistribute > 0;
    }

    //meant to be called by native bot sending rewards in, but can be called by anyone who wants to incentivize
    function addRewardsForDistribution(uint256 rewardAmount,uint initialDistributionBatch) external {
        require(indexToStartNextRewardBatch == 0,"reward distribution in progress");
        require(rewardAmount > 0,"rewards can't be empty");
        require(totalInvest > 0,"can't distribute rewards on empty invest");
        totalRewardsToDistribute += rewardAmount;
        coin.transferFrom(msg.sender, address(this), rewardAmount);

        emit RewardsAdded(rewardAmount, block.number-lastRewardsBlock, totalInvest);
        lastRewardsBlock= block.number;

        //start distribution, if not too many addresses are in, we do not need extra call 
        //TODO: determine first batchSize
        if(initialDistributionBatch > 0) {
            distributeRewards(initialDistributionBatch);
        }
    }

    //must be called in reasonable batch sizes to not go over the gas limit
    function distributeRewards(uint256 maxAddressesInBatch) public {
        require(totalRewardsToDistribute > 0,"no rewards to distribute");
        require(maxAddressesInBatch > 0,"empty batch is not allowed");
        uint256 batchEnd= indexToStartNextRewardBatch + maxAddressesInBatch;
        if(batchEnd >= allAddresses.length) {
            batchEnd= allAddresses.length;
        }
        for(uint i= indexToStartNextRewardBatch; i < batchEnd;++i) {
            address addr= allAddresses[i];
            uint256 rewardPart= (activeInvestPerAddress[addr] * totalRewardsToDistribute)/totalInvest;
            rewards[addr] += rewardPart;
            totalAvailableRewards += rewardPart;
        }
        if(batchEnd >= allAddresses.length) {
            totalRewardsToDistribute= 0;
            indexToStartNextRewardBatch= 0;
        } else {
            indexToStartNextRewardBatch= batchEnd;
        }
    }

}