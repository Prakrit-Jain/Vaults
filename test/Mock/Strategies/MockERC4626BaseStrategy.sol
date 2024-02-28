pragma solidity ^0.8.0;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract ERC4626BaseStrategy is ERC4626 {
    using SafeERC20 for IERC20;

    address public vault;
    uint8 private _decimals;

    constructor(
        address _vault,
        address _asset
    ) ERC4626(IERC20Metadata(address(_asset))) {
        _initialize(_vault, _asset);
    }

    function _initialize(address _vault, address _asset) internal {
        _decimals = IERC20Metadata(address(_asset)).decimals();

        vault = _vault;
        // using approve since initialization is only called once
        IERC20(_asset).approve(_vault, type(uint256).max); // Give Vault unlimited access (might save gas)
    }

    /** @dev See {IERC20Metadata-decimals}. */
    function decimals()
        public
        view
        virtual
        override
        returns (uint8)
    {
        return _decimals;
    }

    // TODO: add roles (including vault)
    // TODO: should we force invest and freeFunds to be in deposit and withdraw functions?

    function invest() external  {
        // TODO: add permissioning ?
    }

    function freeFunds(
        uint256 _amount
    ) external returns (uint256 _freedFunds) {
        // TODO: add permissioning ?
    }

    function migrate(address _newStrategy) external virtual {
        // TODO: add permissioning
    }

    function _invest() internal virtual;

    function _freeFunds(
        uint256 _amount
    ) internal virtual returns (uint256 amountFreed);

    function _protectedTokens()
        internal
        view
        virtual
        returns (address[] memory);

    function sweep(address _token) external {
        // TODO: add permissioning
        // TODO: add logic
    }
}