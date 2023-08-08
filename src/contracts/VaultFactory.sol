pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./Vault.sol";

contract VaultFactory is Ownable {
    using Clones for address;

    error Shutdown();

    event NewVault(address indexed vaultAddress, address indexed asset);
    event FactoryShutdown();

    address public immutable vaultImplementation;
    bool public shutdown;

    constructor() {
        vaultImplementation = address(new Vault());
    }

    function _createAndInitializeVault(
        address asset,
        string memory _name,
        string memory _symbol,
        address roleManager,
        uint256 profitMaxUnlockTime,
        bytes32 _salt
    ) internal returns (address) {
        address vault = vaultImplementation.cloneDeterministic(_salt);
        Vault(vault).initialize(asset, _name, _symbol, roleManager, profitMaxUnlockTime);
        return vault;
    }

    /**
     * @notice Deploys a new vault base on the vaultImplementation.
     * @param asset The asset to be used for the vault.
     * @param _name The name of the new vault.
     * @param _symbol The symbol of the new vault.
     * @param roleManager The address of the role manager.
     * @param profitMaxUnlockTime The time over which the profits will unlock.
     * @return The address of the new vault.
     */
    function deployNewVault(
        address asset,
        string memory _name,
        string memory _symbol,
        address roleManager,
        uint256 profitMaxUnlockTime
    ) external onlyOwner returns (address) {
        if (shutdown) {
            revert Shutdown();
        }
        bytes32 salt = keccak256(abi.encode(msg.sender, asset, _name, _symbol));
        address vaultAddress = _createAndInitializeVault(asset, _name, _symbol, roleManager, profitMaxUnlockTime, salt);
        emit NewVault(vaultAddress, asset);
        return vaultAddress;
    }

    /**
     * @notice To stop new deployments through this factory.
     * @dev A one time switch available for the owner to stop new
     * vaults from being deployed through the factory.
     */
    function shutdownFactory() external onlyOwner {
        if (shutdown) {
            revert Shutdown();
        }
        shutdown = true;

        emit FactoryShutdown();
    }

    /**
     * @notice Computes a Vault's address from its accepted underlying token.
     * @dev The Vault returned may not be deployed yet. Use isVaultDeployed to check.
     * @param asset The ERC20 token address that the Vault should accept
     * @param _name The token name, the vault provides as shares to depositors
     * @param _symbol The token symbol,the vault provides as shares to depositors.
     */
    function getVaultFromUnderlying(address asset, string memory _name, string memory _symbol)
    external
    view
    onlyOwner
    returns (address)
    {
        bytes32 salt = keccak256(abi.encode(msg.sender, asset, _name, _symbol));
        address vault = vaultImplementation.predictDeterministicAddress(salt, address(this));

        return vault;
    }

    /**
     * @notice Returns if a Vault at an address has already been deployed.
     * @dev This function is useful to check the return values of getVaultFromUnderlying,
     * as it does not check that the Vault addresses it computes have been deployed yet.
     * @param vault The address of a Vault which may not have been deployed yet.
     * @return A boolean indicating whether the Vault has been deployed already.
     */
    function isVaultDeployed(address vault) external view returns (bool) {
        return vault.code.length > 0;
    }
}