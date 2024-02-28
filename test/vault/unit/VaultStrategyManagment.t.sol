pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "../../../src/contracts/VaultFactory.sol";
import {Vault} from "../../../src/contracts/Vault.sol";
import {LiquidStrategy} from "../../Mock/Strategies/MockLiquidStrategy.sol";

contract VaultTest is Test {
    ERC20Mock public asset;
    VaultFactory vaultFactory;
    Vault vault;
    LiquidStrategy strategy;
    address roleManager;
    address depositLimitManager;
    address strategyManager;
    address debtManager;
    address minimumIdleManager;

    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;
    uint256 public profitMaxUnlockTime = 7 days;

    function setUp() public {
        asset = new ERC20Mock();
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        roleManager = vm.addr(1);
        depositLimitManager = vm.addr(2);
        vaultFactory = new VaultFactory(msg.sender);
        vault = Vault(
            vaultFactory.deployNewVault(
                address(asset),
                name,
                symbol,
                roleManager,
                7 days
            )
        );
        strategy = new LiquidStrategy(address(vault), address(asset));
        vm.startPrank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vault.setStrategyManager(strategyManager);
        vault.setDebtManager(debtManager);
        vm.stopPrank();
        vm.prank(depositLimitManager);
        vault.setDepositLimit(1e30);
        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
    }

    function test_AddStrategyWithValidStrategy() public {
        LiquidStrategy validStrategy = new LiquidStrategy(
            address(vault),
            address(asset)
        );
        uint256 snapshot = block.timestamp;
        vm.expectEmit(address(vault));
        emit StrategyChanged(
            address(validStrategy),
            Vault.StrategyChangeType.Added
        );
        vm.prank(strategyManager);
        vault.addStrategy(address(validStrategy));

        (
            uint256 activation,
            uint256 lastReport,
            uint256 currentDebt,
            uint256 maxDebt
        ) = vault.strategies(address(validStrategy));

        assertEq(activation, snapshot);
        assertEq(lastReport, snapshot);
        assertEq(currentDebt, 0);
        assertEq(maxDebt, 0);
    }

    function test_AddStrategyWithZeroAddress() public {
        vm.expectRevert("strategy cannot be zero address");
        vm.prank(strategyManager);
        vault.addStrategy(address(0));
    }

    function test_AddStrategyWithActivation() public {
        vm.startPrank(strategyManager);
        vm.expectRevert("strategy already active");
        vault.addStrategy(address(strategy));
        vm.stopPrank();
    }

    function test_AddStrategyWithIncorrectAsset() public {
        ERC20Mock otherAsset = new ERC20Mock();
        LiquidStrategy otherStrategy = new LiquidStrategy(
            address(vault),
            address(otherAsset)
        );
        vm.startPrank(strategyManager);
        vm.expectRevert("invalid asset");
        vault.addStrategy(address(otherStrategy));
        vm.stopPrank();
    }

    function test_RevokeStrategyWithExistingStrategy() public {
        vm.expectEmit(address(vault));
        emit StrategyChanged(
            address(strategy),
            Vault.StrategyChangeType.Revoked
        );
        vm.prank(strategyManager);
        vault.revokeStrategy(address(strategy));
    }

    function test_ForceRevokeStrategyWithNonZeroDebt() public {
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, 1e18);
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 debt = vaultBalance;
        _addDebtToStrategy(vaultBalance);

        vm.expectEmit(address(vault));
        emit StrategyReported(address(strategy), 0, debt, 0); // strategy report error
        emit StrategyChanged(
            address(strategy),
            Vault.StrategyChangeType.Revoked
        ); // strategy changed event
        vm.prank(strategyManager);
        vault.forceRevokeStrategy(address(strategy));

        assertEq(vault.totalDebt(), 0);
        assertEq(vault.pricePerShare(), 0);
    }

    function _addDebtToStrategy(uint256 newDebt) private {
        vm.startPrank(debtManager);
        vault.updateMaxDebtForStrategy(address(strategy), newDebt);
        vault.updateDebt(address(strategy), newDebt);
        vm.stopPrank();
    }

    function _mintAndDepositIntoVault(
        address _user,
        address _receiver,
        uint256 _amount
    ) private {
        asset.mint(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(vault), _amount);
        vault.deposit(_amount, _receiver);
        vm.stopPrank();
    }

    event StrategyChanged(
        address indexed strategy,
        Vault.StrategyChangeType indexed changeType
    );

    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt
    );
}
