// SPDX-License-Identifier: MIT
pragma solidity >=0.8.22;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
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

contract Bond is ERC721, ERC721Enumerable, Ownable {

    BondManager public immutable manager;

    constructor(string memory name_, string memory symbol_, BondManager _manager) ERC721(name_,symbol_) Ownable(address(_manager)) {
        manager= _manager;
    }

    function getTokenData(uint256 tokenId) view external returns (LockEntry memory) {
        return manager.getBatchData(tokenId);
    }

    function safeMint(address receiver, uint256 tokenId) onlyOwner external {
        _safeMint(receiver, tokenId);
    }

     function buildImage(uint256 _tokenId) public view returns(string memory) {
      LockEntry memory dusdBondData = manager.getBatchData(_tokenId);
      return Base64.encode(bytes(
          abi.encodePacked(
              '<svg width="500" height="500" xmlns="http://www.w3.org/2000/svg">',
              '<rect height="500" width="500" fill="#FC1CAE"/>',
              '<circle cx="250.5" cy="75.5" r="40.5" fill="#FFCCEF"/>',
                '<path d="M258 45L250.5 43.5L247.5 58C240.761 59.0087 238.634 61.0024 236.5 66C235.836 73.8168 236.5 77.5 242.5 80.5C249 80.5 251.5 77.5 254.5 78.5C257.5 79.5 257 87.5 250.5 87.5C244 87.5 236.5 84 236.5 84L234.5 91.5L247.5 95L244 105.5L250.5 107.5C250.5 107.5 252.5 96 253.5 95C259.618 94.7847 269.601 79.6319 258 72C254.153 67.7358 244 77.5 244 67.5C247.652 61.5576 253.5 64.5 264.5 67.5L267.5 61L254.5 58L258 45Z" fill="#FF50C1"/>'
              '<text x="50%" y="30%" dominant-baseline="middle" fill="#fff" text-anchor="middle" font-size="41">DUSD LOCK</text>',
              '<text x="50%" y="50%" dominant-baseline="middle" fill="#fff" text-anchor="middle" font-size="41">',dusdBondData.amount,'</text>',
              '<text x="50%" y="70%" dominant-baseline="middle" fill="#fff" text-anchor="middle" font-size="41">DUSD</text>',
              '</svg>'
          )
      ));
  }
  
  function buildMetadata(uint256 _tokenId) public view returns(string memory) {
      LockEntry memory dusdBondData = manager.getBatchData(_tokenId);
      return string(abi.encodePacked(
              'data:application/json;base64,', Base64.encode(bytes(abi.encodePacked(
                          '{"name":"DUSD Bond for ', 
                         dusdBondData.amount,
                          'DUSD", "description":"This NFT represents a Bond for ', 
                          dusdBondData.amount,
                          'DUSD using DUSD-LOCK Bot. It is Locked until',dusdBondData.lockedUntil,'", "image": "', 
                          'data:image/svg+xml;base64,', 
                          buildImage(_tokenId),
                          '"}')))));
  }

  function tokenURI(uint256 _tokenId) public view virtual override(ERC721) returns (string memory) {
      _requireOwned(_tokenId);
      return buildMetadata(_tokenId);
  }

    function burn(uint256 tokenId) onlyOwner external {
        _burn(tokenId);
    }

        // The following functions are overrides required by Solidity.


     function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

 

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
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

    modifier validBatch(uint256 batchId) {
        if(batchId >= investments.length) {
            revert BondsInvalidBond(batchId);
        }
        _;
    }

    modifier ownedBatch(uint256 batchId) {
        if(batchId >= investments.length) {
            revert BondsInvalidBond(batchId);
        }
        if(bondToken.ownerOf(batchId) != msg.sender) {
            revert BondsNotOwner(msg.sender,batchId);
        }
        _;
    }

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

    // --- views -----

    function currentTvl() public view returns(uint256) {
        return totalInvest-totalWithdrawn;
    }

    function getBatchData(uint256 batchId) external view returns(LockEntry memory) {
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

    function availableRewards(uint256 batchId) public view validBatch(batchId) returns(uint256) {
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

    // ------ Bond methods -----

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

    function withdraw(uint batchId) external nonReentrant ownedBatch(batchId) returns(uint256 withdrawAmount) {
        LockEntry storage entry= investments[batchId];
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

    function claimRewards(uint batchId) external nonReentrant ownedBatch(batchId)  returns(uint256 claimed) {
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
        }
        if(total == 0) {
            revert BondsNoRewards();
        }
        totalClaimed += total;
        coin.safeTransfer(msg.sender, total);

    }

    //this method is used to add rewards to the bonds. can be called by anyone, 
    // but is expected to be called by the native bot transfering the swapped DFI rewards (natively swapped to DUSD) in.
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


/// @title Base64
/// @author Brecht Devos - <brecht@loopring.org>
/// @notice Provides a function for encoding some bytes in base64
library Base64 {
    string internal constant TABLE = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return '';
        
        // load the table into memory
        string memory table = TABLE;

        // multiply by 4/3 rounded up
        uint256 encodedLen = 4 * ((data.length + 2) / 3);

        // add some extra buffer at the end required for the writing
        string memory result = new string(encodedLen + 32);

        assembly {
            // set the actual output length
            mstore(result, encodedLen)
            
            // prepare the lookup table
            let tablePtr := add(table, 1)
            
            // input ptr
            let dataPtr := data
            let endPtr := add(dataPtr, mload(data))
            
            // result ptr, jump over length
            let resultPtr := add(result, 32)
            
            // run over the input, 3 bytes at a time
            for {} lt(dataPtr, endPtr) {}
            {
               dataPtr := add(dataPtr, 3)
               
               // read 3 bytes
               let input := mload(dataPtr)
               
               // write 4 characters
               mstore(resultPtr, shl(248, mload(add(tablePtr, and(shr(18, input), 0x3F)))))
               resultPtr := add(resultPtr, 1)
               mstore(resultPtr, shl(248, mload(add(tablePtr, and(shr(12, input), 0x3F)))))
               resultPtr := add(resultPtr, 1)
               mstore(resultPtr, shl(248, mload(add(tablePtr, and(shr( 6, input), 0x3F)))))
               resultPtr := add(resultPtr, 1)
               mstore(resultPtr, shl(248, mload(add(tablePtr, and(        input,  0x3F)))))
               resultPtr := add(resultPtr, 1)
            }
            
            // padding with '='
            switch mod(mload(data), 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }
        }
        
        return result;
    }
}
