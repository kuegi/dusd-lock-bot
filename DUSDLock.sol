// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

struct LockEntry {
    uint256 amount;
    uint256 lockedUntil;
    uint256 initialRewardsPerDeposit;
    uint256 claimedRewards;
}

contract Bond is ERC721Enumerable, Ownable {

    BondManager public immutable manager;

    constructor(string memory name_, string memory symbol_, BondManager _manager) ERC721(name_,symbol_) Ownable(address(_manager)) {
        manager= _manager;
    }

    function getTokenData(uint256 tokenId) view external returns (LockEntry memory) {
        return manager.batchData(tokenId);
    }

    function safeMint(address receiver, uint256 tokenId) onlyOwner external {
        _safeMint(receiver, tokenId);
    }

    function burn(uint256 tokenId) onlyOwner external {
        _burn(tokenId);
    }
}

contract BondManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error BondsNoBondsInAddress(address owner);
    error BondsTotalCapReached();
    error BondsNotOwner(address user, uint256 batchId);
    error BondsNotWithdrawable(uint256 batchId);
    error BondsInvalidBond(uint256 batchId);
    error BondsAlreadyWithdrawn(uint256 batchId);
    error BondsNoRewards();
    error BondsEmptyTVL();

    event DepositAdded(address depositer, uint256 batchId, uint256 amount, uint256 newTVL);
    event Withdrawal(address user, uint256 batchId, uint256 withdrawnFunds, uint256 newTVL);
    event RewardsAdded(uint256 addedRewards, uint256 blocksSinceLastRewards, uint256 newRewardsClaimable, uint256 currentTvl);
    event RewardsClaimed(address user, uint256 batchId,  uint256 claimedRewards, uint256 newRewardsClaimable);

    LockEntry[] public investments;

    //lockup period in seconds
    uint256 public immutable lockupPeriod;
    uint256 public immutable totalInvestCap;
    
    IERC20 public immutable coin;
    Bond public immutable bondToken;
    bool public exitCriteriaTriggered;

    uint256 public totalInvest;
    uint256 public totalWithdrawn;
    uint256 public totalRewards;
    uint256 public totalClaimed;

    //keeps track of the total rewards per deposit since the beginning of the contract, number can only go up
    //is used for rewards calculation. as the total rewards for a specific deposits is (rewardsPerDeposit - rewardsPerDepositOnDeposit)*depositSize
    uint256 public rewardsPerDeposit;

    uint256 public lastRewardsBlock;

    constructor(uint256 lockupTime, uint256 _totalCap, IERC20 lockedCoin) Ownable(msg.sender){
        bondToken= new Bond(string.concat(Strings.toString(lockupTime/86400)," day DUSD Bond"),string.concat("DUSDBond",Strings.toString(lockupTime/86400)),this); 
        lockupPeriod= lockupTime;
        totalInvestCap= _totalCap;
        coin= lockedCoin;
        exitCriteriaTriggered= false;
    }

    function triggerExitCriteria() external onlyOwner {
        exitCriteriaTriggered= true;
    }

    function currentTvl() public view returns(uint256) {
        return totalInvest-totalWithdrawn;
    }

    function batchData(uint256 batchId) external view returns(LockEntry memory) {
        if(batchId >= investments.length) {
            revert BondsInvalidBond(batchId);
        }
        return investments[batchId];
    }

    function currentTVLOfAddress(address addr) public view returns(uint256) {
        uint256 ownTvl= 0;
        uint256 tokens= bondToken.balanceOf(addr);
        for(uint idx = 0; idx < tokens; ++idx) {
            LockEntry storage entry= investments[bondToken.tokenOfOwnerByIndex(addr,idx)];
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
        uint256 tokens= bondToken.balanceOf(addr);
        for(uint idx = 0; idx < tokens; ++idx) {
            allRewards += availableRewards(bondToken.tokenOfOwnerByIndex(addr,idx));
        }
        return allRewards;
    }

    function earliestUnlock(address addr) external view returns(uint256 timestamp,uint earliestBatchId) {
        timestamp = block.timestamp + lockupPeriod;
        earliestBatchId = 0;
        uint256 tokens= bondToken.balanceOf(addr);
        if( tokens == 0) {
            revert BondsNoBondsInAddress(addr);
        }
        for(uint idx = 0; idx < tokens; ++idx) {
            uint256 batchId= bondToken.tokenOfOwnerByIndex(addr,idx);
            if(investments[batchId].lockedUntil < timestamp) {
                timestamp= investments[batchId].lockedUntil;
                earliestBatchId= batchId;
            }
        }
    }

    function lockup(uint256 funds) external nonReentrant {
        if(currentTvl()+funds > totalInvestCap) {
            revert BondsTotalCapReached();
        }
        coin.safeTransferFrom(msg.sender,address(this),funds);
        investments.push(LockEntry(funds,block.timestamp+lockupPeriod,rewardsPerDeposit,0));
        totalInvest += funds;
        uint256 batchId= investments.length-1;
        bondToken.safeMint(msg.sender,batchId);

        emit DepositAdded(msg.sender, batchId, funds, currentTvl());
    }

    function withdraw(uint batchId) external nonReentrant returns(uint256 withdrawAmount) {
        if(batchId >= investments.length) {
            revert BondsInvalidBond(batchId);
        }
        LockEntry storage entry= investments[batchId];
        if(bondToken.ownerOf(batchId) != msg.sender) {
            revert BondsNotOwner(msg.sender, batchId);
        }
        if(entry.lockedUntil > block.timestamp && !exitCriteriaTriggered) {
            revert BondsNotWithdrawable(batchId);
        }
        if(entry.amount == 0) {
            revert BondsAlreadyWithdrawn(batchId);
        }
        
        if(availableRewards(batchId) > 0) _claimBatch(batchId);
        
        withdrawAmount= entry.amount;
        totalWithdrawn += withdrawAmount;
        entry.amount= 0;
        bondToken.burn(batchId);
        coin.safeTransfer(msg.sender, withdrawAmount);

        emit Withdrawal(msg.sender, batchId, withdrawAmount, currentTvl());
    }

    function claimRewards(uint batchId) external nonReentrant returns(uint256 claimed) {
         if(batchId >= investments.length) {
            revert BondsInvalidBond(batchId);
        }
        if(bondToken.ownerOf(batchId) != msg.sender) {
            revert BondsNotOwner(msg.sender, batchId);
        }
        return _claimBatch(batchId);
    }

    function _claimBatch(uint batchId) internal returns(uint256 claimed) {
        claimed= availableRewards(batchId);
        if(claimed == 0) {
            revert BondsNoRewards();
        }
        LockEntry storage entry= investments[batchId];
        entry.claimedRewards += claimed;
        totalClaimed += claimed;
        coin.safeTransfer(bondToken.ownerOf(batchId) , claimed);

        emit RewardsClaimed(bondToken.ownerOf(batchId), batchId, claimed, currentRewardsClaimable());
    }

    function claimAllRewards() external nonReentrant returns(uint256 total) {
        total= 0;
        uint256 tokens= bondToken.balanceOf(msg.sender);
        for(uint idx = 0; idx < tokens; ++idx) {
            uint256 batchId= bondToken.tokenOfOwnerByIndex(msg.sender, idx);
            uint256 claimed= availableRewards(batchId);
            if(claimed > 0) {
                LockEntry storage entry= investments[batchId];
                entry.claimedRewards += claimed;
                total += claimed; 
                emit RewardsClaimed(msg.sender, batchId, claimed, currentRewardsClaimable());
            }
        }if(total == 0) {
            revert BondsNoRewards();
        }
        totalClaimed += total;
        coin.safeTransfer(msg.sender, total);

    }

    function addRewards(uint256 rewardAmount) external {
        if(currentTvl() == 0) {
            revert BondsEmptyTVL();
        }
        coin.safeTransferFrom(msg.sender, address(this), rewardAmount);
        totalRewards += rewardAmount;

        rewardsPerDeposit += (rewardAmount * 1e18)/currentTvl();

        emit RewardsAdded(rewardAmount, block.number-lastRewardsBlock, currentRewardsClaimable(),currentTvl());
        lastRewardsBlock= block.number;
    }
}