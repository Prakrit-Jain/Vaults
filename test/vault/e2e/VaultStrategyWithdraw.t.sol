pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "../../../src/contracts/VaultFactory.sol";
import {Vault} from "../../../src/contracts/Vault.sol";
import {LiquidStrategy} from "../../Mock/Strategies/MockLiquidStrategy.sol";
import {LockedStrategy} from "../../Mock/Strategies/MockLockedStrategy.sol";

contract VaultTest is Test {
    ERC20Mock public asset;
    uint256 decimals = 18;
    uint256 MAX_BPS = 10_000;
    VaultFactory vaultFactory;
    Vault vault;
    address roleManager;
    address depositLimitManager;
    address strategyManager;
    address debtManager;
    address minimumIdleManager;
    address user1;
    address user2;
    LiquidStrategy liquidStrategy;
    LockedStrategy lockedStrategy;
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

        liquidStrategy = new LiquidStrategy(address(vault), address(asset));
        lockedStrategy = new LockedStrategy(address(vault), address(asset));

        vm.startPrank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vault.setStrategyManager(strategyManager);
        vault.setDebtManager(debtManager);
        vault.setMinimumIdleManager(minimumIdleManager);

        vm.stopPrank();
        vm.prank(depositLimitManager);
        vault.setDepositLimit(10e30);

        vm.startPrank(strategyManager);
        vault.addStrategy(address(liquidStrategy));
        vault.addStrategy(address(lockedStrategy));
        vm.stopPrank();

        liquidStrategy.setMaxDebt(10e30);
        lockedStrategy.setMaxDebt(10e30);
    }

    function test_MultipleStrategyWithdrawFlow(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount / 1e2);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        uint256 lowAmount = _amount;
        uint256 highAmount = _amount * 1e2;
        uint256 vaultBalance = lowAmount + highAmount;

        uint256 liquidStrategyDebt = vaultBalance / 4; // deposit a quarter
        uint256 lockedStrategyDebt = vaultBalance / 2; // deposit half, locking half of deposit
        uint256 amountToLock = lockedStrategyDebt / 2;

        address[] memory emptyQueue = queue;
        queue.push(address(lockedStrategy));
        queue.push(address(liquidStrategy));

        // deposit assets to vault
        _mintAndDepositIntoVault(user1, user1, lowAmount);
        _mintAndDepositIntoVault(user2, user2, highAmount);

        // set up strategies
        _addDebtToStrategy(address(liquidStrategy), liquidStrategyDebt);
        _addDebtToStrategy(address(lockedStrategy), lockedStrategyDebt);

        // lock half of assets in locked strategy
        lockedStrategy.setLockedFunds(amountToLock, 1 days);

        uint256 currentIdle = vaultBalance / 4;
        uint256 currentDebt = (vaultBalance * 3) / 4;

        assertEq(vault.totalIdle(), currentIdle);
        assertEq(vault.totalDebt(), currentDebt);
        assertEq(asset.balanceOf(address(vault)), currentIdle);
        assertEq(asset.balanceOf(address(liquidStrategy)), liquidStrategyDebt);
        assertEq(asset.balanceOf(address(lockedStrategy)), lockedStrategyDebt);

        // withdraw small amount as user1 from total idle
        vm.prank(user1);
        vault.withdraw(lowAmount / 2, user1, user1, 0, queue);

        currentIdle -= lowAmount / 2;

        assertEq(asset.balanceOf(user1), lowAmount / 2);
        assertEq(vault.totalIdle(), currentIdle);
        assertEq(vault.totalDebt(), currentDebt);
        assertEq(asset.balanceOf(address(vault)), currentIdle);
        assertEq(asset.balanceOf(address(liquidStrategy)), liquidStrategyDebt);
        assertEq(asset.balanceOf(address(lockedStrategy)), lockedStrategyDebt);

        // drain remaining total idle as user2
        vm.prank(user2);
        vault.withdraw(currentIdle, user2, user2, 0, emptyQueue);

        assertEq(asset.balanceOf(user2), currentIdle);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), currentDebt);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), liquidStrategyDebt);
        assertEq(asset.balanceOf(address(lockedStrategy)), lockedStrategyDebt);

        address user3 = vm.addr(8);
        // withdraw small amount as user1 from locked strategy to user3
        queue.pop(); // queue = [lockedStrategy]
        vm.prank(user1);
        vault.withdraw(lowAmount / 2, user3, user1, 0, queue);

        currentDebt -= lowAmount / 2;
        lockedStrategyDebt -= lowAmount / 2;

        assertEq(asset.balanceOf(user3), lowAmount / 2);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), currentDebt);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), liquidStrategyDebt);
        assertEq(asset.balanceOf(address(lockedStrategy)), lockedStrategyDebt);

        // attempt to withdraw remaining amount from only liquid strategy but revert
        queue.pop(); // queue = []
        queue.push(address(liquidStrategy)); // queue = [liquidStrategy];
        uint256 balanceToWithdraw = Vault(vault).balanceOf(user2) -
            amountToLock; // exclude locked amount
        vm.expectRevert("insufficient assets in vault");
        vm.prank(user2);
        vault.withdraw(balanceToWithdraw, user2, user2, 0, queue);

        queue.pop();
        queue.push(address(lockedStrategy));
        queue.push(address(liquidStrategy));

        vm.prank(user2);
        vault.withdraw(balanceToWithdraw, user2, user2, 0, queue);

        assertEq(asset.balanceOf(user2), highAmount - amountToLock);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), amountToLock);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lockedStrategy)), amountToLock);

        // unlock locked strategy assets
        skip(1 days);
        lockedStrategy.freeLockedFunds();

        queue.pop();
        queue.pop();
        queue.push(address(liquidStrategy));
        queue.push(address(lockedStrategy));

        // test withdrawing from empty strategy
        vm.prank(user2);
        vault.withdraw(amountToLock, user2, user2, 0, queue);

        _checkVaultEmpty();
        assertEq(asset.balanceOf(user2), highAmount);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lockedStrategy)), 0);
    }

    //-----------------------HELPER FUNCTIONS --------------------//

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

    function _addDebtToStrategy(address _strategy, uint256 newDebt) private {
        vm.startPrank(debtManager);
        Vault(vault).updateMaxDebtForStrategy(address(_strategy), newDebt);
        Vault(vault).updateDebt(address(_strategy), newDebt);
        vm.stopPrank();
    }

}
