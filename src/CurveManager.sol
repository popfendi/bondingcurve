// SPDX-License-Identifier: MIT
// Dev: @popfendi (@popfendicollars - twitter)
pragma solidity 0.8.28;

import { ERC20Token } from "./ERC20Token.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

struct Curve {
	address tokenAddress;
	uint64 reserveNative;
	uint64 reserveToken;
	uint64 virtualLiquidity;
	string metadataHash;
}

library CurveLibrary {
	function isComplete(Curve storage self, uint64 completionThreshold) internal view returns (bool) {
		uint64 TOTAL_SUPPLY = 1_000_000_000_000_000_000;
		return self.reserveToken <= TOTAL_SUPPLY - completionThreshold;
	}
}

contract CurveManager {
	using CurveLibrary for Curve;

	address public owner;
	address public feeTaker;
	uint64 public swapFeeBips = 100;
	uint256 public creationFee = 0.001 ether;
	uint256 public transitionFee = 0.25 ether;
	uint16 public confirmationPeriod = 5 minutes;
	uint256 private totalLiqHeld;

	uint64 public completionThreshold = 750_000_000_000_000_000;
	uint64 public virtualLiquidity = uint64(1.5 ether);

	address public v2Router;

	mapping(address => Curve) public curves;
	mapping(address => uint256) public curveCompletionTimestamps;
	mapping(address => bool) public roomUnlocked;

	event TokenCreated(
		address indexed tokenAddress,
		string name,
		string symbol,
		string metadataHash,
		uint64 virtualLiquidity
	);
	event Swap(
		address indexed to,
		uint256 amountNative,
		uint256 amountToken,
		address indexed tokenAddress,
		uint64 reserveNativeAfter,
		uint64 reserveTokenAfter,
		bool isBuy
	);
	event CurveCompleted(address indexed tokenAddress);
	event CurveTransitioned(
		address indexed tokenAddress,
		uint64 reserveNative,
		uint64 reserveToken
	);

	event UpdateOwner(address indexed newOwner);
	event UpdateFeeTaker(address indexed newFeeTaker);
	event UpdateUniRouter(address indexed newUniRouter);
	event UpdateFees(uint64 swapFeeBips, uint256 creationFee, uint256 transitionFee);
	event UpdateCurveMetrics(uint16 confirmationPeriod, uint64 completionThreshold, uint64 virtualLiquidity);

	modifier onlyOwner() {
		require(msg.sender == owner, "Not the contract owner");
		_;
	}

	modifier ensure(uint256 deadline) {
		require(deadline >= block.timestamp, "Deadline expired");
		_;
	}

	uint private unlocked = 1;
	modifier lock() {
		require(unlocked == 1, "LOCKED");
		unlocked = 0;
		_;
		unlocked = 1;
	}

	// my attempt at optimizing errors
	string constant public ERROR_PAY_FEE = "FEE NOT MET";
	string constant public ERROR_TOKEN_NOT_FOUND = "TOKEN NOT FOUND";
	string constant public ERROR_TRANSFER_FAILED = "transfer failed";
	string constant public ERROR_CURVE_COMPLETE = "CURVE ALREADY COMPLETE";
	string constant public ERROR_OUT_AMOUNT = "ERROR OUT AMOUNT";
	string constant public ERROR_IN_AMOUNT = "ERROR IN AMOUNT";
	string constant public ERROR_RESERVE_AMOUNT = "RESERVE ERROR";
	string constant public ERROR_CONST_PRODUCT = "K ERROR";
	string constant public ERROR_0_ADDRESS = "0 ADDRESS ERROR";

	constructor(address _feeTaker, address _v2router) {
		require(_feeTaker != address(0) || _v2router != address(0), ERROR_0_ADDRESS);
		owner = msg.sender;
		feeTaker = _feeTaker;
		v2Router = _v2router;
	}

	function setFeeTaker(address _feeTaker) external onlyOwner {
		require(_feeTaker != address(0), ERROR_0_ADDRESS);
		feeTaker = _feeTaker;
		emit UpdateFeeTaker(_feeTaker);
	}


	function setOwner(address _owner) external onlyOwner {
		require(_owner != address(0), ERROR_0_ADDRESS);
		owner = _owner;
		emit UpdateOwner(_owner);
	}

	function setSwapFeeBips(uint64 _swapFeeBips) external onlyOwner {
		swapFeeBips = _swapFeeBips;
		emit UpdateFees(swapFeeBips, creationFee, transitionFee);
	}

	function setCreationFee(uint256 _creationFee) external onlyOwner {
		creationFee = _creationFee;
		emit UpdateFees(swapFeeBips, creationFee, transitionFee);
	}

	function setTransitionFee(uint256 _transitionFee) external onlyOwner {
		transitionFee = _transitionFee;
		emit UpdateFees(swapFeeBips, creationFee, transitionFee);
	}

	function setConfirmationPeriod(
		uint16 _confirmationPeriod
	) external onlyOwner {
		confirmationPeriod = _confirmationPeriod;
		emit UpdateCurveMetrics(confirmationPeriod, completionThreshold, virtualLiquidity);
	}

	function setCompletionThreshold(
		uint64 _completionThreshold
	) external onlyOwner {
		completionThreshold = _completionThreshold;
		emit UpdateCurveMetrics(confirmationPeriod, completionThreshold, virtualLiquidity);
	}

	function setVirtualLiquidity(
		uint64 _virtualLiquidity
	) external onlyOwner {
		virtualLiquidity = _virtualLiquidity;
		emit UpdateCurveMetrics(confirmationPeriod, completionThreshold, virtualLiquidity);
	}

	function setV2Router(address _v2router) external onlyOwner {
		require(_v2router != address(0), ERROR_0_ADDRESS);
		v2Router = _v2router;
	}

	function getCurve(
		address tokenAddress
	) external view returns (Curve memory) {
		return curves[tokenAddress];
	}

	function create(
		string calldata name,
		string calldata symbol,
		string calldata metadataHash
	) public payable returns (address) {
		require(msg.value >= creationFee, ERROR_PAY_FEE);
		ERC20Token token = new ERC20Token(name, symbol);

		curves[address(token)] = Curve({
			tokenAddress: address(token),
			metadataHash: metadataHash,
			reserveNative: 0,
			reserveToken: uint64(token.totalSupply()),
			virtualLiquidity: virtualLiquidity
		});

		(bool success, ) = feeTaker.call{ value: creationFee }("");
		require(success, ERROR_TRANSFER_FAILED);
		emit TokenCreated(
			address(token),
			name,
			symbol,
			metadataHash,
			virtualLiquidity
		);
		return address(token);
	}

	// locked by parent func
	function swapIn(
		address tokenAddress,
		address to,
		uint256 actualAmountIn
	) internal  returns (uint256) {
		require(actualAmountIn > 100, ERROR_PAY_FEE);
		Curve storage curve = curves[tokenAddress];
		require(curve.tokenAddress != address(0), ERROR_TOKEN_NOT_FOUND);
		require(!curve.isComplete(completionThreshold), ERROR_CURVE_COMPLETE);

		uint256 fee = (actualAmountIn * uint256(swapFeeBips)) / 10000;
		uint256 amountAfterFee = actualAmountIn - fee;

		uint256 reserveNative = curve.reserveNative + curve.virtualLiquidity;
		uint256 reserveToken = curve.reserveToken;

		uint256 tokenAmount = (amountAfterFee * reserveToken) /
			(reserveNative + amountAfterFee);

		require(tokenAmount > 0, ERROR_OUT_AMOUNT);
		require(tokenAmount < curve.reserveToken, ERROR_RESERVE_AMOUNT);
		require(
			(reserveNative + amountAfterFee) * (reserveToken - tokenAmount) >=
				reserveNative * reserveToken,
			ERROR_CONST_PRODUCT
		);

		curve.reserveNative += uint64(amountAfterFee);
		curve.reserveToken -= uint64(tokenAmount);
		totalLiqHeld += amountAfterFee;

		bool success = ERC20Token(curve.tokenAddress).transfer(to, tokenAmount);
		(bool success2, ) = feeTaker.call{ value: fee }("");
		require(success && success2, ERROR_TRANSFER_FAILED);

		emit Swap(to, amountAfterFee, tokenAmount, tokenAddress, curve.reserveNative, curve.reserveToken, true);
		if (curve.isComplete(completionThreshold)) {
			curveCompletionTimestamps[tokenAddress] = block.timestamp;
			emit CurveCompleted(tokenAddress);
		}

		return tokenAmount;
	}

	// locked by parent func
	function swapInForExactTokens(
		address tokenAddress,
		address to,
		uint256 desiredTokenAmount,
		uint256 actualAmountIn
	) internal  returns (uint256) {
		Curve storage curve = curves[tokenAddress];
		require(curve.tokenAddress != address(0), ERROR_TOKEN_NOT_FOUND);
		require(!curve.isComplete(completionThreshold), ERROR_CURVE_COMPLETE);
		require(
			desiredTokenAmount > 0,
			ERROR_OUT_AMOUNT
		);
		require(
			desiredTokenAmount < curve.reserveToken,
			ERROR_RESERVE_AMOUNT
		);

		uint256 reserveNative = curve.reserveNative + curve.virtualLiquidity;
		uint256 reserveToken = curve.reserveToken;

		uint256 amountIn = (reserveNative * desiredTokenAmount) /
			(reserveToken - desiredTokenAmount);

		uint256 fee = (amountIn * uint256(swapFeeBips)) / (10000 - swapFeeBips);
		uint256 totalAmountIn = amountIn + fee;

		require(
			totalAmountIn > 100 && actualAmountIn >= totalAmountIn,
			ERROR_IN_AMOUNT
		);

		require(
			(reserveNative + amountIn) *
				(reserveToken - desiredTokenAmount) *
				10000 >=
				reserveNative * reserveToken * (10000 - swapFeeBips),
			ERROR_CONST_PRODUCT
		);

		curve.reserveNative += uint64(amountIn);
		curve.reserveToken -= uint64(desiredTokenAmount);
		totalLiqHeld += amountIn;

		bool success = ERC20Token(curve.tokenAddress).transfer(to, desiredTokenAmount);
		(bool success2, ) = feeTaker.call{ value: fee }("");
		require(success && success2, ERROR_TRANSFER_FAILED);

		emit Swap(to, amountIn, desiredTokenAmount, tokenAddress, curve.reserveNative, curve.reserveToken, true);
		if (curve.isComplete(completionThreshold)) {
			curveCompletionTimestamps[tokenAddress] = block.timestamp;
			emit CurveCompleted(tokenAddress);
		}
		return totalAmountIn;
	}

	// locked by parent func
	function swapOut(
		address tokenAddress,
		address to
	) internal returns (uint256) {
		Curve storage curve = curves[tokenAddress];
		require(curve.tokenAddress != address(0), ERROR_TOKEN_NOT_FOUND);
		require(!curve.isComplete(completionThreshold), ERROR_CURVE_COMPLETE);

		uint256 balance = ERC20Token(curve.tokenAddress).balanceOf(
			address(this)
		);
		uint256 reserveToken = curve.reserveToken;
		uint256 amountIn = balance - reserveToken;

		require(amountIn > 0, ERROR_IN_AMOUNT);

		uint256 reserveNative = curve.reserveNative + curve.virtualLiquidity;

		uint256 nativeAmount = (amountIn * reserveNative) /
			(reserveToken + amountIn);

		require(nativeAmount > 100, ERROR_OUT_AMOUNT);
		require(nativeAmount < curve.reserveNative, ERROR_RESERVE_AMOUNT);

		uint256 fee = (nativeAmount * uint256(swapFeeBips)) / 10000;
		uint256 amountAfterFee = nativeAmount - fee;

		require(
			(reserveNative - nativeAmount) * (reserveToken + amountIn) >=
				reserveNative * reserveToken,
			ERROR_CONST_PRODUCT
		);

		curve.reserveToken += uint64(amountIn);
		curve.reserveNative -= uint64(nativeAmount);
		totalLiqHeld -= nativeAmount;

		(bool success, ) = to.call{ value: amountAfterFee }("");
		(bool success2, ) = feeTaker.call{ value: fee }("");
		require(success2 && success, ERROR_TRANSFER_FAILED);

		emit Swap(to, amountAfterFee, amountIn, tokenAddress, curve.reserveNative, curve.reserveToken, false);
		if (curve.isComplete(completionThreshold)) {
			curveCompletionTimestamps[tokenAddress] = block.timestamp;
			emit CurveCompleted(tokenAddress);
		}
		return amountAfterFee;
	}

	// locked by parent func
	function swapOutForExactNative(
		address tokenAddress,
		address to,
		uint256 desiredNativeAmount
	) internal returns (uint256) {
		Curve storage curve = curves[tokenAddress];
		require(curve.tokenAddress != address(0), ERROR_TOKEN_NOT_FOUND);
		require(!curve.isComplete(completionThreshold), ERROR_CURVE_COMPLETE);
		require(
			desiredNativeAmount > 100,
			ERROR_OUT_AMOUNT
		);
		require(
			desiredNativeAmount < curve.reserveNative,
			ERROR_RESERVE_AMOUNT
		);

		uint256 reserveNative = curve.reserveNative + curve.virtualLiquidity;
		uint256 reserveToken = curve.reserveToken;

		uint256 amountIn = (reserveToken * desiredNativeAmount) /
			(reserveNative - desiredNativeAmount);

		uint256 fee = (desiredNativeAmount * uint256(swapFeeBips)) / 10000;
		uint256 amountAfterFee = desiredNativeAmount - fee;

		require(amountIn > 0, ERROR_IN_AMOUNT);

		require(
			(reserveNative - desiredNativeAmount) *
				(reserveToken + amountIn) *
				10000 >=
				reserveNative * reserveToken * (10000 - swapFeeBips),
			ERROR_CONST_PRODUCT
		);

		curve.reserveToken += uint64(amountIn);
		curve.reserveNative -= uint64(desiredNativeAmount);
		totalLiqHeld -= desiredNativeAmount;

		(bool success, ) = to.call{ value: amountAfterFee }("");
		(bool success2, ) = feeTaker.call{ value: fee }("");
		require(success2 && success, ERROR_TRANSFER_FAILED);

		emit Swap(to, desiredNativeAmount, amountIn, tokenAddress, curve.reserveNative, curve.reserveToken, false);
		if (curve.isComplete(completionThreshold)) {
			curveCompletionTimestamps[tokenAddress] = block.timestamp;
			emit CurveCompleted(tokenAddress);
		}
		return amountIn;
	}

	function createAndBuy(
		string calldata name,
		string calldata symbol,
		string calldata metadataHash,
		address to,
		uint256 deadline
	) external lock payable ensure(deadline) returns (address, uint256) {
		require(
			msg.value >= creationFee + 100 wei,
			ERROR_PAY_FEE
		);
		address tokenAddress = create(
			name,
			symbol,
			metadataHash
		);

		uint256 actualAmountIn = msg.value - creationFee;
		uint256 tokenAmountOut = swapIn(tokenAddress, to, actualAmountIn);
		return (tokenAddress, tokenAmountOut);
	}


	function buyMinOut(
		address tokenAddress,
		address to,
		uint256 minOut,
		uint256 deadline
	) external lock payable ensure(deadline) {
		uint256 tokenAmountOut = swapIn(tokenAddress, to, msg.value);
		require(tokenAmountOut >= minOut, ERROR_OUT_AMOUNT);
	}

	function buyMaxIn(
		address tokenAddress,
		address to,
		uint256 desiredTokenAmount,
		uint256 deadline
	) external lock payable ensure(deadline) {
		uint256 nativeAmountIn = swapInForExactTokens(
			tokenAddress,
			to,
			desiredTokenAmount,
			msg.value
		);
		if (msg.value > nativeAmountIn) {
			(bool success, ) = msg.sender.call{
				value: msg.value - nativeAmountIn
			}("");
			require(success, ERROR_TRANSFER_FAILED);
		}
	}

	function sellMinOut(
		address tokenAddress,
		address to,
		uint256 amountIn,
		uint256 minOut,
		uint256 deadline
	) external lock ensure(deadline) {
		bool success = ERC20Token(tokenAddress).transferFrom(
			msg.sender,
			address(this),
			amountIn
		);
		require(success, ERROR_TRANSFER_FAILED);
		uint256 nativeAmountOut = swapOut(tokenAddress, to);
		require(nativeAmountOut >= minOut, ERROR_OUT_AMOUNT);
	}

	function sellMaxIn(
		address tokenAddress,
		address to,
		uint256 desiredNativeAmount,
		uint256 maxIn,
		uint256 deadline
	) external lock ensure(deadline) {
		uint256 amountIn = swapOutForExactNative(
			tokenAddress,
			to,
			desiredNativeAmount
		);
		require(amountIn <= maxIn, ERROR_IN_AMOUNT);
		bool success = ERC20Token(tokenAddress).transferFrom(
			msg.sender,
			address(this),
			amountIn
		);
		require(success, ERROR_TRANSFER_FAILED);
	}


	function transitionCurve(
		address tokenAddress,
		uint256 deadline
	) external lock {
		Curve storage curve = curves[tokenAddress];
		require(curve.tokenAddress != address(0), ERROR_TOKEN_NOT_FOUND);
		require(curve.isComplete(completionThreshold), ERROR_CURVE_COMPLETE);
		require(
			curveCompletionTimestamps[tokenAddress] + confirmationPeriod <
				block.timestamp,
			"waitpls"
		);
		ERC20Token(curve.tokenAddress).bond();
		uint256 amountETH = transitionLiqToV2(curve, deadline);
		totalLiqHeld -= amountETH;
	}

	function getPoolBalanceAmount(address tokenAddress) internal view returns (uint256) {
		Curve storage curve = curves[tokenAddress];
		uint256 amount = curve.virtualLiquidity;

		uint256 reserveNative = curve.reserveNative + curve.virtualLiquidity;
		uint256 reserveToken = curve.reserveToken;

		uint256 tokenAmount = (amount * reserveToken) /
			(reserveNative + amount);

		return tokenAmount;
	}

	// locked by parent func
	function transitionLiqToV2(Curve storage curve, uint256 deadline) internal returns (uint256){
		uint256 liqAmount = curve.reserveNative - transitionFee;
		uint256 poolBalanceAmount = getPoolBalanceAmount(curve.tokenAddress);
		ERC20Token token = ERC20Token(curve.tokenAddress);
		if (poolBalanceAmount > 100_000_000_000_000_000) {
			poolBalanceAmount = 100_000_000_000_000_000;
		}

		//burn to balance pool
		if (poolBalanceAmount > 0) {
			token.transfer(0x000000000000000000000000000000000000dEaD, poolBalanceAmount);
			curve.reserveToken -= uint64(poolBalanceAmount);
		}

		token.approve(v2Router, uint256(curve.reserveToken));
		(uint256 amountToken, uint256 amountETH, ) = IUniswapV2Router02(v2Router).addLiquidityETH{ value: liqAmount }(
			curve.tokenAddress,
			uint256(curve.reserveToken),
			uint256(curve.reserveToken),
			liqAmount,
			address(0),
			deadline
		);
		(bool success, ) = feeTaker.call{ value: transitionFee }("");
		require(success, ERROR_TRANSFER_FAILED);
		emit CurveTransitioned(curve.tokenAddress, uint64(amountETH), uint64(amountToken));

		return amountETH;
	}


}
