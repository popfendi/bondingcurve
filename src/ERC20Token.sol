// SPDX-License-Identifier: MIT
// Dev: @popfendi (@popfendicollars - twitter)
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


library Address {
	function isContract(address account) internal view returns (bool) {
		return account.code.length > 0;
	}

	function sendValue(address payable recipient, uint256 amount) internal {
		require(
			address(this).balance >= amount,
			"Address: insufficient balance"
		);

		(bool success, ) = recipient.call{ value: amount }("");
		require(
			success,
			"Address: unable to send value, recipient may have reverted"
		);
	}

	function functionCall(
		address target,
		bytes memory data
	) internal returns (bytes memory) {
		return
			functionCallWithValue(
				target,
				data,
				0,
				"Address: low-level call failed"
			);
	}

	function functionCall(
		address target,
		bytes memory data,
		string memory errorMessage
	) internal returns (bytes memory) {
		return functionCallWithValue(target, data, 0, errorMessage);
	}

	function functionCallWithValue(
		address target,
		bytes memory data,
		uint256 value
	) internal returns (bytes memory) {
		return
			functionCallWithValue(
				target,
				data,
				value,
				"Address: low-level call with value failed"
			);
	}

	function functionCallWithValue(
		address target,
		bytes memory data,
		uint256 value,
		string memory errorMessage
	) internal returns (bytes memory) {
		require(
			address(this).balance >= value,
			"Address: insufficient balance for call"
		);
		(bool success, bytes memory returndata) = target.call{ value: value }(
			data
		);
		return
			verifyCallResultFromTarget(
				target,
				success,
				returndata,
				errorMessage
			);
	}

	function functionStaticCall(
		address target,
		bytes memory data
	) internal view returns (bytes memory) {
		return
			functionStaticCall(
				target,
				data,
				"Address: low-level static call failed"
			);
	}

	function functionStaticCall(
		address target,
		bytes memory data,
		string memory errorMessage
	) internal view returns (bytes memory) {
		(bool success, bytes memory returndata) = target.staticcall(data);
		return
			verifyCallResultFromTarget(
				target,
				success,
				returndata,
				errorMessage
			);
	}

	function functionDelegateCall(
		address target,
		bytes memory data
	) internal returns (bytes memory) {
		return
			functionDelegateCall(
				target,
				data,
				"Address: low-level delegate call failed"
			);
	}

	function functionDelegateCall(
		address target,
		bytes memory data,
		string memory errorMessage
	) internal returns (bytes memory) {
		(bool success, bytes memory returndata) = target.delegatecall(data);
		return
			verifyCallResultFromTarget(
				target,
				success,
				returndata,
				errorMessage
			);
	}

	function verifyCallResultFromTarget(
		address target,
		bool success,
		bytes memory returndata,
		string memory errorMessage
	) internal view returns (bytes memory) {
		if (success) {
			if (returndata.length == 0) {
				require(isContract(target), "Address: call to non-contract");
			}
			return returndata;
		} else {
			_revert(returndata, errorMessage);
		}
	}

	function verifyCallResult(
		bool success,
		bytes memory returndata,
		string memory errorMessage
	) internal pure returns (bytes memory) {
		if (success) {
			return returndata;
		} else {
			_revert(returndata, errorMessage);
		}
	}

	function _revert(
		bytes memory returndata,
		string memory errorMessage
	) private pure {
		if (returndata.length > 0) {
			assembly {
				let returndata_size := mload(returndata)
				revert(add(32, returndata), returndata_size)
			}
		} else {
			revert(errorMessage);
		}
	}
}

contract ERC20Token is ERC20, ERC20Permit, ERC20Votes, Ownable {
	using Address for address;
	bool public bonded = false;

	constructor(
		string memory name,
		string memory symbol
	) ERC20(name, symbol) Ownable(msg.sender) ERC20Permit(name){
		_mint(msg.sender, 1_000_000_000_000_000_000);
	}

	function decimals() public pure override returns (uint8) {
		return 9;
	}

	function transfer(
		address recipient,
		uint256 amount
	) public override returns (bool) {
		require(
			checkTransfer(msg.sender, recipient),
			"Cannot send unbonded tokens to a contract"
		);

		return super.transfer(recipient, amount);
	}

	function transferFrom(
		address sender,
		address recipient,
		uint256 amount
	) public override returns (bool) {
		require(
			checkTransfer(sender, recipient),
			"Cannot send unbonded tokens to a contract"
		);

		if (msg.sender != owner()) {
			uint256 currentAllowance = allowance(sender, msg.sender);
			require(
				currentAllowance >= amount,
				"ERC20: transfer amount exceeds allowance"
			);
			_approve(sender, msg.sender, currentAllowance - amount);
		}

		_transfer(sender, recipient, amount);
		return true;
	}

	function checkTransfer(
		address from,
		address to
	) private view returns (bool) {
		if (bonded) return true;
		if (from == owner() || to == owner()) return true;
		if (from.isContract() || to.isContract()) return false;
		return true;
	}

	function bond() external onlyOwner {
		bonded = true;
		renounceOwnership();
	}

	// Required overrides for ERC20Votes
   function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // The following functions are overrides required by Solidity.

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }


}
