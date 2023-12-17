// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

struct LockEntry {
    uint256 amount;
    uint256 lockedUntil;
    uint256 initialRewardsPerDeposit;
    uint256 claimedRewards;
}

contract DUSDLock is ERC721Enumerable {
    using SafeERC20 for IERC20;

    event DepositAdded(address depositer, uint256 batchId, uint256 amount, uint256 newTVL);
    event Withdrawal(address user, uint256 batchId, uint256 withdrawnFunds, uint256 newTVL);
    event RewardsAdded(uint256 addedRewards, uint256 blocksSinceLastRewards, uint256 newRewardsClaimable, uint256 currentTvl);
    event RewardsClaimed(address user, uint256 batchId,  uint256 claimedRewards, uint256 newRewardsClaimable);

    LockEntry[] public investments;

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

    constructor(uint256 lockupTime, uint256 _totalCap, IERC20 lockedCoin) 
                    ERC721(string.concat(Strings.toString(lockupTime/86400)," day DUSD Lock"),string.concat("LOCK",Strings.toString(lockupTime/86400))) {
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

    function currentTVLOfAddress(address addr) public view returns(uint256) {
        uint256 ownTvl= 0;
        uint256 tokens= balanceOf(addr);
        for(uint idx = 0; idx < tokens; ++idx) {
            LockEntry storage entry= investments[tokenOfOwnerByIndex(addr,idx)];
            ownTvl += entry.amount; 
        }
        return ownTvl;
    }

    function currentRewardsClaimable() public view returns(uint256) {
        return totalRewards-totalClaimed;
    }

    function availableRewards(uint256 batchId) public view returns(uint256) {
        LockEntry memory entry= investments[batchId];
        uint256 addedRewPerDeposit= rewardsPerDeposit - entry.initialRewardsPerDeposit;
        uint256 totalRewardsForFunds= addedRewPerDeposit*entry.amount/1e18;
        if(totalRewardsForFunds > entry.claimedRewards) {
            return totalRewardsForFunds - entry.claimedRewards;
        } else {
            return  0;
        }
    }

    function allAvailableRewards(address addr) public view returns (uint256) {
        uint256 allRewards= 0;
        uint256 tokens= balanceOf(addr);
        for(uint idx = 0; idx < tokens; ++idx) {
            allRewards += availableRewards(tokenOfOwnerByIndex(addr,idx));
        }
        return allRewards;
    }

    function earliestUnlock(address addr) external view returns(uint256 timestamp,uint earliestBatchId) {
        timestamp = block.timestamp + lockupPeriod;
        earliestBatchId = 0;
        uint256 tokens= balanceOf(addr);
        require(tokens > 0,"DUSDLock: no tokens found in address");
        for(uint idx = 0; idx < tokens; ++idx) {
            uint256 batchId= tokenOfOwnerByIndex(addr,idx);
            if(investments[batchId].lockedUntil < timestamp) {
                timestamp= investments[batchId].lockedUntil;
                earliestBatchId= batchId;
            }
        }
    }

    function lockup(uint256 funds) external {
        require(currentTvl()+funds <= totalInvestCap,"DUSDLock: Total invest cap reached");
        coin.safeTransferFrom(msg.sender,address(this),funds);
        investments.push(LockEntry(funds,block.timestamp+lockupPeriod,rewardsPerDeposit,0));
        totalInvest += funds;
        _safeMint(msg.sender,investments.length-1);

        emit DepositAdded(msg.sender, investments.length, funds, currentTvl());
    }

    function withdraw(uint batchId) external returns(uint256 withdrawAmount) {
        LockEntry storage entry= investments[batchId];
        require(_ownerOf(batchId) == msg.sender,"DUSDLock: sender must be owner");
        require(entry.lockedUntil < block.timestamp || exitCriteriaTriggered,"DUSDLock: can not withdraw before lockup ended");
        require(entry.amount > 0,"DUSDLock: already withdrawn");
        
        if(availableRewards(batchId) > 0) _claimBatch(batchId);
        
        withdrawAmount= entry.amount;
        totalWithdrawn += withdrawAmount;
        entry.amount= 0;
        _burn(batchId);
        coin.safeTransfer(msg.sender, withdrawAmount);

        emit Withdrawal(msg.sender, batchId, withdrawAmount, currentTvl());
    }

    function claimRewards(uint batchId) external returns(uint256 claimed) {
        require(_ownerOf(batchId) == msg.sender,"DUSDLock: sender must be owner");
        return _claimBatch(batchId);
    }

    function _claimBatch(uint batchId) internal returns(uint256 claimed) {
        claimed= availableRewards(batchId);
        require(claimed > 0,"DUSDLock: no rewards to claim");
        LockEntry storage entry= investments[batchId];
        entry.claimedRewards += claimed;
        totalClaimed += claimed;
        coin.safeTransfer(_ownerOf(batchId) , claimed);

        emit RewardsClaimed(_ownerOf(batchId), batchId, claimed, currentRewardsClaimable());
    }

    function claimAllRewards() external returns(uint256 total) {
        total= 0;
        uint256 tokens= balanceOf(msg.sender);
        for(uint idx = 0; idx < tokens; ++idx) {
            uint256 batchId= tokenOfOwnerByIndex(msg.sender, idx);
            uint256 claimed= availableRewards(batchId);
            if(claimed > 0) {
                LockEntry storage entry= investments[batchId];
                entry.claimedRewards += claimed;
                total += claimed; 
                emit RewardsClaimed(msg.sender, batchId, claimed, currentRewardsClaimable());
            }
        }
        require(total > 0,"DUSDLock: no rewards to claim");
        totalClaimed += total;
        coin.safeTransfer(msg.sender, total);

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