// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct LockEntry {
    uint256 amount;
    uint256 lockedUntil;
    uint256 initialRewardsPerDeposit;
    uint256 claimedRewards;
}

contract DUSDLock {
    using SafeERC20 for IERC20;

    event DepositAdded(address depositer, uint256 amount, uint256 newTVL);
    event Withdrawal(address user, uint256 withdrawnFunds, uint256 newTVL);
    event RewardsAdded(uint256 addedRewards, uint256 blocksSinceLastRewards, uint256 newRewardsClaimable, uint256 currentTvl);
    event RewardsClaimed(address user, uint256 claimedRewards, uint256 newRewardsClaimable);

    mapping(address => LockEntry[]) public investments;
    address[] public allAddresses;

    //lockup period in seconds
    uint256 public immutable lockupPeriod;
    uint256 public immutable totalInvestCap;
    
    address owner;
    IERC20 public immutable coin;
    bool public exitCriteriaTriggered;

    uint256 public totalInvest;
    uint256 public totalWithdrawn;
    uint256 public totalRewards;
    uint256 public totalClaimed;

    //keeps track of the total rewards per deposit since the beginning of the contract, number can only go up
    //is used for rewards calculation. as the total rewards for a specific deposits is (rewardsPerDeposit - rewardsPerDepositOnDeposit)*depositSize
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
        require(msg.sender == owner,"DUSDLock: only owner allowed to trigger exit criteria");
        exitCriteriaTriggered= true;
    }

    function currentTvl() public view returns(uint256) {
        return totalInvest-totalWithdrawn;
    }

    function currentOwnTvl() public view returns(uint256) {
        LockEntry[] memory entries= investments[msg.sender];
        uint256 ownTvl= 0;
        for(uint batchId = 0; batchId < entries.length; ++batchId) {
            LockEntry storage entry= investments[msg.sender][batchId];
            ownTvl += entry.amount; 
        }
        return ownTvl;
    }

    function currentRewardsClaimable() public view returns(uint256) {
        return totalRewards-totalClaimed;
    }

    function nrOfAddresses() external view returns(uint256) {
        return allAddresses.length;
    }

    function getAllAddress() external view returns(address[] memory) {
        return allAddresses;
    }

    function availableRewards(address addr,uint batch) public view returns(uint256) {
        LockEntry[] memory entries= investments[addr];
        require(entries.length > batch,"DUSDLock: batch not found for this address");
        uint256 addedRewPerDeposit= rewardsPerDeposit - entries[batch].initialRewardsPerDeposit;
        uint256 totalRewardsForFunds= addedRewPerDeposit*entries[batch].amount/1e18;
        if(totalRewardsForFunds > entries[batch].claimedRewards) {
            return totalRewardsForFunds - entries[batch].claimedRewards;
        } else {
            return  0;
        }
    }

    function availableOwnRewards() public view returns (uint256) {
        LockEntry[] memory entries= investments[msg.sender];
        uint256 ownRewards= 0;
        for(uint batchId = 0; batchId < entries.length; ++batchId) {
            ownRewards += availableRewards(msg.sender, batchId);
        }
        return ownRewards;
    }

    function batchesInAddress(address addr) external view returns(uint) {
        return investments[addr].length;
    }

    function earliestUnlock(address addr) external view returns(uint256 timestamp,uint batchId) {
        LockEntry[] memory entries= investments[addr];
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
        require(currentTvl()+funds <= totalInvestCap,"DUSDLock: Total invest cap reached");
        coin.safeTransferFrom(msg.sender,address(this),funds);
        LockEntry[] storage entries= investments[msg.sender];
        if(entries.length == 0) allAddresses.push(msg.sender);
        entries.push(LockEntry(funds,block.timestamp+lockupPeriod,rewardsPerDeposit,0));
        totalInvest += funds;

        emit DepositAdded(msg.sender, funds, currentTvl());
    }

    function withdraw(uint batchId) external returns(uint256 withdrawAmount) {
        LockEntry[] storage entries= investments[msg.sender];
        require(entries.length > batchId,"DUSDLock: batch not found for this address");
        
        LockEntry storage entry= entries[batchId];
        require(entry.lockedUntil < block.timestamp || exitCriteriaTriggered,"DUSDLock: can not withdraw before lockup ended");
        require(entry.amount > 0,"DUSDLock: already withdrawn");
        
        if(availableRewards(msg.sender,batchId) > 0) _claimBatch(msg.sender,batchId);
        
        withdrawAmount= entry.amount;
        totalWithdrawn += withdrawAmount;
        entry.amount= 0;
        coin.safeTransfer(msg.sender, withdrawAmount);

        emit Withdrawal(msg.sender, withdrawAmount, currentTvl());
    }

    function claimRewards(uint batchId) external returns(uint256 claimed) {
        return _claimBatch(msg.sender,batchId);
    }

    function _claimBatch(address addr, uint batchId) internal returns(uint256 claimed) {
        claimed= availableRewards(addr,batchId);
        require(claimed > 0,"DUSDLock: no rewards to claim");
        LockEntry storage entry= investments[addr][batchId];
        entry.claimedRewards += claimed;
        totalClaimed += claimed;
        coin.safeTransfer(addr, claimed);

        emit RewardsClaimed(addr, claimed, currentRewardsClaimable());
    }

    function claimAllRewards() external returns(uint256 total) {
        LockEntry[] memory entries= investments[msg.sender];
        total= 0;
        for(uint batchId = 0; batchId < entries.length; ++batchId) {
            uint256 claimed= availableRewards(msg.sender,batchId);
            if(claimed > 0) {
                LockEntry storage entry= investments[msg.sender][batchId];
                entry.claimedRewards += claimed;
                total += claimed; 
            }
        }
        require(total > 0,"DUSDLock: no rewards to claim");
        totalClaimed += total;
        coin.safeTransfer(msg.sender, total);

        emit RewardsClaimed(msg.sender, total, currentRewardsClaimable());
    }

    function addRewards(uint256 rewardAmount) external {
        require(currentTvl() > 0,"DUSDLock: can not distribute rewards on empty TVL");
        coin.safeTransferFrom(msg.sender, address(this), rewardAmount);
        totalRewards += rewardAmount;

        rewardsPerDeposit += (rewardAmount * 1e18)/currentTvl();

        emit RewardsAdded(rewardAmount, block.number-lastRewardsBlock, currentRewardsClaimable(),currentTvl());
        lastRewardsBlock= block.number;
    }
}