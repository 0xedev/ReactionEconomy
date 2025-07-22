// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRouter } from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import { Commands } from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IV4Router } from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPermit2 } from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
// ADD ADDITIONAL IMPORTS FOR V2/V3:
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract AutoBuyContract {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    UniversalRouter public immutable router;
    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;
    ISwapRouter public immutable v3Router;
    IUniswapV2Router02 public immutable v2Router;
    
    // Auto-buy state
    mapping(address => uint256) public userBalances;
    mapping(address => bool) public authorizedUsers;
    address public owner;
    address public feeRecipient;
    uint256 public constant FEE_BASIS_POINTS = 100; // 1% fee
    uint256 public constant BASIS_POINTS = 10000;

    event AutoBuyExecuted(address indexed user, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 fee);
    event FeeCollected(address indexed token, uint256 amount);

    constructor(
        address _router, 
        address _poolManager, 
        address _permit2,
        address _v3Router,
        address _v2Router
    ) {
        router = UniversalRouter(payable(_router));
        poolManager = IPoolManager(_poolManager);
        permit2 = IPermit2(_permit2);
        v3Router = ISwapRouter(_v3Router);
        v2Router = IUniswapV2Router02(_v2Router);
        owner = msg.sender;
        feeRecipient = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedUsers[msg.sender], "Not authorized");
        _;
    }

    function authorizeUser(address user) external onlyOwner {
        authorizedUsers[user] = true;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function approveTokenWithPermit2(
        address token,
        uint160 amount,
        uint48 expiration
    ) external {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(router), amount, expiration);
    }

    function depositUSDC(address usdcToken, uint256 amount) external {
        IERC20(usdcToken).transferFrom(msg.sender, address(this), amount);
        userBalances[msg.sender] += amount;
    }

    function calculateFee(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_BASIS_POINTS) / BASIS_POINTS;
    }

    // V4 Swap Function
    function swapExactInputSingleV4(
        PoolKey calldata key,
        uint128 amountIn,
        uint128 minAmountOut
    ) external returns (uint256 amountOut) {
        require(userBalances[msg.sender] >= amountIn, "Insufficient balance");
        
        // Calculate fee
        uint256 fee = calculateFee(amountIn);
        uint256 swapAmount = amountIn - fee;
        
        userBalances[msg.sender] -= amountIn;

        // Transfer fee to recipient
        IERC20(Currency.unwrap(key.currency0)).transfer(feeRecipient, fee);
        emit FeeCollected(Currency.unwrap(key.currency0), fee);

        // Approve Universal Router
        IERC20(Currency.unwrap(key.currency0)).approve(address(router), swapAmount);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(swapAmount),
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, swapAmount);
        params[2] = abi.encode(key.currency1, minAmountOut);

        inputs[0] = abi.encode(actions, params);

        router.execute(commands, inputs, block.timestamp + 300);

        amountOut = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        
        IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, amountOut);
        
        emit AutoBuyExecuted(msg.sender, Currency.unwrap(key.currency1), amountIn, amountOut, fee);
        return amountOut;
    }

    // Smart routing function - tries V4 first, falls back to V3/V2
    function smartAutoBuy(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) external onlyAuthorized returns (uint256 amountOut) {
        require(userBalances[msg.sender] >= amountIn, "Insufficient balance");
        
        // Calculate fee
        uint256 fee = calculateFee(amountIn);
        uint256 swapAmount = amountIn - fee;
        
        userBalances[msg.sender] -= amountIn;

        // Transfer fee to recipient
        IERC20(tokenIn).transfer(feeRecipient, fee);
        emit FeeCollected(tokenIn, fee);

        // Try multiple routing strategies
        bytes memory commands;
        bytes[] memory inputs;
        
        if (tryV4Route(tokenIn, tokenOut)) {
            (commands, inputs) = buildV4Route(tokenIn, tokenOut, uint128(swapAmount), minAmountOut);
        } else if (tryV3Route(tokenIn, tokenOut)) {
            (commands, inputs) = buildV3Route(tokenIn, tokenOut, uint128(swapAmount), minAmountOut);
        } else {
            (commands, inputs) = buildV2Route(tokenIn, tokenOut, uint128(swapAmount), minAmountOut);
        }

        IERC20(tokenIn).approve(address(router), swapAmount);
        router.execute(commands, inputs, block.timestamp + 300);

        amountOut = IERC20(tokenOut).balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output");
        
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        emit AutoBuyExecuted(msg.sender, tokenOut, amountIn, amountOut, fee);
        
        return amountOut;
    }

    function tryV4Route(address tokenIn, address tokenOut) internal view returns (bool) {
        // Ensure proper token ordering
        (Currency currency0, Currency currency1) = tokenIn < tokenOut 
            ? (Currency.wrap(tokenIn), Currency.wrap(tokenOut))
            : (Currency.wrap(tokenOut), Currency.wrap(tokenIn));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: address(0)
        });
        
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);
        return sqrtPriceX96 != 0;
    }

    function tryV3Route(address tokenIn, address tokenOut) internal pure returns (bool) {
        // In production, query V3 factory for pool existence
        return tokenIn != address(0) && tokenOut != address(0);
    }

    function buildV4Route(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);
        
        // Ensure proper token ordering
        (Currency currency0, Currency currency1) = tokenIn < tokenOut 
            ? (Currency.wrap(tokenIn), Currency.wrap(tokenOut))
            : (Currency.wrap(tokenOut), Currency.wrap(tokenIn));
        
        bool zeroForOne = tokenIn < tokenOut;
        
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(currency0, amountIn);
        params[2] = abi.encode(currency1, minAmountOut);

        inputs[0] = abi.encode(actions, params);
    }

    function buildV3Route(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_IN));
        inputs = new bytes[](1);
        
        // Build V3 path: tokenIn -> fee -> tokenOut
        bytes memory path = abi.encodePacked(tokenIn, uint24(3000), tokenOut);
        
        inputs[0] = abi.encode(
            address(this), // recipient
            amountIn,
            minAmountOut,
            path,
            false // payerIsUser
        );
    }
//
    function buildV2Route(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(uint8(Commands.V2_SWAP_EXACT_IN));
        inputs = new bytes[](1);
        
        // Build V2 path
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        inputs[0] = abi.encode(
            address(this), // recipient
            amountIn,
            minAmountOut,
            path,
            false // payerIsUser
        );
    }

    // Emergency functions
    function withdrawFees(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(feeRecipient, balance);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
    }

    // View functions
    function getUserBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }

    function isAuthorized(address user) external view returns (bool) {
        return authorizedUsers[user];
    }
}
