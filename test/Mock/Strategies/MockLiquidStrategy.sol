pragma solidity ^0.8.0;

import {BaseStrategy, IERC20} from "./MockBaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LiquidStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    constructor(
        address _vault,
        address _asset
    ) BaseStrategy(_vault, _asset) {}

    // doesn't do anything in liquid strategy as all funds are free
    function _freeFunds(
        uint256 _amount
    ) internal override returns (uint256 _amountFreed) {
        _amountFreed = IERC20(asset()).balanceOf(address(this));
    }

    function maxWithdraw(
        address _owner
    ) public view override returns (uint256) {
        return _convertToAssets(balanceOf(_owner), Math.Rounding.Down);
    }

    function migrate(address _newStrategy) external override {
        IERC20(asset()).safeTransfer(
            _newStrategy,
            IERC20(asset()).balanceOf(address(this))
        );
    }
}
