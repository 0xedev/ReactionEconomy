  //SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
 import "@openzeppelin/contracts/access/Ownable.sol";
 import "@openzeppelin/contracts/security/Pausable.sol";
 import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

 contract ReactionEconomy is Ownable, Pausable, ReentrancyGuard {
     IERC20 public immutable usdc;
     // User approved USDC amount
     mapping(address => uint256) public allowances;
     // User => day => USDC spent
     mapping(address => mapping(uint256 => uint256)) public dailySpent;
     // Per-user daily limit
     mapping(address => uint256) public userDailyLimit;
     // Per-user like amount
     mapping(address => uint256) public likeAmount;
     // Per-user recast amount
     mapping(address => uint256) public recastAmount;
     // Seconds in a day
     uint256 public constant DAY = 86400;
     // 1000 USDC (6 decimals)
     uint256 public defaultDailyLimit = 1000 * 10**6;

     event BuyExecuted(address indexed user, address indexed token, uint256 usdcAmount, uint256 timestamp);
     event AllowanceSet(address indexed user, uint256 amount);
     event AllowanceRevoked(address indexed user);
     event DailyLimitUpdated(uint256 newLimit);

     constructor(address _usdc, address initialOwner) Ownable(initialOwner) {
         usdc = IERC20(_usdc);
     }

     // Set EIP-2612 permit for user
     function setAllowance(address user, uint256 amount, uint8 v, bytes32 r, bytes32 s) 
         external 
         onlyOwner 
         whenNotPaused 
     {
         IERC20Permit(address(usdc)).permit(user, address(this), amount, type(uint256).max, v, r, s);
         allowances[user] = amount;
         emit AllowanceSet(user, amount);
     }

      // Set per-user daily limit
     function setUserDailyLimit(address user, uint256 limit) external onlyOwner {
         userDailyLimit[user] = limit;
     }

     // Set per-user like amount
     function setLikeAmount(address user, uint256 amount) external onlyOwner {
         likeAmount[user] = amount;
     }

     // Set per-user recast amount
     function setRecastAmount(address user, uint256 amount) external onlyOwner {
         recastAmount[user] = amount;
     }

     // Execute single auto-buy trade (with action type)
     function executeBuy(address user, address token, uint256 usdcAmount, address swapRouter, bytes calldata swapData, string calldata actionType)
         external
         onlyOwner
         whenNotPaused
         nonReentrant
     {
         require(allowances[user] >= usdcAmount, "Insufficient allowance");
         uint256 today = block.timestamp / DAY;
         uint256 limit = userDailyLimit[user] > 0 ? userDailyLimit[user] : defaultDailyLimit;
         require(dailySpent[user][today] + usdcAmount <= limit, "Daily limit exceeded");
         if (keccak256(bytes(actionType)) == keccak256(bytes("like"))) {
             require(likeAmount[user] > 0, "Like amount not set");
             require(usdcAmount <= likeAmount[user], "Exceeds like amount");
         } else if (keccak256(bytes(actionType)) == keccak256(bytes("recast"))) {
             require(recastAmount[user] > 0, "Recast amount not set");
             require(usdcAmount <= recastAmount[user], "Exceeds recast amount");
         }

         unchecked { 
             allowances[user] -= usdcAmount; 
             dailySpent[user][today] += usdcAmount;
         }

         require(usdc.transferFrom(user, address(this), usdcAmount), "USDC transfer failed");
         usdc.approve(swapRouter, usdcAmount);
         (bool success, bytes memory result) = swapRouter.call(swapData);
         require(success, string(result));

         emit BuyExecuted(user, token, usdcAmount, block.timestamp);
     }

      // Execute batch auto-buy trades (with action types)
     function executeBatchBuys(
         address[] calldata users,
         address[] calldata tokens,
         uint256[] calldata usdcAmounts,
         address swapRouter,
         bytes[] calldata swapData,
         string[] calldata actionTypes
     )
         external
         onlyOwner
         whenNotPaused
         nonReentrant
     {
         require(users.length == tokens.length && tokens.length == usdcAmounts.length && usdcAmounts.length == swapData.length && swapData.length == actionTypes.length, "Invalid input");
         uint256 today = block.timestamp / DAY;
        
         for (uint256 i = 0; i < users.length; i++) {
             _processSingleBuy(
                 users[i],
                 tokens[i],
                 usdcAmounts[i],
                 swapRouter,
                 swapData[i],
                 actionTypes[i],
                 today
             );
         }
     }

     // Helper function to process a single buy operation
     function _processSingleBuy(
         address user,
         address token,
         uint256 usdcAmount,
         address swapRouter,
         bytes calldata swapData,
         string calldata actionType,
         uint256 today
     ) private {
         // Get the appropriate daily limit
         uint256 limit;
         if (userDailyLimit[user] > 0) {
             limit = userDailyLimit[user];
         } else {
             limit = defaultDailyLimit;
         }
        
         require(allowances[user] >= usdcAmount, "Insufficient allowance");
         require(dailySpent[user][today] + usdcAmount <= limit, "Daily limit exceeded");
        
         // Check action type
         bytes32 actionHash = keccak256(bytes(actionType));
         if (actionHash == keccak256(bytes("like"))) {
             require(likeAmount[user] > 0, "Like amount not set");
             require(usdcAmount <= likeAmount[user], "Exceeds like amount");
         } else if (actionHash == keccak256(bytes("recast"))) {
             require(recastAmount[user] > 0, "Recast amount not set");
             require(usdcAmount <= recastAmount[user], "Exceeds recast amount");
         }

         unchecked { 
             allowances[user] -= usdcAmount; 
             dailySpent[user][today] += usdcAmount;
         }

         require(usdc.transferFrom(user, address(this), usdcAmount), "USDC transfer failed");
         usdc.approve(swapRouter, usdcAmount);
         (bool success, bytes memory result) = swapRouter.call(swapData);
         require(success, string(result));

         emit BuyExecuted(user, token, usdcAmount, block.timestamp);
     }
      // Revoke user allowance
     function revokeAllowance(address user) external onlyOwner whenNotPaused {
         allowances[user] = 0;
         emit AllowanceRevoked(user);
     }

     // Update default daily limit
     function setDailyLimit(uint256 newLimit) external onlyOwner {
         defaultDailyLimit = newLimit;
         emit DailyLimitUpdated(newLimit);
     }

     // Pause contract
     function pause() external onlyOwner {
         _pause();
     }

     // Unpause contract
     function unpause() external onlyOwner {
         _unpause();
     }

     // Get user's daily spent amount
     function getDailySpent(address user) external view returns (uint256) {
         return dailySpent[user][block.timestamp / DAY];
     }
 }