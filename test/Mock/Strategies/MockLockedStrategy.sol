pragma solidity ^0.8.0;

import {BaseStrategy, IERC20} from "./MockBaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LockedStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    // error for test function setLockedFunds
    error InsufficientFunds();

    uint256 public lockedBalance;
    uint256 public lockedUntil;

    constructor(
        address _vault,
        address _asset
    ) BaseStrategy(_vault, _asset) {}

    // only used during testing
    // locks funds for duration _lockTime
    function setLockedFunds(uint256 _amount, uint256 _lockTime) external {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (_amount > balance) revert InsufficientFunds();
        lockedBalance = _amount;
        lockedUntil = block.timestamp + _lockTime;
    }

    // only used during testing
    // free locked funds if duration has passed
    function freeLockedFunds() external {
        if (block.timestamp >= lockedUntil) {
            lockedBalance = 0;
            lockedUntil = 0;
        }
    }

    function _freeFunds(
        uint256 _amount
    ) internal override returns (uint256 _amountFreed) {}

    function maxWithdraw(address) public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (block.timestamp < lockedUntil) {
            return balance - lockedBalance;
        } else {
            // no locked assets, withdraw all
            return balance;
        }
    }

    function migrate(address _newStrategy) external override {
        require(lockedBalance == 0, "strat not liquid");
        IERC20(asset()).safeTransfer(
            _newStrategy,
            IERC20(asset()).balanceOf(address(this))
        );
    }
}
