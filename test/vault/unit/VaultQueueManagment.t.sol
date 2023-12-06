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
        strategy = new LiquidStrategy(address(vault), address(asset));
        vm.startPrank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vault.setStrategyManager(strategyManager);
        vault.setDebtManager(debtManager);
        vm.stopPrank();
        vm.prank(depositLimitManager);
        vault.setDepositLimit(1e30);
    }

    function test_WithdrawNoQueueWithInsufficientFundsInVaultReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        _addDebtToStrategy(_amount);

        vm.startPrank(roleManager);
        vault.setDefaultQueue(queue);
        vm.stopPrank();

        vm.expectRevert("insufficient assets in vault");
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
    }

    function test_WithdrawQueueWithInsufficientFundsInVaultWithdraws(
        uint _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        _addDebtToStrategy(_amount);

        queue.push(address(strategy));
        vm.startPrank(roleManager);
        vault.setDefaultQueue(queue);
        vm.stopPrank();

        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, _amount, _amount);
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
        _checkVaultEmpty();
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(user), _amount);
    }

    function test_WithdrawQueueWithInactiveStrategyReverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        LiquidStrategy inActiveStrategy = new LiquidStrategy(
            address(vault),
            address(asset)
        );
        queue.push(address(inActiveStrategy));
        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        _addDebtToStrategy(_amount);

        vm.expectRevert("inactive strategy");
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
    }

    function test_WithdrawQueueWithLiquidStrategyWithdraws(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        _addDebtToStrategy(_amount);

        queue.push(address(strategy));
        vm.startPrank(roleManager);
        vault.setDefaultQueue(queue);
        vm.stopPrank();

        vm.expectEmit(address(vault));
        emit Withdraw(user, user, user, _amount, _amount);
        vm.prank(user);
        vault.withdraw(_amount, user, user, 0, queue);
        _checkVaultEmpty();
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(user), _amount);
    }

    // TODO: Add test to check removal and adding strategies works.
    function test_AddElevenStrategyAddsTenToQueue() public {
        assertEq(vault.getDefaultQueue(), queue);

        for (uint i; i < 10; ++i) {
            LiquidStrategy _strategy = new LiquidStrategy(
                address(vault),
                address(asset)
            );
            vm.prank(strategyManager);
            vault.addStrategy(address(_strategy));
        }

        assertEq((vault.getDefaultQueue()).length, 10);

        // Make sure we can still add a strategy, but doesnt change the queue
        LiquidStrategy _strategy = new LiquidStrategy(
            address(vault),
            address(asset)
        );
        vm.prank(strategyManager);
        vault.addStrategy(address(_strategy));

        (uint256 activation, , , ) = vault.strategies(address(_strategy));
        assertFalse(activation == 0);

        // default Queue length remains same
        assertEq((vault.getDefaultQueue()).length, 10);
    }

    function test_RevokeStrategyRemovesStrategyFromQueue() public {
        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        queue.push(address(strategy));

        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.revokeStrategy(address(strategy));

        (uint256 activation, , , ) = vault.strategies(address(strategy));
        assertEq(activation, 0);

        // default Queue gets empty
        assertEq((vault.getDefaultQueue()).length, 0);
    }

    function test_RevokeStrategyMultipleStrategiesRemovesStrategyFromQueue()
        public
    {
        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        queue.push(address(strategy));

        LiquidStrategy newStrategy = new LiquidStrategy(
            address(vault),
            address(asset)
        );
        vm.prank(strategyManager);
        vault.addStrategy(address(newStrategy));
        queue.push(address(newStrategy));

        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.revokeStrategy(address(strategy));

        (uint256 activation, , , ) = vault.strategies(address(strategy));
        assertEq(activation, 0);

        delete queue[0];
        _orderedQueue(0);

        assertEq((vault.getDefaultQueue()).length, 1);
        assertEq(vault.getDefaultQueue(), queue);
    }

    function testSetDefaultQueue() public {
        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        queue.push(address(strategy));

        LiquidStrategy newStrategy = new LiquidStrategy(
            address(vault),
            address(asset)
        );
        vm.prank(strategyManager);
        vault.addStrategy(address(newStrategy));
        queue.push(address(newStrategy));

        assertEq(vault.getDefaultQueue(), queue);

        // setting up new Queue
        queue.pop();
        queue.pop();
        queue.push(address(newStrategy));
        queue.push(address(strategy));
        address[] memory newQueue = queue;

        vm.expectEmit(address(vault));
        emit UpdateDefaultQueue(newQueue);

        vm.prank(roleManager);
        vault.setDefaultQueue(newQueue);
    }

    function testSetDefaultQueueInactiveStrategyReverts() public {
        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        queue.push(address(strategy));

        // create second strategy without addding it to vault
        LiquidStrategy newStrategy = new LiquidStrategy(
            address(vault),
            address(asset)
        );

        assertEq(vault.getDefaultQueue(), queue);

        // setting up new Queue
        queue.push(address(newStrategy));
        address[] memory newQueue = queue;

        vm.expectRevert("!inactive");
        vm.prank(roleManager);
        vault.setDefaultQueue(newQueue);
    }

    function testSetDefaultQueueTooLongQueueReverts() public {
        assertEq(vault.getDefaultQueue(), queue);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));

        // setting up mock Queue longer than 10
        for (uint i; i < 11; ++i) {
            queue.push(address(strategy));
        }

        vm.expectRevert("Queue length greater than MAX_QUEUE");
        vm.prank(roleManager);
        vault.setDefaultQueue(queue);
    }

    //---------------HELPER FUNCTIONS------------------//
    function _addDebtToStrategy(uint256 newDebt) private {
        vm.startPrank(debtManager);
        vault.updateMaxDebtForStrategy(address(strategy), newDebt);
        vault.updateDebt(address(strategy), newDebt);
        vm.stopPrank();
    }

    function _checkVaultEmpty() private {
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
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

    function _orderedQueue(uint index) private {
        for (uint i = index; i < queue.length - 1; i++) {
            queue[i] = queue[i + 1];
        }
        queue.pop();
    }

    // events
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

    event UpdateDefaultQueue(address[] newDefaultQueue);
}
