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
    uint256 wad = 10 ** decimals;
    VaultFactory vaultFactory;
    LossyStrategy strategy;
    Vault vault;
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
        strategyManager = vm.addr(3);
        debtManager = vm.addr(4);
        minimumIdleManager = vm.addr(5);
        vaultFactory = new VaultFactory(msg.sender);
        vault = Vault(vaultFactory.deployNewVault(
            address(asset),
            name,
            symbol,
            roleManager,
            profitMaxUnlockTime
        ));
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

    function test_LossyStrategyFlow(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 firstLoss = _amount / 4;
        uint256 secondLoss = _amount / 2;
        address user1 = vm.addr(6);
        address user2 = vm.addr(7);
        _mintAndDepositIntoVault(user1, user1, _amount);

        assertEq(vault.balanceOf(user1), _amount);
        assertEq(vault.pricePerShare(), wad); // 1 : 1 price

        _addDebtToStrategy(_amount);

        assertEq(strategy.totalAssets(), _amount);
        assertEq(strategy.balanceOf(address(vault)), _amount);
        assertEq(vault.totalAssets(), _amount);
        (, , uint256 currentDebt, ) = vault.strategies(
            address(strategy)
        );
        assertEq(currentDebt, _amount);

        // simulate loss on strategy
        strategy.setLoss(msg.sender, firstLoss);

        assertEq(strategy.totalAssets(), _amount - firstLoss);

        vm.prank(strategyManager);
        (, uint256 _firstLoss) = vault.processReport(address(strategy));
        assertEq(_firstLoss, firstLoss);

        assertEq((vault.pricePerShare() / 1e16), 75); // pps = 0.75

        uint256 depositAmount = _amount;

        // user2 deposit assets to vault
        _mintAndDepositIntoVault(user2, user2, depositAmount);

        assertEq(vault.totalAssets(), depositAmount * 2 - firstLoss);

        // Since pps goes down , vault shares will be more for user2.
        assertGt(vault.balanceOf(user2), vault.balanceOf(user1));

        assertEq(vault.totalIdle(), depositAmount);
        assertEq(vault.totalDebt(), depositAmount - firstLoss);

        _addDebtToStrategy(vault.totalAssets());

        assertEq(strategy.totalAssets(), depositAmount * 2 - firstLoss);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), depositAmount * 2 - firstLoss);

        // simulate loss on strategy
        strategy.setLoss(msg.sender, secondLoss);

        assertEq(
            strategy.totalAssets(),
            depositAmount * 2 - firstLoss - secondLoss
        );

        vm.prank(strategyManager);
        (, uint256 _secondLoss) = vault.processReport(address(strategy));
        assertEq(_secondLoss, secondLoss);

        assertEq(
            vault.totalAssets(),
            depositAmount * 2 - firstLoss - secondLoss
        );

        // Lets set a `minimumTotalIdle` value
        vm.prank(minimumIdleManager);
        vault.setMinimumTotalIdle((depositAmount * 3) / 4);

        // we allowed more debt than `minimum_total_idle` allows us, to ensure `update_debt`
        // forces to comply with `minimum_total_idle`
        _addDebtToStrategy(depositAmount);

        assertEq(vault.totalIdle(), (depositAmount * 3) / 4);
        assertEq(
            strategy.totalAssets(),
            (depositAmount * 2) -
                firstLoss -
                secondLoss -
                vault.totalIdle()
        );

        // user1 withdraws all his shares in `vault.totalIdle`. Due to the lossy strategy, his shares have less value
        // and therefore he ends up with less assets than before
        uint256 shares = vault.balanceOf(user1);

        vm.prank(user1);
        vault.redeem(shares, user1, user1, MAX_BPS, queue);

        assertEq(vault.balanceOf(user1), 0);

        // seconds loss affects user1 in relation to the shares he has within the vault
        uint256 sharesRatio = ((depositAmount - firstLoss) * 10e30) /
            (depositAmount * 2 - firstLoss);
        assertGt(depositAmount, asset.balanceOf(user1));
        assertGt(vault.minTotalIdle(), vault.totalIdle());
        assertApproxEqAbs(
            asset.balanceOf(user1),
            (depositAmount - firstLoss - (secondLoss * sharesRatio) / 10e30),
            1
        );

        _addDebtToStrategy(depositAmount / 4);

        assertEq(strategy.totalAssets(), 0);

        (, , uint256 currentDebt1, uint256 maxDebt1 ) = vault.strategies(address(strategy));
        assertEq(currentDebt1, 0);
        assertEq(maxDebt1, depositAmount / 4);

        // user_2 withdraws everything else
        vm.startPrank(user2);
        // user_2 has now less assets, because strategy was lossy.
        vm.expectRevert("insufficient shares to redeem");
        vault.withdraw(depositAmount, user2, user2, 0, queue);
        vault.redeem(
            vault.balanceOf(user2),
            user2,
            user2,
            0,
            queue
        );
        vm.stopPrank();

        assertEq(vault.totalAssets(), 0);
        assertEq(vault.pricePerShare() / wad, 1);
        assertGt(depositAmount, asset.balanceOf(user2));

        vm.prank(strategyManager);
        vault.revokeStrategy(address(strategy));
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

    function _addDebtToStrategy(uint256 newDebt) private {
        vm.startPrank(debtManager);
        vault.updateMaxDebtForStrategy(address(strategy), newDebt);
        vault.updateDebt(address(strategy), newDebt);
        vm.stopPrank();
    }
}
