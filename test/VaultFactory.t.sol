// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/contracts/Vault.sol";
import "../src/contracts/VaultFactory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract VaultFactoryTest is Test {
    error Shutdown();

    event NewVault(address indexed vaultAddress, address indexed asset);
    event FactoryShutdown();

    VaultFactory vaultFactory;
    address asset;
    function setUp() public {
        vaultFactory = new VaultFactory();
        asset = address(new ERC20("USDC","usdc"));
    }

    function test_DeployVault() public {
        //vars
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        address roleManger = vm.addr(1);
        //test
        vm.expectEmit(address(vaultFactory));
        emit NewVault(vaultFactory.getVaultFromUnderlying(asset,name,symbol), asset);
        address vault = vaultFactory.deployNewVault(asset, name, symbol, roleManger, 10000);
        assertEq(address(vaultFactory.getVaultFromUnderlying(asset,name,symbol)), address(vault));
        assertTrue(vaultFactory.isVaultDeployed(vault));
    }

    function test_DeployVault_InvalidCaller(address randomAddress) public {
        //vars
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        address roleManger = vm.addr(1);
        //test
        vm.assume(randomAddress != address(this));
        vm.prank(randomAddress);
        vm.expectRevert("Ownable: caller is not the owner");
        vaultFactory.deployNewVault(asset, name, symbol, roleManger, 10000);
    }

    function test_DeployVault_FactoryShutdown() public {
        //vars
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        address roleManger = vm.addr(1);
        //test
        vaultFactory.shutdownFactory();
        vm.expectRevert(Shutdown.selector);
        vaultFactory.deployNewVault(asset, name, symbol, roleManger, 10000);
    }

    function test_ShutdownFactory() public {
        vm.expectEmit(address(vaultFactory));
        vaultFactory.shutdown();
        emit FactoryShutdown();
        vaultFactory.shutdownFactory();
        vm.expectRevert(Shutdown.selector);
        vaultFactory.shutdownFactory();
    }

    function test_NoDuplicateVaults() public {
        //vars
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        address roleManger = vm.addr(1);
        //test
        address vault = vaultFactory.deployNewVault(asset, name, symbol, roleManger, 10000);
        vm.expectRevert();
        address vault1 = vaultFactory.deployNewVault(asset, name, symbol, roleManger, 10000);
    }

    function test_IsVaultDeployed() public {
        //vars
        string memory name = "USDCReserveVault";
        string memory symbol = "usdc.rv";
        address roleManger = vm.addr(1);
        //test
        address vault = vaultFactory.deployNewVault(asset, name, symbol, roleManger, 10000);
        assertTrue(vaultFactory.isVaultDeployed(vault));
        assertFalse(vaultFactory.isVaultDeployed(address(0)));
    }
}