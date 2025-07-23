// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ReactionEconomy} from "../src/ReactionEconomy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

// Mock USDC contract with permit functionality
contract MockUSDC is IERC20, IERC20Permit {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) private _nonces;
    
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 private _totalSupply = 1000000 * 10**6; // 1M USDC
    
    bytes32 private constant _PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private immutable _DOMAIN_SEPARATOR;
    
    constructor() {
        _balances[msg.sender] = _totalSupply;
        _DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }
    
    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) external view returns (uint256) { return _allowances[owner][spender]; }
    function nonces(address owner) external view returns (uint256) { return _nonces[owner]; }
    function DOMAIN_SEPARATOR() external view returns (bytes32) { return _DOMAIN_SEPARATOR; }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);
        return true;
    }
    
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(block.timestamp <= deadline, "ERC20Permit: expired deadline");
        
        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, _nonces[owner]++, deadline));
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
        
        address signer = ecrecover(hash, v, r, s);
        require(signer == owner, "ERC20Permit: invalid signature");
        
        _approve(owner, spender, value);
    }
    
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount, "ERC20: insufficient balance");
        _balances[from] -= amount;
        _balances[to] += amount;
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        _allowances[owner][spender] = amount;
    }
}

// Mock swap router
contract MockSwapRouter {
    bool public shouldFail;
    
    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }
    
    receive() external payable {}

    fallback() external payable {
        if (shouldFail) {
            revert("Swap failed");
        }
        // Simulate successful swap
    }

}

contract ReactionEconomyTest is Test {
    ReactionEconomy public reactionEconomy;
    MockUSDC public usdc;
    MockSwapRouter public swapRouter;
    
    uint256 private contractOwnerPrivateKey = 1;
    uint256 private user1PrivateKey = 2;
    uint256 private user2PrivateKey = 3;
    
    address public contractOwner;
    address public user1;
    address public user2;
    address public tokenA = address(4);
    address public tokenB = address(5);
    
    bytes public swapData = abi.encodeWithSignature("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)", 
        100 * 10**6, 0, new address[](0), user1, block.timestamp + 1000);
    
    event BuyExecuted(address indexed user, address indexed token, uint256 usdcAmount, uint256 timestamp);
    event AllowanceSet(address indexed user, uint256 amount);
    event AllowanceRevoked(address indexed user);
    event DailyLimitUpdated(uint256 newLimit);

    function setUp() public {
        // Derive addresses from private keys
        contractOwner = vm.addr(contractOwnerPrivateKey);
        user1 = vm.addr(user1PrivateKey);
        user2 = vm.addr(user2PrivateKey);
        
        // Deploy contracts
        usdc = new MockUSDC();
        swapRouter = new MockSwapRouter();
        reactionEconomy = new ReactionEconomy(address(usdc), contractOwner);
        
        // Setup initial balances
        usdc.mint(user1, 10000 * 10**6); // 10k USDC
        usdc.mint(user2, 10000 * 10**6); // 10k USDC
        
        // Approve USDC to reaction economy
        vm.prank(user1);
        usdc.approve(address(reactionEconomy), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(reactionEconomy), type(uint256).max);
    }
    
    function test_constructor() public view{
        assertEq(address(reactionEconomy.usdc()), address(usdc));
        assertEq(reactionEconomy.owner(), contractOwner);
        assertEq(reactionEconomy.defaultDailyLimit(), 1000 * 10**6);
        assertEq(reactionEconomy.DAY(), 86400);
    }
    
    function test_setAllowance() public {
        uint256 amount = 500 * 10**6;
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(user1, address(reactionEconomy), amount, type(uint256).max, user1PrivateKey);
        
        vm.prank(contractOwner);
        vm.expectEmit(true, false, false, true);
        emit AllowanceSet(user1, amount);
        reactionEconomy.setAllowance(user1, amount, v, r, s);
        
        assertEq(reactionEconomy.allowances(user1), amount);
        assertEq(usdc.allowance(user1, address(reactionEconomy)), amount);
    }
    
    function test_setAllowance_onlyOwner() public {
        uint256 amount = 500 * 10**6;
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(user1, address(reactionEconomy), amount, type(uint256).max, user1PrivateKey);
        
        vm.prank(user1);
        vm.expectRevert();
        reactionEconomy.setAllowance(user1, amount, v, r, s);
    }
    
    function test_setAllowance_whenPaused() public {
        vm.prank(contractOwner);
        reactionEconomy.pause();
        
        uint256 amount = 500 * 10**6;
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(user1, address(reactionEconomy), amount, type(uint256).max, user1PrivateKey);
        
        vm.prank(contractOwner);
        vm.expectRevert();
        reactionEconomy.setAllowance(user1, amount, v, r, s);
    }
    
    function test_setUserDailyLimit() public {
        uint256 newLimit = 2000 * 10**6;
        
        vm.prank(contractOwner);
        reactionEconomy.setUserDailyLimit(user1, newLimit);
        
        assertEq(reactionEconomy.userDailyLimit(user1), newLimit);
    }
    
    function test_setUserDailyLimit_onlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        reactionEconomy.setUserDailyLimit(user1, 2000 * 10**6);
    }
    
    function test_setLikeAmount() public {
        uint256 amount = 10 * 10**6;
        
        vm.prank(contractOwner);
        reactionEconomy.setLikeAmount(user1, amount);
        
        assertEq(reactionEconomy.likeAmount(user1), amount);
    }
    
    function test_setRecastAmount() public {
        uint256 amount = 20 * 10**6;
        
        vm.prank(contractOwner);
        reactionEconomy.setRecastAmount(user1, amount);
        
        assertEq(reactionEconomy.recastAmount(user1), amount);
    }
    
    function test_executeBuy_like() public {
        // Setup
        uint256 allowanceAmount = 500 * 10**6;
        uint256 likeAmount = 10 * 10**6;
        uint256 buyAmount = 5 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, 0);
        
        // Execute buy
        vm.prank(contractOwner);
        vm.expectEmit(true, true, false, true);
        emit BuyExecuted(user1, tokenA, buyAmount, block.timestamp);
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
        
        // Verify state changes
        assertEq(reactionEconomy.allowances(user1), allowanceAmount - buyAmount);
        assertEq(reactionEconomy.getDailySpent(user1), buyAmount);
    }
    
    function test_executeBuy_recast() public {
        // Setup
        uint256 allowanceAmount = 500 * 10**6;
        uint256 recastAmount = 20 * 10**6;
        uint256 buyAmount = 15 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, 0, recastAmount);
        
        // Execute buy
        vm.prank(contractOwner);
        vm.expectEmit(true, true, false, true);
        emit BuyExecuted(user1, tokenA, buyAmount, block.timestamp);
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "recast");
        
        // Verify state changes
        assertEq(reactionEconomy.allowances(user1), allowanceAmount - buyAmount);
        assertEq(reactionEconomy.getDailySpent(user1), buyAmount);
    }
    
    function test_executeBuy_insufficientAllowance() public {
        uint256 allowanceAmount = 500 * 10**6;
        uint256 buyAmount = 600 * 10**6; // More than allowance
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, buyAmount, 0);
        
        vm.prank(contractOwner);
        vm.expectRevert("Insufficient allowance");
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
    }
    
    function test_executeBuy_dailyLimitExceeded() public {
        uint256 allowanceAmount = 2000 * 10**6;
        uint256 buyAmount = 1500 * 10**6; // Exceeds default daily limit
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, buyAmount, 0);
        
        vm.prank(contractOwner);
        vm.expectRevert("Daily limit exceeded");
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
    }
    
    function test_executeBuy_likeAmountNotSet() public {
        uint256 allowanceAmount = 500 * 10**6;
        uint256 buyAmount = 10 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, 0, 0); // Like amount not set
        
        vm.prank(contractOwner);
        vm.expectRevert("Like amount not set");
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
    }
    
    function test_executeBuy_exceedsLikeAmount() public {
        uint256 allowanceAmount = 500 * 10**6;
        uint256 likeAmount = 10 * 10**6;
        uint256 buyAmount = 15 * 10**6; // Exceeds like amount
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, 0);
        
        vm.prank(contractOwner);
        vm.expectRevert("Exceeds like amount");
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
    }
    
    function test_executeBuy_swapFails() public {
        uint256 allowanceAmount = 500 * 10**6;
        uint256 likeAmount = 10 * 10**6;
        uint256 buyAmount = 5 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, 0);
        swapRouter.setShouldFail(true);
        
        vm.prank(contractOwner);
        vm.expectRevert("Swap failed");
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
    }
    
    function test_executeBatchBuys() public {
        // Setup multiple users
        uint256 allowanceAmount = 500 * 10**6;
        uint256 likeAmount = 10 * 10**6;
        uint256 recastAmount = 20 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, recastAmount);
        _setupUserAllowanceAndLimits(user2, allowanceAmount, likeAmount, recastAmount);
        
        // Prepare batch data
        address[] memory users = new address[](2);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes[] memory swapDataArray = new bytes[](2);
        string[] memory actionTypes = new string[](2);
        
        users[0] = user1;
        users[1] = user2;
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        amounts[0] = 5 * 10**6;
        amounts[1] = 15 * 10**6;
        swapDataArray[0] = swapData;
        swapDataArray[1] = swapData;
        actionTypes[0] = "like";
        actionTypes[1] = "recast";
        
        // Execute batch
        vm.prank(contractOwner);
        reactionEconomy.executeBatchBuys(users, tokens, amounts, address(swapRouter), swapDataArray, actionTypes);
        
        // Verify state changes
        assertEq(reactionEconomy.allowances(user1), allowanceAmount - amounts[0]);
        assertEq(reactionEconomy.allowances(user2), allowanceAmount - amounts[1]);
        assertEq(reactionEconomy.getDailySpent(user1), amounts[0]);
        assertEq(reactionEconomy.getDailySpent(user2), amounts[1]);
    }
    
    function test_executeBatchBuys_invalidInput() public {
        address[] memory users = new address[](2);
        address[] memory tokens = new address[](1); // Mismatched length
        uint256[] memory amounts = new uint256[](2);
        bytes[] memory swapDataArray = new bytes[](2);
        string[] memory actionTypes = new string[](2);
        
        vm.prank(contractOwner);
        vm.expectRevert("Invalid input");
        reactionEconomy.executeBatchBuys(users, tokens, amounts, address(swapRouter), swapDataArray, actionTypes);
    }
    
    function test_executeBatchBuys_batchSizeTooLarge() public {
        address[] memory users = new address[](51); // Too large
        address[] memory tokens = new address[](51);
        uint256[] memory amounts = new uint256[](51);
        bytes[] memory swapDataArray = new bytes[](51);
        string[] memory actionTypes = new string[](51);
        
        vm.prank(contractOwner);
        vm.expectRevert("Batch size too large");
        reactionEconomy.executeBatchBuys(users, tokens, amounts, address(swapRouter), swapDataArray, actionTypes);
    }
    
    function test_revokeAllowance() public {
        // Setup allowance first
        uint256 allowanceAmount = 500 * 10**6;
        _setupUserAllowanceAndLimits(user1, allowanceAmount, 0, 0);
        
        // Revoke allowance
        vm.prank(contractOwner);
        vm.expectEmit(true, false, false, false);
        emit AllowanceRevoked(user1);
        reactionEconomy.revokeAllowance(user1);
        
        assertEq(reactionEconomy.allowances(user1), 0);
    }
    
    function test_setDailyLimit() public {
        uint256 newLimit = 2000 * 10**6;
        
        vm.prank(contractOwner);
        vm.expectEmit(false, false, false, true);
        emit DailyLimitUpdated(newLimit);
        reactionEconomy.setDailyLimit(newLimit);
        
        assertEq(reactionEconomy.defaultDailyLimit(), newLimit);
    }
    
    function test_pause_unpause() public {
        // Test pause
        vm.prank(contractOwner);
        reactionEconomy.pause();
        assertTrue(reactionEconomy.paused());
        
        // Test unpause
        vm.prank(contractOwner);
        reactionEconomy.unpause();
        assertFalse(reactionEconomy.paused());
    }
    
    function test_getDailySpent() public {
        uint256 allowanceAmount = 500 * 10**6;
        uint256 likeAmount = 10 * 10**6;
        uint256 buyAmount = 5 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, 0);
        
        // Initial daily spent should be 0
        assertEq(reactionEconomy.getDailySpent(user1), 0);
        
        // Execute buy
        vm.prank(contractOwner);
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
        
        // Daily spent should be updated
        assertEq(reactionEconomy.getDailySpent(user1), buyAmount);
    }
    
    function test_dailyLimitResetAfterDay() public {
        uint256 allowanceAmount = 500 * 10**6;
        uint256 likeAmount = 10 * 10**6;
        uint256 buyAmount = 5 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, 0);
        
        // Execute buy on day 1
        vm.prank(contractOwner);
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
        assertEq(reactionEconomy.getDailySpent(user1), buyAmount);
        
        // Fast forward to next day
        vm.warp(block.timestamp + 86401);
        
        // Daily spent should be 0 for new day
        assertEq(reactionEconomy.getDailySpent(user1), 0);
    }
    
    function test_userSpecificDailyLimit() public {
        uint256 allowanceAmount = 3000 * 10**6;
        uint256 likeAmount = 2000 * 10**6;
        uint256 userDailyLimit = 2000 * 10**6;
        uint256 buyAmount = 1500 * 10**6;
        
        _setupUserAllowanceAndLimits(user1, allowanceAmount, likeAmount, 0);
        
        // Set user-specific daily limit
        vm.prank(contractOwner);
        reactionEconomy.setUserDailyLimit(user1, userDailyLimit);
        
        // Should succeed within user's daily limit
        vm.prank(contractOwner);
        reactionEconomy.executeBuy(user1, tokenA, buyAmount, address(swapRouter), swapData, "like");
        
        assertEq(reactionEconomy.getDailySpent(user1), buyAmount);
    }
    
    // Helper function to setup user allowance and action limits
    function _setupUserAllowanceAndLimits(address user, uint256 allowanceAmount, uint256 likeAmt, uint256 recastAmt) internal {
        // Setup allowance with permit
        uint256 privateKey = user == user1 ? user1PrivateKey : user2PrivateKey;
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(user, address(reactionEconomy), allowanceAmount, type(uint256).max, privateKey);
        
        vm.prank(contractOwner);
        reactionEconomy.setAllowance(user, allowanceAmount, v, r, s);
        
        if (likeAmt > 0) {
            vm.prank(contractOwner);
            reactionEconomy.setLikeAmount(user, likeAmt);
        }
        
        if (recastAmt > 0) {
            vm.prank(contractOwner);
            reactionEconomy.setRecastAmount(user, recastAmt);
        }
    }
    
    // Helper function to generate permit signature
    function _getPermitSignature(address owner, address spender, uint256 value, uint256 deadline, uint256 privateKey) 
        internal 
        view 
        returns (uint8 v, bytes32 r, bytes32 s) 
    {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            owner,
            spender,
            value,
            usdc.nonces(owner),
            deadline
        ));
        
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, hash);
    }
}
