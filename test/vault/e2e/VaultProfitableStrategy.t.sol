pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "../../../src/contracts/VaultFactory.sol";
import {Vault} from "../../../src/contracts/Vault.sol";
import {LossyStrategy} from "../../Mock/Strategies/MockLossyStrategy.sol";

contract VaultTest is Test {
    ERC20Mock public asset;
    uint256 decimals = 18;
    uint256 MAX_BPS = 10_000;
    VaultFactory vaultFactory;
    LossyStrategy strategy;
    Vault vault;
    address roleManager;
    address depositLimitManager;
    address strategyManager;
    address debtManager;
    address minimumIdleManager;
    address user1;
    address user2;
    address[] queue;
    uint256 firstProfit;
    uint256 secondProfit;
    uint256 firstLoss;

    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;
    uint256 public profitMaxUnlockTime = 7 days;

    function setUp() public {
        asset = new ERC20Mock();
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        roleManager = vm.addr(1);
        depositLimitManager = vm.addr(2);
        strategyManager = vm.addr(3);
        debtManager = vm.addr(4);
        minimumIdleManager = vm.addr(5);
        user1 = vm.addr(6);
        user2 = vm.addr(7);
        vaultFactory = new VaultFactory(msg.sender);
        vault = Vault(
            vaultFactory.deployNewVault(
                address(asset),
                name,
                symbol,
                roleManager,
                profitMaxUnlockTime
            )
        );
        strategy = new LossyStrategy(address(vault), address(asset));
        vm.startPrank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vault.setStrategyManager(strategyManager);
        vault.setDebtManager(debtManager);
        vault.setMinimumIdleManager(minimumIdleManager);

        vm.stopPrank();
        vm.prank(depositLimitManager);
        vault.setDepositLimit(10e30);
        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        strategy.setMaxDebt(10e30);
    }

    function test_ProfitableStrategyFlow(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        firstProfit = _amount / 4;
        secondProfit = _amount / 2;
        firstLoss = _amount / 4;

        _mintAndDepositIntoVault(user1, user1, _amount);

        assertEq(vault.balanceOf(user1), _amount);
        assertEq(vault.pricePerShare(), 10 ** asset.decimals()); // 1 : 1 price

        _addDebtToStrategy(_amount);

        assertEq(strategy.totalAssets(), _amount);
        assertEq(vault.totalAssets(), _amount);
        assertEq(_getCurrentDebtOfStrategy(), _amount);

        // we simulate profit on strategy
        asset.mint(address(this), firstProfit);
        asset.transfer(address(strategy), firstProfit);

        (uint256 gainReported, ) = _callProcessReport();

        assertApproxEqAbs(gainReported, firstProfit, 1);
        assertApproxEqAbs(_amount + firstProfit, vault.totalAssets(), 1);

        _mintAndDepositIntoVault(user2, user2, _amount);

        assertEq(vault.totalIdle(), _amount);
        _addDebtToStrategy(strategy.totalAssets() + _amount);
        assertEq(vault.totalIdle(), 0);

        // We generate second profit
        asset.mint(address(this), secondProfit);
        asset.transfer(address(strategy), secondProfit);
        uint256 assetsBeforeProfit = vault.totalAssets();
        (gainReported, ) = _callProcessReport();

        assertApproxEqAbs(gainReported, secondProfit, 1);
        assertApproxEqAbs(
            assetsBeforeProfit + secondProfit,
            vault.totalAssets(),
            1
        );

        uint256 assetsBeforeLoss = vault.totalAssets();

        // we create a small loss that should be damped by profit buffer
        strategy.setLoss(msg.sender, firstLoss);

        (, uint256 lossReported) = _callProcessReport();
        assertEq(lossReported, firstLoss);

        assertGt(assetsBeforeLoss, vault.totalAssets());

        assertEq(vault.totalIdle(), 0);

        // Lets set a `minimumTotalIdle` value
        uint256 minTotalIdle = _amount / 2;
        vm.prank(minimumIdleManager);
        vault.setMinimumTotalIdle(minTotalIdle);

        // We update debt for minimum_total_idle to take effect
        uint256 newDebt = strategy.totalAssets() - _amount / 4;
        _addDebtToStrategy(newDebt);

        assertEq(vault.totalIdle(), minTotalIdle);

        // strategy has not the desired debt, as we need to have minimumTotalIdle
        assertFalse(_getCurrentDebtOfStrategy() == newDebt);

        uint256 user1Withdraw = vault.totalIdle();

        vm.prank(user1);
        vault.withdraw(user1Withdraw, user1, user1, 0, queue);

        assertApproxEqAbs(vault.totalIdle(), 0, 1);
        uint256 newDebt1 = strategy.totalAssets() - _amount / 4;

        _addDebtToStrategy(newDebt1);
        queue.push(address(strategy));

        assertApproxEqAbs(vault.totalIdle(), minTotalIdle, 1);

        // strategy has not the desired debt, as we need to have minimumTotalIdle
        assertFalse(_getCurrentDebtOfStrategy() == newDebt1);

        // Lets let time pass to empty profit buffer
        skip(7 days);
        assertApproxEqAbs(
            vault.totalAssets(),
            _amount *
                2 +
                firstProfit +
                secondProfit -
                firstLoss -
                user1Withdraw,
            1
        );
        uint256 shares1 = vault.balanceOf(user1);
        vm.prank(user1);
        vault.redeem(shares1, user1, user1, 0, queue);

        assertApproxEqAbs(vault.balanceOf(user1), 0, 1);

        assertGt(asset.balanceOf(user1), _amount);

        queue.pop();
        uint256 shares2 = vault.balanceOf(user2);
        vm.prank(user2);
        vault.redeem(shares2, user2, user2, 0, queue);

        assertApproxEqAbs(vault.balanceOf(user2), 0, 1);
        assertGt(asset.balanceOf(user2), _amount);

        assertApproxEqAbs(strategy.totalAssets(), vault.totalAssets(), 1);
    }

    function _mintAndDepositIntoVault(
        address _user,
        address _receiver,
        uint256 _amount
    ) private {
        asset.mint(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(vault), _amount);
        Vault(vault).deposit(_amount, _receiver);
        vm.stopPrank();
    }

    function _checkVaultEmpty() private {
        assertEq(Vault(vault).totalAssets(), 0);
        assertEq(Vault(vault).totalSupply(), 0);
        assertEq(Vault(vault).totalIdle(), 0);
        assertEq(Vault(vault).totalDebt(), 0);
    }

    function _addDebtToStrategy(uint256 newDebt) private {
        vm.startPrank(debtManager);
        Vault(vault).updateMaxDebtForStrategy(address(strategy), newDebt);
        Vault(vault).updateDebt(address(strategy), newDebt);
        vm.stopPrank();
    }

    function _callProcessReport() private returns (uint256 gain, uint256 loss) {
        vm.prank(strategyManager);
        (gain, loss) = vault.processReport(address(strategy));
    }

    function _getCurrentDebtOfStrategy() private view returns (uint256 currentDebt) {
        (, , currentDebt, ) = vault.strategies(address(strategy));
    }
}
