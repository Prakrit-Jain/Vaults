pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "../../../src/contracts/VaultFactory.sol";
import {Vault} from "../../../src/contracts/Vault.sol";
import {LiquidStrategy} from "../../Mock/Strategies/MockLiquidStrategy.sol";
import {LockedStrategy} from "../../Mock/Strategies/MockLockedStrategy.sol";
import {LossyStrategy} from "../../Mock/Strategies/MockLossyStrategy.sol";

contract VaultTest is Test {
    ERC20Mock public asset;
    VaultFactory vaultFactory;
    Vault vault;
    address strategy;
    address roleManager;
    address depositLimitManager;
    address strategyManager;
    address debtManager;
    address minimumIdleManager;
    address[] queue;

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
        strategy = _createLiquidStrategy();
        vm.startPrank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vault.setStrategyManager(strategyManager);
        vault.setDebtManager(debtManager);
        vm.stopPrank();
        vm.prank(depositLimitManager);
        vault.setDepositLimit(1e30);
    }

    function test_WithdrawWithInactiveStrategyReverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);
        address inactiveStrategy = _createLiquidStrategy();
        queue.push(inactiveStrategy);

        vm.prank(strategyManager);
        vault.addStrategy(strategy);
        _addDebtToStrategy(_amount);

        vm.expectRevert("inactive strategy");
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
    }

    function test_WithdrawWithLiquidStrategyWithdraws(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);
        queue.push(strategy);

        vm.prank(strategyManager);
        vault.addStrategy(strategy);
        _addDebtToStrategy(_amount);

        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, _amount, _amount);
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);

        _checkVaultEmpty();
    }

    function test_WithdrawWithMultipleLiquidStrategiesWithdraws(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy

        queue.push(strategy);
        address newStrategy = _createLiquidStrategy();
        queue.push(newStrategy);

        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // events check
        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }
        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, _amount, _amount);
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);

        _checkVaultEmpty();
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(newStrategy), 0);
        assertEq(asset.balanceOf(user), _amount);
    }

    function test_WithdrawLockedFundsWithLockedAndLiquidStrategyReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLock = amountPerStrategy / 2; // lock only half of strategy

        address lockedStrategy = _createLockedStrategy();
        queue.push(lockedStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lock half of assets in locked strategy
        LockedStrategy(lockedStrategy).setLockedFunds(amountToLock, 1 days);

        vm.expectRevert("insufficient assets in vault");
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
    }

    function test_WithdrawWithLockedAndLiquidStrategyWithdraws(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLock = amountPerStrategy / 2; // lock only half of strategy
        uint256 amountToWithdraw = _amount - amountToLock;

        address lockedStrategy = _createLockedStrategy();
        queue.push(lockedStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lock half of assets in locked strategy
        LockedStrategy(lockedStrategy).setLockedFunds(amountToLock, 1 days);

        // events check
        // new debt index would be in `DebtUpdated` event
        uint256[2] memory newDebts = [amountPerStrategy - amountToLock, 0];
        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, newDebts[i]);
        }
        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, amountToWithdraw, amountToWithdraw);
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, 0, queue);

        assertEq(vault.totalAssets(), amountToLock);
        assertEq(vault.totalSupply(), amountToLock);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), amountToLock);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(lockedStrategy), amountToLock);
        assertEq(asset.balanceOf(user), amountToWithdraw);
    }

    function test_WithdrawWithLossyStrategyNoMaxLossReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount;
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        address lossyStrategy = _createLossyStrategy();
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(lossyStrategy);
        _addDebtToStrategy(lossyStrategy, amountPerStrategy);

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        vm.expectRevert("too much loss");
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
    }

    function test_WithdrawWithLossyStrategyWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount;
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount / 2;
        address lossyStrategy = _createLossyStrategy();
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(lossyStrategy);
        _addDebtToStrategy(lossyStrategy, amountPerStrategy);

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        vm.expectEmit(address(vault));
        emit DebtUpdated(lossyStrategy, amountPerStrategy, 0);

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_RedeemWithLossyStrategyWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount;
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount;
        address lossyStrategy = _createLossyStrategy();
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(lossyStrategy);
        _addDebtToStrategy(lossyStrategy, amountPerStrategy);

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        vm.expectEmit(address(vault));
        emit DebtUpdated(lossyStrategy, amountPerStrategy, 0);

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_WithdrawWithFullLossyStrategyWithdrawsNone(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount;
        uint256 amountToLose = _amount; // loss all of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount;
        address lossyStrategy = _createLossyStrategy();
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(lossyStrategy);
        _addDebtToStrategy(lossyStrategy, amountPerStrategy);

        // lose all of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        vm.expectEmit(address(vault));
        emit DebtUpdated(lossyStrategy, amountPerStrategy, 0);

        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, amountToWithdraw - amountToLose, amountToWithdraw);
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_WithdrawWithLossyAndLiquidStrategyWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2;
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount / 4;
        address lossyStrategy = _createLossyStrategy();
        queue.push(lossyStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_RedeemWithFullLossyAndLiquidStrategyWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2;
        uint256 amountToLose = amountPerStrategy; // loss all of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount;
        address lossyStrategy = _createLossyStrategy();
        queue.push(lossyStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_WithdrawWithLiquidAndLossyStrategyWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2;
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount / 4;
        address lossyStrategy = _createLossyStrategy();
        queue.push(strategy);
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_RedeemWithLiquidAndFullLossyStrategyWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2;
        uint256 amountToLose = amountPerStrategy; // loss all of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount;
        address lossyStrategy = _createLossyStrategy();
        queue.push(strategy);
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose all of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_WithdrawWithLiquidAndLossyStrategyThatLossesWhileWithdrawingNoMaxLossReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2;
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = 0;
        address lossyStrategy = _createLossyStrategy();
        queue.push(strategy);
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose all of assets in lossy strategy
        LossyStrategy(lossyStrategy).setWithdrawingLoss(amountToLose);

        vm.expectRevert("too much loss");
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);
    }

    function test_WithdrawWithLiquidAndLossyStrategyThatLossesWhileWithdrawingWithdrawsLessThanDepoited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount; // withdraw full deposit
        uint256 maxLoss = _amount / 4;
        address lossyStrategy = _createLossyStrategy();
        queue.push(strategy);
        queue.push(lossyStrategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setWithdrawingLoss(amountToLose);

        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            amountToWithdraw
        );
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), 0);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_RedeemHalfOfAssetsFromLossyStrategyThatLossesWhileWithdrawingWithdrawsLessThanDepoited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 4; // loss only quarter of strategy
        uint256 amountToWithdraw = _amount / 2; // withdraw half deposit
        uint256 maxLoss = _amount;
        address lossyStrategy = _createLossyStrategy();

        queue.push(lossyStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setWithdrawingLoss(amountToLose);

        vm.expectEmit(address(vault));
        emit DebtUpdated(lossyStrategy, amountPerStrategy, 0);

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose,
            _amount / 2
        );
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), _amount / 2);
        assertEq(vault.totalSupply(), _amount / 2);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), _amount - amountToWithdraw);
        assertEq(asset.balanceOf(address(vault)), vault.totalIdle());
        assertEq(asset.balanceOf(strategy), amountPerStrategy);
        assertEq(asset.balanceOf(lossyStrategy), 0);
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose);
    }

    function test_RedeemHalfOfAssetsFromLossyStrategyThatLossesWhileWithdrawingCustomMaxlossReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 4; // loss only quarter of strategy
        uint256 amountToWithdraw = _amount / 2; // withdraw half deposit
        uint256 maxLoss = 0;
        address lossyStrategy = _createLossyStrategy();

        queue.push(lossyStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setWithdrawingLoss(amountToLose);

        vm.expectRevert("too much loss");
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);
    }

    function test_WithdrawHalfOfStrategyAssetsFromLossyStrategyWithUnrealizedLossesNoMaxReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToWithdraw = _amount / 4; // withdraw a quarter deposit(half of strategy debit)
        uint256 maxLoss = 0;
        address lossyStrategy = _createLossyStrategy();

        queue.push(lossyStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        vm.expectRevert("too much loss");
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);
    }

    function test_WithdrawHalfOfStrategyAssetsFromLossyStrategyWithUnrealisedLossesWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0 && _amount % 8 == 0);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only quarter of strategy
        uint256 amountToWithdraw = _amount / 4; // withdraw a quarter deposit (half of strategy debt)
        uint256 maxLoss = _amount / 2;
        address lossyStrategy = _createLossyStrategy();

        queue.push(lossyStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in lossy strategy
        LossyStrategy(lossyStrategy).setLoss(msg.sender, amountToLose);

        vm.expectEmit(address(vault));
        emit DebtUpdated(
            lossyStrategy,
            amountPerStrategy,
            amountPerStrategy - amountToWithdraw
        );

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - amountToLose / 2,
            _amount / 4
        );
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), _amount - amountToWithdraw);
        assertEq(vault.totalSupply(), _amount - amountToWithdraw);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), _amount - amountToWithdraw);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(strategy), amountPerStrategy);
        assertEq(
            asset.balanceOf(lossyStrategy),
            amountPerStrategy - amountToLose - amountToLose / 2
        ); // withdrawn from strategy
        assertEq(asset.balanceOf(user), amountToWithdraw - amountToLose / 2); // it only takes half loss
    }

    function test_RedeemHalfOfStrategyAssetsFromLockedLossyStrategyWithUnrealisedLossesWithdrawsLessThanDeposited(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(
            _amount % 2 == 0 &&
                _amount % 4 == 0 &&
                _amount % 8 == 0 &&
                _amount % 5 == 0
        );
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToLock = (amountToLose * 9) / 10;
        uint256 amountToWithdraw = _amount / 4; // withdraw a quarter deposit (half of strategy debt)
        uint256 maxLoss = _amount;
        address lockedStrategy = _createLockedStrategy();
        uint256 shares = _amount;
        queue.push(lockedStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in locked strategy
        vm.prank(lockedStrategy);
        asset.transfer(msg.sender, amountToLose);

        // lock half of remaining funds
        LockedStrategy(lockedStrategy).setLockedFunds(amountToLock, 1 days);

        uint256 expectedLockedOut = amountToLose / 10;
        uint256 expectedLockedLoss = expectedLockedOut;
        uint256 expectedLiquidOut = amountToWithdraw -
            expectedLockedOut -
            expectedLockedLoss;

        // new debt index would be in `DebtUpdated` event
        uint256[2] memory newDebts = [
            amountPerStrategy - expectedLockedOut - expectedLockedLoss,
            amountPerStrategy - expectedLiquidOut
        ];
        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, newDebts[i]);
        }

        vm.expectEmit(address(vault));
        emit Withdraw(
            user,
            user,
            user,
            amountToWithdraw - expectedLockedLoss,
            shares / 4
        );
        vm.prank(user);
        vault.withdraw(amountToWithdraw, user, user, maxLoss, queue);

        assertEq(vault.totalAssets(), _amount - amountToWithdraw);
        assertEq(vault.totalSupply(), _amount - amountToWithdraw);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), _amount - amountToWithdraw);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(
            asset.balanceOf(strategy),
            amountPerStrategy - expectedLiquidOut
        );
        assertEq(
            asset.balanceOf(lockedStrategy),
            amountPerStrategy - amountToLose - expectedLockedOut
        ); // withdrawn from strategy
        assertEq(asset.balanceOf(user), amountToWithdraw - expectedLockedLoss); // it only takes half loss
        assertEq(vault.balanceOf(user), _amount - amountToWithdraw);
    }

    function test_RedeemHalfOfStrategyAssetsFromLockedLossyStrategyWithUnrealizedLossesCustomMaxLossReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of strategy
        uint256 amountToLock = (amountToLose * 9) / 10;
        uint256 amountToWithdraw = _amount / 4; // withdraw a quarter deposit (half of strategy debt)
        uint256 maxLoss = 0;
        address lockedStrategy = _createLockedStrategy();
        queue.push(lockedStrategy);
        queue.push(strategy);

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // lose half of assets in locked strategy
        vm.prank(lockedStrategy);
        asset.transfer(msg.sender, amountToLose);

        // lock half of remaining funds
        LockedStrategy(lockedStrategy).setLockedFunds(amountToLock, 1 days);

        vm.expectRevert("too much loss");
        vm.prank(user);
        vault.redeem(amountToWithdraw, user, user, maxLoss, queue);
    }

    function test_WithdrawWithMultipleLiquidStrategiesMoreAssetsThanDebtWithdraws(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        uint256 amountPerStrategy = _amount / 2; // deposit half of amount per strategy
        address newStrategy = _createLiquidStrategy();
        queue.push(strategy);
        queue.push(newStrategy);

        // enough so that it could serve a full withdraw with the profit
        // deposit assets to vault
        uint256 profit = amountPerStrategy + 1;

        // deposit assets to vault
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        for (uint i; i < queue.length; ++i) {
            vm.prank(strategyManager);
            vault.addStrategy(queue[i]);
            _addDebtToStrategy(queue[i], amountPerStrategy);
        }

        // airdrop assets to the strategy
        asset.mint(address(this), _amount);
        asset.transfer(strategy, profit);

        // events check
        for (uint i; i < queue.length; ++i) {
            vm.expectEmit(address(vault));
            emit DebtUpdated(queue[i], amountPerStrategy, 0);
        }
        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, _amount, _amount);
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);

        _checkVaultEmpty();

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(LiquidStrategy(strategy).totalAssets(), profit);
        assertEq(asset.balanceOf(strategy), profit);
        assertEq(asset.balanceOf(newStrategy), 0);
        assertEq(asset.balanceOf(user), _amount);
    }

    // ------------------HELPER FUNCTIONS----------------------//

    function _addDebtToStrategy(uint256 newDebt) private {
        vm.startPrank(debtManager);
        vault.updateMaxDebtForStrategy(address(strategy), newDebt);
        vault.updateDebt(address(strategy), newDebt);
        vm.stopPrank();
    }

    function _addDebtToStrategy(address _strategy, uint256 newDebt) private {
        vm.startPrank(debtManager);
        vault.updateMaxDebtForStrategy(_strategy, newDebt);
        vault.updateDebt(_strategy, newDebt);
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

    function _checkVaultEmpty() private {
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
    }

    function _createLiquidStrategy() private returns (address _strategy) {
        _strategy = address(new LiquidStrategy(address(vault), address(asset)));
    }

    function _createLockedStrategy() private returns (address _strategy) {
        _strategy = address(new LockedStrategy(address(vault), address(asset)));
    }

    function _createLossyStrategy() private returns (address _strategy) {
        _strategy = address(new LossyStrategy(address(vault), address(asset)));
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

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event DebtUpdated(
        address indexed strategy,
        uint256 currentDebt,
        uint256 newDebt
    );
}
