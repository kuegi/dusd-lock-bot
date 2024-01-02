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

    string[12] months= ['January','February','March','April', 'May', 
                        'June', 'July', 'August', 'September', 'October', 
                        'November', 'December'];

    constructor(string memory name_, string memory symbol_, BondManager _manager) ERC721(name_,symbol_) Ownable(address(_manager)) {
        manager= _manager;
    }

    function getTokenData(uint256 tokenId) view external returns (LockEntry memory) {
        return manager.getBatchData(tokenId);
    }

    function safeMint(address receiver, uint256 tokenId) onlyOwner external {
        _safeMint(receiver, tokenId);
    }

    function burn(uint256 tokenId) onlyOwner external {
        _burn(tokenId);
    }

    function to2DigitString(uint256 number,uint256 denominator) pure internal returns(string memory) {
        uint256 digitNumber= (number*100/denominator)%100;
        string memory digits = digitNumber >= 10 ? 
                                Strings.toString(digitNumber) : 
                                string.concat("0",Strings.toString(digitNumber));
        return string(abi.encodePacked(Strings.toString(number/denominator),'.',digits));
    }


    function formatTimestamp(uint256 tstamp) public view returns(string memory) {
      (uint year, uint month, uint day)= DateTime.timestampToDate(tstamp);
      return string(abi.encodePacked(Strings.toString(day),' ',months[month-1],' ',Strings.toString(year)));
    }


    function buildImage(uint256 _tokenId) public view returns(string memory) {
        LockEntry memory dusdBondData = manager.getBatchData(_tokenId);
        uint256 lockPeriodYears= manager.lockupPeriod()/(86400*365);
        //uint256 rewards= manager.availableRewards(_tokenId);
        return Base64.encode(bytes(
            abi.encodePacked(
                '<svg width="100%" height="100%" viewBox="0 0 128 128" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">',
                '<defs><path id="curve" d="M34.67 115.77C43.4 120.82 53.54 123.7 64.36 123.7C97.17 123.7 123.71 97.15 123.71 64.35C123.71 31.55 97.16 5 64.35 5C31.54 5 5 31.55 5 64.35C5 75.17 7.89 85.31 12.93 94.04"/>',
                ' <style> @import url("https://fonts.googleapis.com/css2?family=Montserrat:wght@600"); @keyframes rotate {0%    { rotate: 0; } 100%  { rotate: 360deg; } } text {font-size: 0.48rem; font-family: "Montserrat", sans-serif; font-weight: 600; letter-spacing: 0.02rem; transform-origin: 50% 50%; animation: rotate 24s infinite linear; } </style>',
                '</defs>',
                '<circle cx="64" cy="64" r="64" fill="#ffccef"/>'
                '<path d="M56.03 49.85L63.34 45.63L127.94 62.94C127.88 59.06 127.49 55.26 126.77 51.58L69.15 36.13L78.42 1.54C74.97 0.74 71.41 0.22 67.77 0L58.03 36.36L50.7 40.59L49.97 41.03C42.87 45.63 40.56 55.04 44.84 62.45C49.26 70.11 59.05 72.73 66.71 68.31C69.26 66.84 72.51 67.71 73.98 70.26C75.45 72.81 74.58 76.07 72.03 77.54L63.79 82.3L0 65.24C0.08 69.13 0.49 72.94 1.24 76.63L58.01 91.82L48.85 126.07C52.29 126.9 55.83 127.46 59.46 127.71L69.14 91.56L77.37 86.81L78.09 86.37C85.18 81.76 87.5 72.36 83.22 64.95C78.8 57.3 69.01 54.67 61.36 59.09C58.81 60.56 55.55 59.69 54.08 57.14C52.61 54.59 53.48 51.33 56.03 49.86V49.85Z" fill="#ffa3e2"/>',
                '<text width="96" fill="#FF00AF"><textPath xlink:href="#curve">',to2DigitString(dusdBondData.amount,1e18),' DUSD-',Strings.toString(lockPeriodYears),' year-BOND | ',formatTimestamp(dusdBondData.lockedUntil),'</textPath></text>',
                '</svg>'
            )
        ));
    }

    function buildMetadata(uint256 _tokenId) public view returns(string memory) {
        LockEntry memory dusdBondData = manager.getBatchData(_tokenId);
        uint256 rewards= manager.availableRewards(_tokenId);
        return string(abi.encodePacked(
                'data:application/json;base64,', Base64.encode(bytes(abi.encodePacked(
                            '{',
                            '"name":"DUSD Bond for ',to2DigitString(dusdBondData.amount,1e18),' DUSD",',
                            '"description":"This NFT represents a Bond for ',to2DigitString(dusdBondData.amount,1e18),' DUSD. It is Locked until ',formatTimestamp(dusdBondData.lockedUntil),'",',
                            '"amount":',Strings.toString(dusdBondData.amount),',',
                            '"lockedUntil":',Strings.toString(dusdBondData.lockedUntil),',',
                            '"availableRewards":',Strings.toString(rewards),',',
                            '"image": "data:image/svg+xml;base64,',buildImage(_tokenId),
                            '"}')))));
    }

    function tokenURI(uint256 _tokenId) public view virtual override(ERC721) returns (string memory) {
        _requireOwned(_tokenId);
        return buildMetadata(_tokenId);
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
        bondToken= new Bond(string.concat(Strings.toString(lockupTime/(86400*365))," year DUSD Bond"),string.concat("DUSDBond",Strings.toString(lockupTime/(86400*365))),this); 
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

// ----------------------------------------------------------------------------
// DateTime Library v2.0
//
// A gas-efficient Solidity date and time library
//
// https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary
//
// Tested date range 1970/01/01 to 2345/12/31
//
// Conventions:
// Unit      | Range         | Notes
// :-------- |:-------------:|:-----
// timestamp | >= 0          | Unix timestamp, number of seconds since 1970/01/01 00:00:00 UTC
// year      | 1970 ... 2345 |
// month     | 1 ... 12      |
// day       | 1 ... 31      |
// hour      | 0 ... 23      |
// minute    | 0 ... 59      |
// second    | 0 ... 59      |
// dayOfWeek | 1 ... 7       | 1 = Monday, ..., 7 = Sunday
//
//
// Enjoy. (c) BokkyPooBah / Bok Consulting Pty Ltd 2018-2019. The MIT Licence.
// ----------------------------------------------------------------------------

library DateTime {
    uint256 constant SECONDS_PER_DAY = 24 * 60 * 60;
    uint256 constant SECONDS_PER_HOUR = 60 * 60;
    uint256 constant SECONDS_PER_MINUTE = 60;
    int256 constant OFFSET19700101 = 2440588;

    uint256 constant DOW_MON = 1;
    uint256 constant DOW_TUE = 2;
    uint256 constant DOW_WED = 3;
    uint256 constant DOW_THU = 4;
    uint256 constant DOW_FRI = 5;
    uint256 constant DOW_SAT = 6;
    uint256 constant DOW_SUN = 7;


    // ------------------------------------------------------------------------
    // Calculate year/month/day from the number of days since 1970/01/01 using
    // the date conversion algorithm from
    //   http://aa.usno.navy.mil/faq/docs/JD_Formula.php
    // and adding the offset 2440588 so that 1970/01/01 is day 0
    //
    // int L = days + 68569 + offset
    // int N = 4 * L / 146097
    // L = L - (146097 * N + 3) / 4
    // year = 4000 * (L + 1) / 1461001
    // L = L - 1461 * year / 4 + 31
    // month = 80 * L / 2447
    // dd = L - 2447 * month / 80
    // L = month / 11
    // month = month + 2 - 12 * L
    // year = 100 * (N - 49) + year + L
    // ------------------------------------------------------------------------
    function _daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        unchecked {
            int256 __days = int256(_days);

            int256 L = __days + 68569 + OFFSET19700101;
            int256 N = (4 * L) / 146097;
            L = L - (146097 * N + 3) / 4;
            int256 _year = (4000 * (L + 1)) / 1461001;
            L = L - (1461 * _year) / 4 + 31;
            int256 _month = (80 * L) / 2447;
            int256 _day = L - (2447 * _month) / 80;
            L = _month / 11;
            _month = _month + 2 - 12 * L;
            _year = 100 * (N - 49) + _year + L;

            year = uint256(_year);
            month = uint256(_month);
            day = uint256(_day);
        }
    }

    function timestampToDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        unchecked {
            (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        }
    }

    function timestampToDateTime(uint256 timestamp)
        internal
        pure
        returns (uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, uint256 second)
    {
        unchecked {
            (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
            uint256 secs = timestamp % SECONDS_PER_DAY;
            hour = secs / SECONDS_PER_HOUR;
            secs = secs % SECONDS_PER_HOUR;
            minute = secs / SECONDS_PER_MINUTE;
            second = secs % SECONDS_PER_MINUTE;
        }
    }
}
