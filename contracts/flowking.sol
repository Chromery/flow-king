// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title KingOfForest
 * @dev A bidding game where the auction end time is randomly extended with each bid.
 * This contract is updated to use OpenZeppelin 5.0, Solidity 0.8+, and includes a Cadence VRF integration.
 */
contract KingOfForest is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //- EVENTS -//

    event BidPlaced(address indexed bidder, uint256 amount, uint256 newAuctionEndTime);
    event WinnerClaimed(address indexed winner, uint256 amount);
    event TokensBurned(uint256 amount);

    //- CADENCE VRF -//

    address constant public cadenceArch = 0x0000000000000000000000010000000000000001;

    //- STATE VARIABLES -//

    IERC20 public immutable token;
    address public immutable burnAddress = 0x000000000000000000000000000000000000dEaD;
    address public treasuryAddress;

    address public lastBidder;
    address public lastWinner;
    uint256 public auctionEndTime;

    uint256 public amountBurned;
    uint256 public nextStartTime;

    //- GAME PARAMETERS -//

    uint256 public endDelay = 10 minutes;
    uint256 public coolDownTime = 24 hours;
    uint256 public bidAmount = 1e18; // Default 1.0 tokens

    //- VRF PARAMETERS -//
    uint256 public minTimeIncrease = 1 minutes;
    uint256 public maxTimeIncrease = 5 minutes;


    //- BLACKLIST -//

    mapping(address => bool) public isBlacklisted;

    //- MODIFIERS -//

    modifier notContract() {
        require(msg.sender == tx.origin, "Proxy contracts are not allowed");
        require(address(msg.sender).code.length == 0, "Contracts are not allowed");
        _;
    }

    //- CONSTRUCTOR -//

    constructor(address initialOwner, address tokenAddress, address _treasuryAddress) Ownable(initialOwner) {
        token = IERC20(tokenAddress);
        treasuryAddress = _treasuryAddress;
    }

    //- EXTERNAL FUNCTIONS -//

    /**
     * @notice Places a bid and randomly extends the auction time.
     */
    function participate() external nonReentrant notContract {
        require(!hasWinner(), "Game has a winner, reward must be claimed first.");
        require(block.timestamp >= nextStartTime, "Game is in a cooldown period.");
        require(!isBlacklisted[msg.sender], "Address is blacklisted.");
        require(lastWinner != msg.sender, "Previous winner cannot participate in the next round.");

        // If this is the first bid, set the initial auction end time
        if (lastBidder == address(0)) {
            auctionEndTime = block.timestamp + endDelay;
        }

        // Transfer tokens for the bid
        token.safeTransferFrom(msg.sender, address(this), bidAmount);

        uint256 burnAmount = bidAmount / 10;
        token.safeTransfer(burnAddress, burnAmount);
        amountBurned += burnAmount;

        // Get random time and extend the auction
        uint256 randomIncrease = _getRandomTimeIncrease(uint64(minTimeIncrease), uint64(maxTimeIncrease));
        auctionEndTime = block.timestamp + endDelay + randomIncrease;
        
        lastBidder = msg.sender;

        emit BidPlaced(msg.sender, bidAmount, auctionEndTime);
        emit TokensBurned(burnAmount);
    }

    /**
     * @notice Called to distribute rewards to the winner after the auction ends.
     */
    function claimReward() external nonReentrant notContract {
        require(hasWinner(), "There is no winner yet.");

        uint256 totalBalance = token.balanceOf(address(this));
        
        // Distribution percentages
        uint256 winAmount = (totalBalance * 60) / 100;
        uint256 nextRoundAmount = (totalBalance * 20) / 100;
        uint256 treasuryAmount = (totalBalance * 5) / 100;
        uint256 burnAmount = totalBalance - winAmount - nextRoundAmount - treasuryAmount;

        // Distribute funds
        token.safeTransfer(lastBidder, winAmount);
        token.safeTransfer(treasuryAddress, treasuryAmount);
        token.safeTransfer(burnAddress, burnAmount);
        
        amountBurned += burnAmount;
        lastWinner = lastBidder;

        // Reset for the next round
        auctionEndTime = 0;
        lastBidder = address(0);
        nextStartTime = block.timestamp + coolDownTime;

        emit WinnerClaimed(lastWinner, winAmount);
        emit TokensBurned(burnAmount);
    }

    //- OWNER FUNCTIONS -//
    
    /**
     * @notice Sets the min/max range for the random time extension on bids.
     * @param _min The minimum time in seconds to add.
     * @param _max The maximum time in seconds to add.
     */
    function setTimeIncreaseRange(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "Min must be less than max");
        require(_max <= 1 hours, "Max increase cannot exceed 1 hour");
        minTimeIncrease = _min;
        maxTimeIncrease = _max;
    }

    function setEndDelay(uint256 delay) external onlyOwner {
        require(delay >= 1 minutes, "Delay must be at least one minute.");
        endDelay = delay;
    }

    function setCoolDownTime(uint256 time) external onlyOwner {
        coolDownTime = time;
    }

    function setBidAmount(uint256 _bidAmount) external onlyOwner {
        require(_bidAmount > 0, "Bid amount must be greater than zero.");
        bidAmount = _bidAmount;
    }

    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        treasuryAddress = _treasuryAddress;
    }

    function banAddress(address _address) external onlyOwner {
        require(!isBlacklisted[_address], "Address is already blacklisted.");
        isBlacklisted[_address] = true;
    }

    function unbanAddress(address _address) external onlyOwner {
        require(isBlacklisted[_address], "Address is not blacklisted.");
        isBlacklisted[_address] = false;
    }
    
    function resetLastWinner() external onlyOwner {
        lastWinner = address(0);
    }
    
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        token.safeTransfer(owner(), amount);
    }

    //- VIEW & INTERNAL FUNCTIONS -//

    /**
     * @notice Checks if the auction has ended and there is a winner.
     */
    function hasWinner() public view returns (bool) {
        // A winner exists if there was a bidder and the auction time has passed
        return lastBidder != address(0) && block.timestamp >= auctionEndTime;
    }

    /**
     * @dev Internal function to get a random number from Cadence VRF.
     * @param min The minimum value of the range.
     * @param max The maximum value of the range.
     * @return A random number within the specified range.
     */
    function _getRandomTimeIncrease(uint64 min, uint64 max) internal view returns (uint64) {
        // Static call to the Cadence Arch contract's revertibleRandom function
        (bool ok, bytes memory data) = cadenceArch.staticcall(abi.encodeWithSignature("revertibleRandom()"));
        require(ok, "Failed to fetch random number from Cadence Arch");
        
        uint64 randomNumber = abi.decode(data, (uint64));

        // Return the number in the specified range
        return (randomNumber % (max + 1 - min)) + min;
    }
}