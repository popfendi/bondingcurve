// SPDX-License-Identifier: UNLICENSED
// Dev: @popfendi (@popfendicollars - twitter)
pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/CurveManager.sol";
import "../src/ERC20Token.sol";
import "../src/CurveQuoter.sol";

contract SimpleERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        // Mint some initial supply to the deployer for testing purposes
        _mint(msg.sender, 1000 * 10**decimals());
    }
}

contract CurveManagerTest is Test {
	CurveManager manager;
	CurveQuoter quoter;
	address owner = address(0x1);
	address user = address(0x2);
	address feeTaker = address(0x3);
	address router;
	uint256 forkId;

	function setUp() public {
		string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
		forkId = vm.createFork(rpcUrl); // rpc fork needed for testing uniswap interactions
		vm.selectFork(forkId);
		vm.deal(owner, 1000 ether);
		vm.startPrank(owner);
		router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
		manager = new CurveManager(feeTaker, router);
		quoter = new CurveQuoter(address(manager));
		vm.stopPrank();
	}

	function testCreateSuccess() public {
		vm.startPrank(owner);

		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		manager.create{ value: 0.001 ether }(
			name,
			symbol,
			ipfsHash
		);

		vm.stopPrank();
	}

	function testCreateAndBuySuccess() public {
		vm.startPrank(owner);

		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		uint256 approxTokenAmountOut = 61159787994107613; // according to uniswap v2 router calc'd with same reserves

		(address tokenAddress, uint256 tokenAmountOut) = manager.createAndBuy{
			value: 0.1 ether
		}(
			name,
			symbol,
			ipfsHash,
			user,
			block.timestamp + 1 hours
		);

		ERC20Token token = ERC20Token(tokenAddress);
		uint256 userBalance = token.balanceOf(user);
		assert(userBalance == tokenAmountOut);
		assertApproxEqAbs(
			userBalance,
			approxTokenAmountOut,
			approxTokenAmountOut / 100,
			"Token amount out is incorrect"
		);

		vm.stopPrank();
	}


	function testSetFeeTakerSuccess() public {
		vm.startPrank(owner);
		address newFeeTaker = address(0x4);
		manager.setFeeTaker(newFeeTaker);
		assertEq(
			manager.feeTaker(),
			newFeeTaker,
			"Fee taker should be updated to the new address"
		);
		vm.stopPrank();
	}

	function testSetFeeTakerRevertNotOwner() public {
		vm.startPrank(user);
		address newFeeTaker = address(0x4);
		vm.expectRevert("Not the contract owner");
		manager.setFeeTaker(newFeeTaker);
		vm.stopPrank();
	}

	// results are compared to the results of the uniswap v2 router for assertions
	function testGetAmountsSuccess() public {
		vm.startPrank(owner);

		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		address tokenAddress = manager.create{ value: 0.001 ether }(
			name,
			symbol,
			ipfsHash
		);

		manager.setSwapFeeBips(30); // set swap fee to same as uniswap v2

		uint256 amount = 100000000000;

		// benchmarks produced by deployed uniswap v2 router for comparison
		uint256 amountInUniswap = 150451369108;
		uint256 amountOutUniswap = 66466662248; 

		uint256 actualBuyAmountOut = quoter.getBuyAmountOut(
			tokenAddress,
			amount
		);

		uint256 actualBuyAmountIn = quoter.getBuyAmountIn(
			tokenAddress,
			amount
		);

		/*
		// SELL cases omitted as they revert when there are no buys prior, but math was tested manually and checks out.
		uint256 actualSellAmountOut = manager.getSellAmountOut(
			tokenAddress,
			amount
		);
		

		uint256 actualSellAmountIn = manager.getSellAmountIn(
			tokenAddress,
			amount
		);

		*/

		// assertApproxEqAbs is used to account for rounding errors in the calculations
		assertApproxEqAbs(
			actualBuyAmountOut,
			amountOutUniswap,
			amountOutUniswap / 100,
			"getBuyAmountOut failed"
		);
		assertApproxEqAbs(
			actualBuyAmountIn,
			amountInUniswap,
			amountInUniswap / 100,
			"getBuyAmountIn failed"
		);

		vm.stopPrank();
	}

	// test buy, then sell for min out funcs
	function testMinOutSuccess() public {
		vm.startPrank(owner);

		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		address tokenAddress = manager.create{ value: 0.001 ether }(
			name,
			symbol,
			ipfsHash
		);

		Curve memory curve = manager.getCurve(tokenAddress);
		uint64 reserveNativeBefore = curve.reserveNative;
		uint64 reserveTokenBefore = curve.reserveToken;

		vm.deal(user, 5 ether);

		uint256 amountIn = 0.1 ether;
		uint256 expectedTokenAmountOut = quoter.getBuyAmountOut(
			tokenAddress,
			amountIn
		);

		vm.startPrank(user);
		uint256 minOut = (expectedTokenAmountOut * 99) / 100;
		uint256 deadline = block.timestamp + 1 hours;
		manager.buyMinOut{ value: amountIn }(
			tokenAddress,
			user,
			minOut,
			deadline
		);

		uint256 userBalance = ERC20Token(tokenAddress).balanceOf(user);
		assert(userBalance >= minOut);

		Curve memory curveAfter = manager.getCurve(tokenAddress);
		assert(curveAfter.reserveNative > reserveNativeBefore);
		assert(curveAfter.reserveToken < reserveTokenBefore);

		uint256 sellAmountIn = ERC20Token(tokenAddress).balanceOf(user);

		uint256 expectedSellAmountOut = quoter.getSellAmountOut(
			tokenAddress,
			sellAmountIn
		);

		uint256 minOut2 = (expectedSellAmountOut * 99) / 100;
		manager.sellMinOut(tokenAddress, user, sellAmountIn, minOut2, deadline);

		uint256 userBalance2 = ERC20Token(tokenAddress).balanceOf(user);
		assert(userBalance2 == 0);

		Curve memory curveAfter2 = manager.getCurve(tokenAddress);
		assert(curveAfter2.reserveNative < curveAfter.reserveNative);
		assert(curveAfter2.reserveToken > curveAfter.reserveToken);

		uint256 userBalanceEth = user.balance;
		uint256 expectedBalanceEth = 5 ether;
		uint256 tolerance = (expectedBalanceEth * 1) / 100; // 1% tolerance

		assertApproxEqAbs(userBalanceEth, expectedBalanceEth, tolerance);

		assert(feeTaker.balance > 0);

		vm.stopPrank();
	}

	function testMaxInSuccess() public {
		vm.startPrank(owner);

		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		address tokenAddress = manager.create{ value: 0.001 ether }(
			name,
			symbol,
			ipfsHash
		);

		Curve memory curve = manager.getCurve(tokenAddress);
		uint64 reserveNativeBefore = curve.reserveNative;
		uint64 reserveTokenBefore = curve.reserveToken;

		vm.deal(user, 5 ether);

		uint256 amountOut = 10_000_000_000_000_000;
		uint256 nativeIn = quoter.getBuyAmountIn(tokenAddress, amountOut);

		vm.startPrank(user);
		uint256 maxIn = (nativeIn * 110) / 100; // 10% slippage
		uint256 deadline = block.timestamp + 1 hours;
		manager.buyMaxIn{ value: maxIn }(
			tokenAddress,
			user,
			amountOut,
			deadline
		);

		uint256 userBalance = ERC20Token(tokenAddress).balanceOf(user);
		assert(userBalance == amountOut);

		// 10% slippage was not necessary for this tx, so this check is to make sure the remaining amount is being returned correctly
		uint256 userEthBalance = user.balance;
		assert(userEthBalance > 5 ether - maxIn);

		Curve memory curveAfter = manager.getCurve(tokenAddress);
		assert(curveAfter.reserveNative > reserveNativeBefore);
		assert(curveAfter.reserveToken < reserveTokenBefore);

		uint256 sellAmountOut = 0.001 ether;
		uint256 sellAmountIn = quoter.getSellAmountIn(
			tokenAddress,
			sellAmountOut
		);

		uint256 maxIn2 = (sellAmountIn * 110) / 100; // 10% slippage
		manager.sellMaxIn(tokenAddress, user, sellAmountOut, maxIn2, deadline);

		uint256 userBalance2 = ERC20Token(tokenAddress).balanceOf(user);
		assert(userBalance2 < userBalance);

		Curve memory curveAfter2 = manager.getCurve(tokenAddress);
		assert(curveAfter2.reserveNative < curveAfter.reserveNative);
		assert(curveAfter2.reserveToken > curveAfter.reserveToken);

		uint256 userBalanceEth2 = user.balance;
		assert(userBalanceEth2 > userEthBalance);

		uint256 feeTakerBalance = feeTaker.balance;
		assert(feeTakerBalance > 0);

		vm.stopPrank();
	}

	function testSwapInRevertCases() public {
		vm.startPrank(owner);

		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		address tokenAddress = manager.create{ value: 0.001 ether }(
			name,
			symbol,
			ipfsHash
		);

		vm.deal(user, 1000000000 ether);
		vm.startPrank(user);

		vm.expectRevert("FEE NOT MET");
		manager.buyMinOut{ value: 100 wei }(
			tokenAddress,
			user,
			1,
			block.timestamp + 1 hours
		);

		address nonExistentTokenAddress = address(0x123);
		vm.expectRevert("TOKEN NOT FOUND");
		manager.buyMinOut{ value: 1 ether }(
			nonExistentTokenAddress,
			user,
			1,
			block.timestamp + 1 hours
		);

		vm.expectRevert(bytes("ERROR OUT AMOUNT"));
		manager.buyMinOut{ value: 0.001 ether }(
			tokenAddress,
			user,
			500_000_000_000_000_000,
			block.timestamp + 1 hours
		);

		vm.stopPrank();
	}

	// this test relies on forked rpc (see setup)
	function testBond() public {
		vm.selectFork(forkId);
		vm.deal(user, 99999999999999 ether);
		vm.startPrank(user);
		
		string memory name = "Test Token";
		string memory symbol = "TT";
		string memory ipfsHash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

		address tokenAddress = manager.create{ value: 0.001 ether }(
			name,
			symbol,
			ipfsHash
		);

		uint256 amountOut = manager.completionThreshold();
		uint256 amountIn = quoter.getBuyAmountIn(tokenAddress, amountOut);
		
		manager.buyMaxIn{ value: amountIn  }(
			tokenAddress,
			user,
			amountOut,
			block.timestamp + 1 hours
		);

		vm.stopPrank();

		Curve memory curve = manager.getCurve(tokenAddress);

		assert(curve.reserveToken <= 1_000_000_000_000_000_000 - manager.completionThreshold());

		vm.warp(block.timestamp + 5 minutes + 1);
		manager.transitionCurve(tokenAddress, block.timestamp + 1);
		
		IUniswapV2Router02 r = IUniswapV2Router02(router);
		address[] memory path = new address[](2);
		path[0] = r.WETH();
		path[1] = tokenAddress;
		uint256[] memory amounts = r.getAmountsOut(1 ether, path);
		console.log(amounts[1]);
		assert(amounts[1] > 0);
	}

}
