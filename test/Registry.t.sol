pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/contracts/Registry.sol";

contract RegistryTest is Test {

    Registry _registry;
    address _eoAdmin = vm.addr(1);
    address asset1 = vm.addr(2);
    function setUp() public {
        // deploy contracts
        string memory _name = "Test Registry";
        _registry = new Registry(_name, _eoAdmin);
        assertEq(_registry.name(), _name);
        assertEq(_registry.numAssets(), 0);
    }

    function test_deployNewVault() public {
        // deploy new vault
        address _roleManager = vm.addr(3);
        address _vault = _registry.deployNewVault(asset1, "Test Vault", "TV", _roleManager, block.timestamp + 1 weeks);
        assertEq(_registry.numAssets(), 1);
        assertEq(_registry.assets(0), asset1);
        assertEq(_registry.assetIsUsed(asset1), true);
        assertEq(_registry.numDeployedVaults(asset1), 1);
        assertEq(_registry.getDeployedVaults(asset1)[0], _vault);
        assertEq(_registry.numDeployedStrategies(asset1), 0);
        assertFalse(address(_registry.factory())==address(0));
    }

    function test_registerStrategy() public {
        // deploy new vault
        address _roleManager = vm.addr(3);
        address _vault = _registry.deployNewVault(asset1, "Test Vault", "TV", _roleManager, block.timestamp + 1 weeks);
        assertEq(_registry.numAssets(), 1);
        assertEq(_registry.assets(0), asset1);
        assertEq(_registry.assetIsUsed(asset1), true);
        assertEq(_registry.numDeployedVaults(asset1), 1);
        assertEq(_registry.getDeployedVaults(asset1)[0], _vault);
        assertEq(_registry.numDeployedStrategies(asset1), 0);
        assertFalse(address(_registry.factory())==address(0));

        // register strategy

        address _strategy = vm.addr(4);
        vm.mockCall(_strategy, abi.encodeWithSignature("asset()"), abi.encode(asset1));
        _registry.registerStrategy(_strategy, block.timestamp);
        assertEq(_registry.numAssets(), 1);
        assertEq(_registry.numDeployedStrategies(asset1), 1);
        assertEq(_registry.getDeployedStrategies(asset1)[0], _strategy);
    }
}