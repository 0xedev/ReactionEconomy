// SPDX-License-Identifier: MIT
pragma solidity ^0.8.;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol"; 
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

 /**
  * @title FlashBotAutoBuy
  * @dev Ultra-lightweight auto-buy contract optimized for <15k gas per transaction
  * 
  * Design Philosophy:
  * - Hard-coded trusted routers for maximum gas efficiency
  * - Contract only handles critical security (allowances)
  * - Backend handles validation, tracking, and swap execution
  * - Minimal gas footprint for microtransactions
  */
 contract FlashBotAutoBuy is Ownable, Pausable, ReentrancyGuard {
     IERC20 public immutable usdc;
    
     // Hard-coded trusted DEX routers (Base mainnet)
     address public constant OPENOCEAN_ROUTER = OPENOCEAN_ROUTER addy;
     address public constant KYBERSWAP_ROUTER = KYBERSWAP_ROUTER addy;
    
     // Router IDs for gas-efficient function calls
     uint8 public constant OPENOCEAN_ID = 0;
     uint8 public constant KYBERSWAP_ID = 1;
    
     // Events - minimal and efficient
     event AutoBuyApproved(address indexed user, uint256 usdcAmount, address indexed router);

     constructor(address _usdc, address initialOwner) Ownable(initialOwner) {
         usdc = IERC20(_usdc);
     }
    
     /**
      * @dev Ultra-light auto-buy approval function (hard-coded routers)
      * @param user User's wallet address
      * @param usdcAmount Amount of USDC to spend
      * @param routerId Router ID (0=OpenOcean, 1=KyberSwap)
      */
     function approveAutoBuy(
         address user,
         uint256 usdcAmount,
         uint8 routerId
     ) external onlyOwner whenNotPaused nonReentrant {
         // Check user has approved contract to spend enough USDC
         uint256 currentAllowance = usdc.allowance(user, address(this));
         require(currentAllowance >= usdcAmount, "Insufficient USDC allowance");
        
         // Get router address (gas-optimized with constants)
         address router;
         if (routerId == OPENOCEAN_ID) {
             router = OPENOCEAN_ROUTER;
         } else if (routerId == KYBERSWAP_ID) {
             router = KYBERSWAP_ROUTER;
         } else {
             revert("Invalid router ID");
         }
        
         // Transfer USDC from user to contract
         require(usdc.transferFrom(user, address(this), usdcAmount), "USDC transfer failed");
        
         // Approve router to spend only this specific amount
         require(usdc.approve(router, usdcAmount), "Router approval failed");
        
         emit AutoBuyApproved(user, usdcAmount, router);
     }
    
     /**
      * @dev Emergency pause
      */
     function pause() external onlyOwner {
         _pause();
     }

     /**
      * @dev Unpause
      */
     function unpause() external onlyOwner {
         _unpause();
     }     // ========== VIEW FUNCTIONS ==========
    
     /**
      * @dev Get user's current USDC allowance for this contract
      * @param user User address
      * @return Current USDC allowance amount
      */
     function getAllowance(address user) external view returns (uint256) {
         return usdc.allowance(user, address(this));
     }
    
     /**
      * @dev Check if user has sufficient USDC allowance
      * @param user User address
      * @param amount Amount to check
      * @return True if sufficient allowance
      */
     function hasAllowance(address user, uint256 amount) external view returns (bool) {
         return usdc.allowance(user, address(this)) >= amount;
     }
    
     /**
      * @dev Get router address by ID
      * @param routerId Router ID (0=OpenOcean, 1=KyberSwap)
      * @return Router contract address
      */
     function getRouterAddress(uint8 routerId) external pure returns (address) {
         if (routerId == OPENOCEAN_ID) {
             return OPENOCEAN_ROUTER;
         } else if (routerId == KYBERSWAP_ID) {
             return KYBERSWAP_ROUTER;
         } else {
             revert("Invalid router ID");
         }
     }
    
     /**
      * @dev Get OpenOcean router address
      * @return OpenOcean router address
      */
     function getOpenOceanRouter() external pure returns (address) {
         return OPENOCEAN_ROUTER;
     }
    
     /**
      * @dev Get KyberSwap router address
      * @return KyberSwap router address
      */
     function getKyberSwapRouter() external pure returns (address) {
         return KYBERSWAP_ROUTER;
     }
 }

