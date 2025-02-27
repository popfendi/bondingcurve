// SPDX-License-Identifier: MIT
// Dev: @popfendi (@popfendicollars - twitter)
// THIS IS MEANT TO BE A HIGH CLASS BUREAU DE CHANGE

pragma solidity ^0.8.0;

import "./CurveManager.sol";

contract CurveQuoter {
    CurveManager public curveManager;

    constructor(address _curveManager) {
        curveManager = CurveManager(_curveManager);
    }

    string constant public ERROR_TOKEN_NOT_FOUND = "token?";
    string constant public ERROR_RESERVE_AMOUNT = "rsrv2low";

    function getBuyAmountOut(
		address tokenAddress,
		uint256 amountIn
	) public view virtual returns (uint256) {
		(address token, uint64 reserveNative, uint64 reserveToken, uint64 virtualLiquidity, ) = curveManager.curves(tokenAddress);
		require(token != address(0), ERROR_TOKEN_NOT_FOUND);

		uint256 fee = (amountIn * uint256(curveManager.swapFeeBips())) / 10000;
		uint256 amountAfterFee = amountIn - fee;

		uint256 vReserveNative = reserveNative + virtualLiquidity;
		uint256 vReserveToken = reserveToken;

		uint256 tokenAmount = (amountAfterFee * vReserveToken) /
			(vReserveNative + amountAfterFee);


		require(tokenAmount < reserveToken, ERROR_RESERVE_AMOUNT);
		return tokenAmount;
	}

	function getBuyAmountIn(
		address tokenAddress,
		uint256 amountOut
	) public view virtual returns (uint256) {
		(address token, uint64 reserveNative, uint64 reserveToken, uint64 virtualLiquidity, ) = curveManager.curves(tokenAddress);
		require(token != address(0), ERROR_TOKEN_NOT_FOUND);
		require(amountOut < reserveToken, ERROR_RESERVE_AMOUNT);

		uint256 vReserveNative = reserveNative + virtualLiquidity;
		uint256 vReserveToken = reserveToken;

		uint256 amountIn = (vReserveNative * amountOut) /
			(vReserveToken - amountOut);

		uint256 fee = (amountIn * uint256(curveManager.swapFeeBips())) / (10000 - curveManager.swapFeeBips());
		uint256 totalAmountIn = amountIn + fee;

		return totalAmountIn;
	}

	function getSellAmountOut(
		address tokenAddress,
		uint256 amountIn
	) public view virtual returns (uint256) {
		(address token, uint64 reserveNative, uint64 reserveToken, uint64 virtualLiquidity, ) = curveManager.curves(tokenAddress);
		require(token != address(0), ERROR_TOKEN_NOT_FOUND);


		uint256 vReserveToken = reserveToken;
		uint256 vReserveNative = reserveNative + virtualLiquidity;

		uint256 nativeAmount = (amountIn * vReserveNative) /
			(vReserveToken + amountIn);

		require(nativeAmount < reserveNative, ERROR_RESERVE_AMOUNT);

		uint256 fee = (nativeAmount * uint256(curveManager.swapFeeBips())) / 10000;
		uint256 amountAfterFee = nativeAmount - fee;
		return amountAfterFee;
	}

	function getSellAmountIn(
		address tokenAddress,
		uint256 amountOut
	) public view virtual returns (uint256) {
		(address token, uint64 reserveNative, uint64 reserveToken, uint64 virtualLiquidity, ) = curveManager.curves(tokenAddress);
		require(token != address(0), ERROR_TOKEN_NOT_FOUND);
		require(amountOut < reserveNative, ERROR_RESERVE_AMOUNT);

		uint256 fee = (amountOut * uint256(curveManager.swapFeeBips())) / 10000;
		uint256 amountAfterFee = amountOut - fee;

		uint256 vReserveNative = reserveNative + virtualLiquidity;
		uint256 vReserveToken = reserveToken;

		uint256 amountIn = (vReserveToken * amountAfterFee) /
			(vReserveNative - amountAfterFee);
		return amountIn;
	}
}
