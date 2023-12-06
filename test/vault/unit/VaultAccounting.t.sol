pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "../../../src/contracts/VaultFactory.sol";
import {Vault} from "../../../src/contracts/Vault.sol";

contract VaultTest is Test {
    ERC20Mock public asset;
    VaultFactory vaultFactory;
    Vault vault;
    address roleManager;
    address depositLimitManager;

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
        vm.prank(roleManager);
        vault.setDepositLimitManager(depositLimitManager);
        vm.prank(depositLimitManager);
        vault.setDepositLimit(1e30);
    }

    function test_VaultAirdropDoNotIncreasePps(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        address user = vm.addr(1);
        _mintAndDepositIntoVault(user, user, _amount);
        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertFalse(vaultBalance == 0);

        uint256 ppsBeforeAirdrop = vault.pricePerShare();

        // aidrop to vault
        asset.mint(address(this), _amount / 10);
        asset.transfer(address(vault), _amount / 10);

        // pps doesn't change
        assertEq(vault.pricePerShare(), ppsBeforeAirdrop);
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
}
