 # Vaults

This repository contains the Smart Contracts for vault implementation.

- `Registry.sol` - The Registry contract where all base strategies are registered and it contains all information related to vaults and strategies

- `VaultFactory.sol` - The base factory from where all vaults will be deployed using CREATE2 minimal proxy clones.

- `Vault.sol` - The ERC4626-compliant Vault that will handle all logic associated with deposits, withdraws, strategy management, profit reporting, etc.

---
- Run `forge build` to build the project.
- Run `forge compile` to compile the contracts.
- Run `forge test` to run all the tests.

