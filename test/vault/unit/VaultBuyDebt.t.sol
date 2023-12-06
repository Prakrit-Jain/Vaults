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
        debtManager = vm.addr(3);
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

    function test_BuyDebtStrategyNotActiveReverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        
        address user = vm.addr(4);
        _mintAndDepositIntoVault(user, user, _amount);

        // Approve vault to pull funds.
        asset.mint(debtManager, _amount);
        vm.prank(debtManager);
        asset.approve(address(vault), _amount);

        vm.expectRevert("Not active");
        vm.prank(debtManager);
        vault.buyDebt(address(strategy), _amount);
    }

    function test_BuyDebtNoDebtReverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        
        address user = vm.addr(4);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));
        
        // Approve vault to pull funds.
        asset.mint(debtManager, _amount);
        vm.prank(debtManager);
        asset.approve(address(vault), _amount);

        vm.expectRevert("Nothing to buy");
        vm.prank(debtManager);
        vault.buyDebt(address(strategy), _amount);
    }

    function test_BuyDebtNoAmountReverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        
        address user = vm.addr(4);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));

        _addDebtToStrategy(_amount);
        
        // Approve vault to pull funds.
        asset.mint(debtManager, _amount);
        vm.prank(debtManager);
        asset.approve(address(vault), _amount);

        vm.expectRevert("Nothing to buy with");
        vm.prank(debtManager);
        vault.buyDebt(address(strategy), 0);
    }

    function test_BuyDebtNotEnoughSharesReverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        
        address user = vm.addr(4);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));

        _addDebtToStrategy(_amount);
        
        // Approve vault to pull funds.
        asset.mint(debtManager, _amount);
        vm.prank(debtManager);
        asset.approve(address(vault), _amount);

        vm.expectRevert("Not enough shares");
        vm.prank(debtManager);
        vault.buyDebt(address(strategy), _amount * 2);
    }

    function test_BuyDebtFullDebt(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        
        address user = vm.addr(4);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));

        _addDebtToStrategy(_amount);
        
        // Approve vault to pull funds.
        asset.mint(debtManager, _amount);
        vm.prank(debtManager);
        asset.approve(address(vault), _amount);

        uint256 beforeBalance = asset.balanceOf(debtManager);
        uint256 beforeShares = strategy.balanceOf(debtManager);

        vm.prank(debtManager);
        vault.buyDebt(address(strategy), _amount);

        assertEq(vault.totalIdle(), _amount);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.pricePerShare(), 10 ** asset.decimals());
        uint256 currentDebt = _reportStrategy();
        assertEq(currentDebt, 0);
        assertEq(strategy.balanceOf(debtManager), beforeShares + _amount);
        assertEq(asset.balanceOf(debtManager), beforeBalance - _amount);
        
    }

    function test_BuyDebtHalfDebt(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        
        address user = vm.addr(4);
        _mintAndDepositIntoVault(user, user, _amount);

        vm.prank(strategyManager);
        vault.addStrategy(address(strategy));

        _addDebtToStrategy(_amount);

        uint256 toBuy = _amount / 2;
        
        // Approve vault to pull funds.
        asset.mint(debtManager, toBuy);
        vm.prank(debtManager);
        asset.approve(address(vault), toBuy);

        uint256 beforeBalance = asset.balanceOf(debtManager);
        uint256 beforeShares = strategy.balanceOf(debtManager);

        vm.prank(debtManager);
        vault.buyDebt(address(strategy), toBuy);

        assertEq(vault.totalIdle(), toBuy);
        assertEq(vault.totalDebt(), _amount - toBuy);
        assertEq(vault.pricePerShare(), 10 ** asset.decimals());
        uint256 currentDebt = _reportStrategy();
        assertEq(currentDebt, _amount - toBuy);
        // assert shares got moved
        assertEq(strategy.balanceOf(debtManager), beforeShares + toBuy);
        assertEq(asset.balanceOf(debtManager), beforeBalance - toBuy);
        
    }





    

    

    // ----------------HELPER FUNCTIONS -------------------//
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

    function _reportStrategy() private view returns(uint256 currentDebt) {
        (, , currentDebt, ) = vault.strategies(
            address(strategy)
        );
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

    event DebtPurchased(address strategy, uint256 amount);

    event DebtUpdated(
        address indexed strategy,
        uint256 currentDebt,
        uint256 newDebt
    );
}
