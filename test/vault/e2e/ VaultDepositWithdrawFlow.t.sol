pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "../../../src/contracts/VaultFactory.sol";
import {Vault} from "../../../src/contracts/Vault.sol";
import "forge-std/console.sol";

contract VaultTest is Test {
    ERC20Mock public asset;
    uint256 decimals = 18;
    uint256 MAX_BPS = 10_000;
    uint256 wad = 10 ** decimals;
    VaultFactory vaultFactory;
    Vault vault;
    address roleManager;
    address depositLimitManager;
    address[] arr;

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
                profitMaxUnlockTime
            )
        );
        vm.prank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vm.prank(depositLimitManager);
        vault.setDepositLimit(1e30);
    }

    function test_depositAndWithdraw(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        uint256 amount = _amount;
        uint256 halfAmount = amount / 2;
        uint256 quarterAmount = halfAmount / 2;
        address user1 = vm.addr(3);
        _mintAndDepositIntoVault(user1, user1, quarterAmount);

        assertEq(vault.totalSupply(), quarterAmount);
        assertEq(asset.balanceOf(address(vault)), quarterAmount);
        assertEq(vault.totalIdle(), quarterAmount);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.pricePerShare(), wad); // 1 : 1 price

        //set deposit limit to halfAmount and max deposit to test deposit limit
        vm.prank(depositLimitManager);
        vault.setDepositLimit(halfAmount);

        asset.mint(user1, amount);
        vm.startPrank(user1);
        asset.approve(address(vault), amount);
        vm.expectRevert();
        vault.deposit(amount, user1);
        vm.stopPrank();

        _mintAndDepositIntoVault(user1, user1, quarterAmount);
        assertEq(vault.totalSupply(), halfAmount);
        assertEq(asset.balanceOf(address(vault)), halfAmount);
        assertEq(vault.totalIdle(), halfAmount);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.pricePerShare(), wad); // 1 : 1 price

        console.log(vault.balanceOf(user1));
        vm.prank(user1);
        vault.withdraw(halfAmount, user1, user1, 0, arr);

        _checkVaultEmpty();
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.pricePerShare(), wad);
    }

    function test_delegatedDepositAndWithdraw(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_amount % 2 == 0 && _amount % 4 == 0);
        address user1 = vm.addr(2);
        address user2 = vm.addr(3);
        address user3 = vm.addr(4);
        // 1. Deposit from user1 and send shares to user2
        _mintAndDepositIntoVault(user1, user2, _amount);

        // user1 no longer has any assets
        assertEq(asset.balanceOf(user1), 0);
        // user1 does not have any vault shares
        assertEq(vault.balanceOf(user1), 0);
        // user2 has been issued the vault shares
        assertEq(vault.balanceOf(user2), _amount);

        // 2. Withdraw from user2 to user3
        vm.prank(user2);
        vault.withdraw(_amount, user3, user2, 0, arr);

        // user2 no longer has any shares
        assertEq(vault.balanceOf(user2), 0);
        // user3 receive assets
        assertEq(asset.balanceOf(user3), _amount);
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
}
