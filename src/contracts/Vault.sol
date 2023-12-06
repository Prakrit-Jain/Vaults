// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../interfaces/IStrategy.sol";

contract Vault is
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC4626Upgradeable
{
    using MathUpgradeable for uint256;

    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);

    //Events

    //Strategy events
    event StrategyChanged(
        address indexed strategy,
        StrategyChangeType indexed changeType
    );

    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt
    );

    //Debt Managment Events
    event DebtUpdated(
        address indexed strategy,
        uint256 currentDebt,
        uint256 newDebt
    );

    event UpdatedMaxDebtForStrategy(
        address indexed sender,
        address indexed strategy,
        uint256 newDebt
    );

    event UpdateProfitMaxUnlockTime(uint256 profitMaxUnlockTime);

    event UpdateMinimumTotalIdle(uint256 minimumTotalIdle);

    event UpdateRoleManager(address indexed roleManager);

    event UpdateDepositLimit(uint256 depositLimit);

    event UpdateDefaultQueue(address[] newDefaultQueue);

    event DebtPurchased(address indexed strategy, uint256 amount);

    event Shutdown();

    // STRUCTS
    struct StrategyParams {
        // Timestamp when the strategy was added.
        uint256 activation;
        // Timestamp of the strategies last report.
        uint256 lastReport;
        // The current assets the strategy holds.
        uint256 currentDebt;
        // The max assets the strategy can hold.
        uint256 maxDebt;
    }

    // CONSTANTS
    // The max length the withdrawal queue can be.
    uint256 constant MAX_QUEUE = 10;
    // 100% in Basis Points.
    uint256 constant MAX_BPS = 10000;
    // Extended for profit locking calculations.
    uint256 constant MAX_BPS_EXTENDED = 1000000000000;

    // Roles
    // Role that adds and removes debt from strategies
    bytes32 private constant DEBT_MANAGER = keccak256("DEBT_MANAGER");

    // Role that can add and revoke strategies to the vault.
    bytes32 private constant STRATEGY_MANAGER = keccak256("STRATEGY_MANAGER");

    // Role that sets deposit limit for the vault.
    bytes32 private constant DEPOSIT_LIMIT_MANAGER =
        keccak256("DEPOSIT_LIMIT_MANAGER");

    // Role that sets the minimum total idle the vault should keep.
    bytes32 private constant MINIMUM_IDLE_MANAGER =
        keccak256("MINIMUM_IDLE_MANAGER");

    // Role that manages the allocation and distribution of yeid to the protocol and Khalani chain staker
    bytes32 private constant YIELD_MANAGER = keccak256("YIELD_MANAGER");

    // ENUMS
    enum StrategyChangeType {
        Added,
        Revoked
    }

    // Deployer contract used to retrieve the protocol fee config.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable factory;

    // Underlying token used by the vault.
    IERC20Upgradeable assetUnderlying;

    // Mapping that records all the strategies that are allowed to receive assets from the vault.
    mapping(address => StrategyParams) public strategies;

    // The current default withdrawal queue.
    address[] public defaultQueue;

    // Total amount of assets that has been deposited in strategies.
    uint256 public totalDebt;

    // Current assets held in the vault contract. Replacing balanceOf(address(this)) to avoid price per share manipulation.
    uint256 public totalIdle;

    // Minimum amount of assets that should be kept in the vault contract to allow for fast, cheap redeems.
    uint256 public minTotalIdle;

    // Maximum amount of tokens that the vault can accept. If totalAssets > depositLimit, deposits will revert.
    uint256 public depositLimit;

    // Address that can add and remove roles to addresses.
    address public roleManager;

    // Temporary variable to store the address of the next roleManager until the role is accepted.
    address public futureRoleManager;

    // State of the vault
    bool public shutdown;

    // The amount of time profits will unlock over.
    uint256 public profitMaxUnlockTime;

    // The timestamp of when the current unlocking period ends.
    uint256 public fullProfitUnlockDate;

    // The per second rate at which profit will unlock.
    uint256 public profitUnlockingRate;

    // Last timestamp of the most recent profitable report.
    uint256 public lastProfitUpdate;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        factory = msg.sender;

        // Note that the contract is upgradeable. Use initialize() or reinitializers
        // to set the state variables.
        _disableInitializers();
    }

    modifier onlyAdmin() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Access Denied, Must have DEFAULT_ADMIN_ROLE"
        );
        _;
    }

    /**
     * @notice Initialize the vault. Sets the assetUnderlying, name, symbol, and role Manager
     * @param _asset The address of the assetUnderlying that the vault will accept
     * @param _name  The name of the vault token
     * @param _symbol The symbol of the vault token
     * @param _roleManager  The address that can add and remove roles to addresses
     * @param _profitMaxUnlockTime The amount of time that the profit will be locked for
     */
    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _roleManager,
        uint256 _profitMaxUnlockTime
    ) external initializer {
        assetUnderlying = IERC20Upgradeable(_asset);
        require(_profitMaxUnlockTime > 0, "profit unlock time too low");
        require(
            _profitMaxUnlockTime <= 31556952,
            "profit unlock time too high"
        );
        profitMaxUnlockTime = _profitMaxUnlockTime;
        __ERC4626_init(assetUnderlying);
        __ERC20_init(_name, _symbol);
        roleManager = _roleManager;
        _grantRole(DEFAULT_ADMIN_ROLE, roleManager);
    }

    //------------------SETTERS---------------------------------//
    /**
     * @notice Sets the `DEBT_MANAGER` role to `_debtManager`.
     * @dev Can only be called by the current `DEFAULT_ADMIN_ROLE`.
     *
     * @param _debtManager New `debtManager` address.
     */
    function setDebtManager(address _debtManager) external onlyAdmin {
        _grantRole(DEBT_MANAGER, _debtManager);
    }

    /**
     * @notice Sets the `STRATEGY_MANAGER` role to `_strategyManager`.
     * @dev Can only be called by the current `DEFAULT_ADMIN_ROLE`.
     *
     * @param _strategyManager New `STRATEGY_MANAGER` address.
     */
    function setStrategyManager(address _strategyManager) external onlyAdmin {
        _grantRole(STRATEGY_MANAGER, _strategyManager);
    }

    /**
     * @notice Sets the `DEPOSIT_LIMIT_MANAGER` role to `_depositLimitManager`.
     * @dev Can only be called by the current `DEFAULT_ADMIN_ROLE`.
     *
     * @param _depositLimitManager New `DEPOSIT_LIMIT_MANAGER` address.
     */
    function setDepositLimitManager(
        address _depositLimitManager
    ) external onlyAdmin {
        _grantRole(DEPOSIT_LIMIT_MANAGER, _depositLimitManager);
    }

    /**
     * @notice Sets the `MINIMUM_IDLE_MANAGER` role to `_minimumIdleManager`.
     * @dev Can only be called by the current `DEFAULT_ADMIN_ROLE`.
     *
     * @param _minimumIdleManager New `MINIMUM_IDLE_MANAGER` address.
     */
    function setMinimumIdleManager(
        address _minimumIdleManager
    ) external onlyAdmin {
        _grantRole(MINIMUM_IDLE_MANAGER, _minimumIdleManager);
    }

    /**
     * @notice Sets the `YIELD_MANAGER` role to `_yieldManager`.
     * @dev Can only be called by the current `DEFAULT_ADMIN_ROLE`.
     *
     * @param _yieldManager New `YIELD_MANAGER` address.
     */
    function setYieldManager(address _yieldManager) external onlyAdmin {
        _grantRole(YIELD_MANAGER, _yieldManager);
    }

    function _unlockedShares() private view returns (uint256) {
        uint256 unlockedShares_;
        if (fullProfitUnlockDate > block.timestamp) {
            uint256 timePassed = block.timestamp - lastProfitUpdate;
            unlockedShares_ =
                (timePassed * profitUnlockingRate) /
                MAX_BPS_EXTENDED;
        } else if (fullProfitUnlockDate != 0) {
            unlockedShares_ = super.balanceOf(address(this));
        }
        return unlockedShares_;
    }

    function _totalSupply() internal view returns (uint256) {
        // Need to account for the shares issued to the vault that have unlocked.
        return super.totalSupply() - _unlockedShares();
    }

    function _burnUnlockedShares() internal {
        // Burns shares that have been unlocked since last update.
        // In case the full unlocking period has passed, it stops the unlocking.
        uint256 unlockedShares_ = _unlockedShares();
        if (unlockedShares_ == 0) {
            return;
        }

        if (fullProfitUnlockDate > block.timestamp) {
            lastProfitUpdate = block.timestamp;
        }

        _burn(address(this), unlockedShares_);
    }

    function _mintSharesForAmount(
        uint256 amount,
        address receiver
    ) internal returns (uint256) {
        // Issues shares that are worth 'amount' in the underlying token (assetUnderlying).
        // WARNING: this takes into account that any new assets have been summed
        // to totalAssets (otherwise pps will go down).
        uint256 totalSupply_ = _totalSupply();
        uint256 totalAssets_ = _totalAssets();
        uint256 newShares;

        // if no supply PPS = 1.
        if (totalSupply_ == 0) {
            newShares = amount;
        } else if (totalAssets_ > amount) {
            newShares = (amount * totalSupply_) / (totalAssets_ - amount);
        } else {
            // If totalSupply > 0 but amount = totalAssets we want to revert because
            // after first deposit, getting here would mean that the rest of the shares
            // would be diluted to a pps of 0. Issuing shares would then mean
            // either the new depositer or the previous depositers will loose money.
            require(totalAssets_ > amount, "amount too high");
        }

        if (newShares == 0) {
            return 0;
        }

        _mint(receiver, newShares);
        return newShares;
    }

    function _totalAssets() internal view returns (uint256) {
        // Total amount of assets that are in the vault and in the strategies.
        return totalIdle + totalDebt;
    }

    /**
     * @notice The amount of shares that the strategy would
     *  exchange for the amount of assets provided, in an
     *  ideal scenario where all the conditions are met.
     *
     * @param assets The amount of underlying.
     * @return Expected shares that `assets` represents.
     */
    function _convertToShares(
        uint256 assets,
        MathUpgradeable.Rounding rounding
    ) internal view override returns (uint256) {
        // Saves an extra SLOAD if totalAssets() is non-zero.
        uint256 totalAssets_ = totalAssets();
        uint256 totalSupply_ = totalSupply();

        // If assets are 0 but supply is not PPS = 0.
        if (totalAssets_ == 0) return totalSupply_ == 0 ? assets : 0;

        return assets.mulDiv(totalSupply_, totalAssets_, rounding);
    }

    /**
     * @notice The amount of assets that the strategy would
     * exchange for the amount of shares provided, in an
     * ideal scenario where all the conditions are met
     *
     * @param shares The amount of the strategies shares
     * @return Expected amount of `asset` the shares represents
     */
    function _convertToAssets(
        uint256 shares,
        MathUpgradeable.Rounding rounding
    ) internal view override returns (uint256) {
        // Saves an extra SLOAD if totalSupply() is non-zero
        uint256 supply = totalSupply();

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, rounding);
    }

    function maxDeposit(
        address receiver
    ) public view override returns (uint256) {
        if (receiver == address(0) || receiver == address(this)) {
            return 0;
        }

        uint256 totalAssets_ = _totalAssets();
        uint256 _depositLimit = depositLimit;
        if (totalAssets_ >= _depositLimit) {
            return 0;
        }

        unchecked {
            return _depositLimit - totalAssets_;
        }
    }

    function _deposit(
        address sender,
        address receiver,
        uint256 assets
    ) internal returns (uint256) {
        require(shutdown == false, "shutdown");
        require(
            receiver != address(0) || receiver != address(this),
            "invalid receiver"
        );
        require(
            _totalAssets() + assets <= depositLimit,
            "exceed deposit limit"
        );

        SafeERC20Upgradeable.safeTransferFrom(
            assetUnderlying,
            sender,
            address(this),
            assets
        );
        totalIdle += assets;
        uint256 shares = _mintSharesForAmount(assets, receiver);

        require(shares > 0, "cannnot mint zero");

        emit Deposit(sender, receiver, assets, shares);
        return shares;
    }

    function _mintShares(
        address sender,
        address receiver,
        uint256 shares
    ) internal returns (uint256) {
        require(shutdown == false, "shutdown");
        require(
            receiver != address(0) || receiver != address(this),
            "invalid receiver"
        );

        uint256 assets = _convertToAssets(shares, MathUpgradeable.Rounding.Up);
        require(assets > 0, "cannot mint zero");
        require(
            _totalAssets() + assets <= depositLimit,
            "exceed deposit limit"
        );

        SafeERC20Upgradeable.safeTransferFrom(
            assetUnderlying,
            msg.sender,
            address(this),
            assets
        );
        totalIdle += assets;

        _mint(receiver, shares);
        emit Deposit(sender, receiver, assets, shares);
        return assets;
    }

    function _assessShareOfUnrealizedLosses(
        address strategy,
        uint256 assetsNeeded
    ) internal view returns (uint256) {
        // Returns the share of losses that a user would take if withdrawing from this strategy
        // e.g. if the strategy has unrealised losses for 10% of its current debt and the user
        // wants to withdraw 1000 tokens, the losses that he will take are 100 token

        // Minimum of how much debt the debt should be worth.
        uint256 strategyCurrentDebt = strategies[strategy].currentDebt;
        // The actual amount that the debt is currently worth.
        uint256 vaultShares = IStrategy(strategy).balanceOf(address(this));
        uint256 strategyAssets = IStrategy(strategy).convertToAssets(
            vaultShares
        );

        // If no losses , return 0
        if (strategyAssets >= strategyCurrentDebt || strategyCurrentDebt == 0) {
            return 0;
        }

        // Users will withdraw assetsToWithdraw divided by loss ratio (strategyAsets / strategyCurrentDebt - 1),
        // but will only receive assetsToWithdraw.
        // NOTE: If there are unrealised losses, the user will take his share.

        uint256 numerator = assetsNeeded * strategyAssets;
        uint256 lossesUserShare = assetsNeeded -
            numerator /
            strategyCurrentDebt;

        if (numerator % strategyCurrentDebt != 0) {
            lossesUserShare += 1;
        }

        return lossesUserShare;
    }

    function _redeem(
        address sender,
        address receiver,
        address owner,
        uint256 assets,
        uint256 sharesToBurn,
        uint256 maxLoss,
        address[] memory _strategies
    ) internal returns (uint256) {
        // This will attempt to free up the full amount of assets equivalent to
        // `sharesToBurn` and transfer them to the `receiver`. If the vault does
        // not have enough idle funds it will go through any strategies provided by
        // either the withdrawer or the strategy manager to free up enough funds to
        // service the request.

        // The vault will attempt to account for any unrealized losses taken on from
        // strategies since their respective last reports.

        // Any losses realized during the withdraw from a strategy will be passed on
        // to the user that is redeeming their vault shares.

        require(receiver != address(0), "Receiver cannot be Zero Address");

        require(sharesToBurn > 0, "no shares to redeem");
        require(
            balanceOf(owner) >= sharesToBurn,
            "insufficient shares to redeem"
        );

        if (sender != owner) {
            _spendAllowance(owner, sender, sharesToBurn);
        }

        uint256 requestedAssets = assets;
        uint256 currTotalIdle = totalIdle;

        //  If there are not enough assets in the Vault contract, we try to free
        // # funds from strategies.
        if (requestedAssets > currTotalIdle) {
            if (_strategies.length == 0) {
                _strategies = defaultQueue;
            }

            uint256 currTotalDebt = totalDebt;
            uint256 assetsNeeded;
            unchecked {
                assetsNeeded = requestedAssets - currTotalIdle;
            }
            uint256 assetsToWithdraw;

            uint256 previousBalance = IERC20Upgradeable(assetUnderlying)
                .balanceOf(address(this));

            for (uint256 i; i < _strategies.length; ) {
                address strategy = _strategies[i];
                require(
                    strategies[strategy].activation != 0,
                    "inactive strategy"
                );

                // How much should the strategy have.
                uint256 currentDebt = strategies[strategy].currentDebt;

                // What is the max amount to withdraw from this strategy.
                assetsToWithdraw = MathUpgradeable.min(
                    assetsNeeded,
                    currentDebt
                );

                // Cache maxWithdraw now for use if unrealized loss > 0
                uint256 _maxWithdraw = IStrategy(strategy).maxWithdraw(
                    address(this)
                );

                // CHECK FOR UNREALISED LOSSES
                // If unrealised losses > 0, then the user will take the proportional share
                // and realize it (required to avoid users withdrawing from lossy strategies).
                // NOTE: strategies need to manage the fact that realising part of the loss can
                // mean the realisation of 100% of the loss!! (i.e. if for withdrawing 10% of the
                // strategy it needs to unwind the whole position, generated losses might be bigger)
                uint256 unrealisedLossesShare = _assessShareOfUnrealizedLosses(
                    strategy,
                    assetsToWithdraw
                );
                if (unrealisedLossesShare > 0) {
                    // If max withdraw is limiting the amount to pull, we need to adjust the portion of
                    // the unrealized loss the user should take.
                    if (
                        _maxWithdraw < assetsToWithdraw - unrealisedLossesShare
                    ) {
                        // How much would we want to withdraw
                        uint256 wanted = assetsToWithdraw -
                            unrealisedLossesShare;
                        // Get the proportion of unrealised comparing what we want vs. what we can get
                        unrealisedLossesShare =
                            (unrealisedLossesShare * _maxWithdraw) /
                            wanted;
                        // Adjust assetsToWithdraw so all future calcultations work correctly
                        assetsToWithdraw = _maxWithdraw + unrealisedLossesShare;
                    }

                    assetsToWithdraw -= unrealisedLossesShare;
                    requestedAssets -= unrealisedLossesShare;

                    // NOTE: done here instead of waiting for regular update of these values
                    // because it's a rare case (so we can save minor amounts of gas)
                    assetsNeeded -= unrealisedLossesShare;
                    currTotalDebt -= unrealisedLossesShare;

                    // If max withdraw is 0 and unrealised loss is still > 0 then the strategy likely
                    // realized a 100% loss and we will need to realize that loss before moving on.
                    if (_maxWithdraw == 0 && unrealisedLossesShare > 0) {
                        // Adjust the strategy debt accordingly.
                        uint256 newDebt = currentDebt - unrealisedLossesShare;
                        // Update strategies storage
                        strategies[strategy].currentDebt = newDebt;
                        emit DebtUpdated(strategy, currentDebt, newDebt);
                    }
                }
                assetsToWithdraw = MathUpgradeable.min(
                    assetsToWithdraw,
                    _maxWithdraw
                );

                if (assetsToWithdraw == 0) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                // WITHDRAW FROM STRATEGY
                // Need to get shares since we use redeem to be able to take on losses.
                _withdrawFromStrategy(assetsToWithdraw, strategy);

                uint256 postBalance = IERC20Upgradeable(assetUnderlying)
                    .balanceOf(address(this));

                // Always check withdrawn against the real amounts.
                uint256 withdrawn = postBalance - previousBalance;
                uint256 loss;

                if (withdrawn > assetsToWithdraw) {
                    if (withdrawn > currentDebt) {
                        assetsToWithdraw = currentDebt;
                    } else {
                        unchecked {
                            assetsToWithdraw += withdrawn - assetsToWithdraw;
                        }
                    }
                } else if (withdrawn < assetsToWithdraw) {
                    unchecked {
                        loss = assetsToWithdraw - withdrawn;
                    }
                }
                {
                    // NOTE: strategy's debt decreases by the full amount but the total idle increases
                    // by the actual amount only (as the difference is considered lost).
                    {
                        currTotalIdle =
                            currTotalIdle +
                            (assetsToWithdraw - loss);
                        requestedAssets = requestedAssets - loss;
                        currTotalDebt = currTotalDebt - assetsToWithdraw;

                        // Vault will reduce debt because the unrealised loss has been taken by user
                        uint256 _newDebt = currentDebt -
                            (assetsToWithdraw + unrealisedLossesShare);

                        strategies[strategy].currentDebt = _newDebt;

                        emit DebtUpdated(strategy, currentDebt, _newDebt);
                    }

                    // Break if we have enough total idle to serve initial request.
                    if (requestedAssets <= currTotalIdle) {
                        break;
                    }

                    // We update the previousBalance variable here to save gas in next iteration.
                    previousBalance = postBalance;

                    // Reduce what we still need. Safe to use assetsToWithdraw
                    // here since it has been checked against requestedAssets
                    assetsNeeded -= assetsToWithdraw;
                }
                unchecked {
                    ++i;
                }
            }
            // If we exhaust the queue and still have insufficient total idle, revert
            require(
                currTotalIdle >= requestedAssets,
                "insufficient assets in vault"
            );
            totalDebt = currTotalDebt;
        }

        if (assets > requestedAssets && maxLoss < MAX_BPS) {
            uint256 lossThreshold = (assets * maxLoss) / MAX_BPS;
            require(assets - requestedAssets <= lossThreshold, "too much loss");
        }

        _burn(owner, sharesToBurn);
        totalIdle = currTotalIdle - requestedAssets;
        SafeERC20Upgradeable.safeTransfer(
            assetUnderlying,
            receiver,
            requestedAssets
        );

        emit Withdraw(sender, receiver, owner, requestedAssets, sharesToBurn);
        return requestedAssets;
    }

    function _withdrawFromStrategy(
        uint256 assetsToWithdraw,
        address strategy
    ) private {
        uint256 sharesToWithdraw = MathUpgradeable.min(
            IStrategy(strategy).previewWithdraw(assetsToWithdraw),
            IStrategy(strategy).balanceOf(address(this))
        );
        IStrategy(strategy).redeem(
            sharesToWithdraw,
            address(this),
            address(this)
        );
    }

    //------------------STRATEGY MANAGEMENT---------------------------------//

    function _addStrategy(address newStrategy) internal {
        require(
            newStrategy != address(0) && newStrategy != address(this),
            "strategy cannot be zero address"
        );
        require(
            IStrategy(newStrategy).asset() == address(assetUnderlying),
            "invalid asset"
        );
        require(
            strategies[newStrategy].activation == 0,
            "strategy already active"
        );

        // Add the new strategy to the mapping.
        strategies[newStrategy] = StrategyParams({
            activation: block.timestamp,
            lastReport: block.timestamp,
            currentDebt: 0,
            maxDebt: 0
        });

        if (defaultQueue.length < MAX_QUEUE) {
            defaultQueue.push(newStrategy);
        }

        emit StrategyChanged(newStrategy, StrategyChangeType.Added);
    }

    function _revokeStrategy(address strategy, bool force) internal {
        require(strategies[strategy].activation != 0, "strategy not active");

        // If force revoking a strategy, it will cause a loss.
        uint256 loss;

        if (strategies[strategy].currentDebt != 0) {
            require(force, "strategy has debt");
            // Vault realizes the full loss of outstanding debt.
            loss = strategies[strategy].currentDebt;
            // Adjust total vault debt.
            totalDebt -= loss;

            emit StrategyReported(strategy, 0, loss, 0);
        }

        // Set strategy params all back to 0 (WARNING: it can be readded).
        strategies[strategy] = StrategyParams({
            activation: 0,
            lastReport: 0,
            currentDebt: 0,
            maxDebt: 0
        });

        uint256 length = defaultQueue.length;
        for (uint256 i; i < length; ) {
            if (defaultQueue[i] == strategy) {
                if (i < length - 1) {
                    defaultQueue[i] = defaultQueue[length - 1];
                }
                defaultQueue.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        emit StrategyChanged(strategy, StrategyChangeType.Revoked);
    }

    //----------------------DEBT MANAGEMENT-----------------------------//
    function _updateDebt(
        address strategy,
        uint256 targetDebt
    ) internal returns (uint256) {
        // The vault will re-balance the debt vs target debt. Target debt must be
        // smaller or equal to strategy's maxDebt. This function will compare the
        // current debt with the target debt and will take funds or deposit new
        // funds to the strategy.

        // The strategy can require a maximum amount of funds that it wants to receive
        // to invest. The strategy can also reject freeing funds if they are locked.

        // How much we want the strategy to have.
        uint256 newDebt = targetDebt;
        // How much the strategy currently has.
        uint256 currentDebt = strategies[strategy].currentDebt;

        if (shutdown) {
            newDebt = 0;
        }

        require(newDebt != currentDebt, "new debt equals current debt");

        if (currentDebt > newDebt) {
            // Reduce Debt
            uint256 assetsToWithdraw;
            unchecked {
                assetsToWithdraw = currentDebt - newDebt;
            }

            // Ensure we always have minimumTotalIdle when updating debt.
            uint256 minimumTotalIdle = minTotalIdle;
            uint256 _totalIdle = totalIdle;

            // Respect minimum total idle in vault
            if (_totalIdle + assetsToWithdraw < minimumTotalIdle) {
                unchecked {
                    assetsToWithdraw = minimumTotalIdle - totalIdle;
                }

                // Cant withdraw more than the strategy has.
                if (assetsToWithdraw > currentDebt) {
                    assetsToWithdraw = currentDebt;
                }
            }

            // Check how much we are able to withdraw.
            uint256 withdrawable = IStrategy(strategy).maxWithdraw(
                address(this)
            );
            require(withdrawable != 0, "nothing to withdraw");

            // If insufficient withdrawable, withdraw what we can.
            if (withdrawable < assetsToWithdraw) {
                assetsToWithdraw = withdrawable;
            }

            // If there are unrealised losses we don't let the vault reduce its debt until there is a new report
            uint256 unrealisedLossesShare = _assessShareOfUnrealizedLosses(
                strategy,
                assetsToWithdraw
            );
            require(
                unrealisedLossesShare == 0,
                "strategy has unrealised losses"
            );

            // Always check the actual amount withdrawn.
            uint256 preBalance = assetUnderlying.balanceOf(address(this));
            IStrategy(strategy).withdraw(
                assetsToWithdraw,
                address(this),
                address(this)
            );
            uint256 postBalance = assetUnderlying.balanceOf(address(this));

            // making sure we are changing according to the real result no matter what.
            // This will spend more gas but makes it more robust. Also prevents issues
            // from a faulty strategy that either under or over delievers 'assetsToWithdraw'
            assetsToWithdraw = MathUpgradeable.min(
                postBalance - preBalance,
                currentDebt
            );

            totalIdle += assetsToWithdraw;
            totalDebt -= assetsToWithdraw;

            newDebt = currentDebt - assetsToWithdraw;
        } else {
            // We are increasing the strategies debt

            // Revert if targetDebt cannot be achieved due to configured maxDebt for given strategy
            require(
                newDebt <= strategies[strategy].maxDebt,
                "target debt higher than max debt"
            );

            // Vault is increasing debt with the strategy by sending more funds.
            uint256 _maxDeposit = IStrategy(strategy).maxDeposit(address(this));
            require(_maxDeposit != 0, "nothing to deposit");

            // Deposit the difference between desired and current.
            uint256 assetsToDeposit = newDebt - currentDebt;
            if (assetsToDeposit > _maxDeposit) {
                // Deposit as much as possible.
                assetsToDeposit = _maxDeposit;
            }

            // Ensure we always have minimumTotalIdle when updating debt.
            uint256 minimumTotalIdle = minTotalIdle;
            uint256 _totalIdle = totalIdle;

            require(_totalIdle > minimumTotalIdle, "no funds to deposit");
            uint256 availableIdle;
            unchecked {
                availableIdle = _totalIdle - minimumTotalIdle;
            }

            // If insufficient funds to deposit, transfer only what is free.
            if (assetsToDeposit > availableIdle) {
                assetsToDeposit = availableIdle;
            }

            if (assetsToDeposit > 0) {
                // Approve the strategy to pull only what we are giving it.
                SafeERC20Upgradeable.forceApprove(
                    assetUnderlying,
                    strategy,
                    assetsToDeposit
                );

                uint256 preBalance = assetUnderlying.balanceOf(address(this));
                IStrategy(strategy).deposit(assetsToDeposit, address(this));
                uint256 postBalance = assetUnderlying.balanceOf(address(this));

                // Make sure our approval is always back to 0.
                SafeERC20Upgradeable.forceApprove(assetUnderlying, strategy, 0);

                // Making sure we are changing according to the real result no
                // matter what. This will spend more gas but makes it more robust.
                assetsToDeposit = preBalance - postBalance;

                totalIdle -= assetsToDeposit;
                totalDebt += assetsToDeposit;
            }

            newDebt = currentDebt + assetsToDeposit;
        }

        strategies[strategy].currentDebt = newDebt;

        emit DebtUpdated(strategy, currentDebt, newDebt);
        return newDebt;
    }

    //---------------- ACCOUNTING MANAGEMENT ----------------------------//
    function _processReport(
        address strategy
    ) internal returns (uint256 gain, uint256 loss) {
        // Processing a report means comparing the debt that the strategy has taken
        // with the current amount of funds it is reporting. If the strategy owes
        // less than it currently has, it means it has had a profit, else (assets < debt)
        // it has had a loss.

        // Different strategies might choose different reporting strategies: pessimistic,
        // only realised P&L, ... The best way to report depends on the strategy.

        // The profit will be distributed following a smooth curve over the vaults
        // profitMaxUnlockTime seconds. Losses will be taken immediately, first from the
        // profit buffer (avoiding an impact in pps), then will reduce pps.

        // Make sure we have a valid strategy.
        require(strategies[strategy].activation != 0, "inactive strategy");

        // Burn shares that have been unlocked since the last update
        _burnUnlockedShares();

        // Vault assesses profits using 4626 compliant interface.
        // NOTE: It is important that a strategies `convertToAssets` implementation
        // cannot be manipulated or else the vault could report incorrect gains/losses.
        uint256 strategyShares = IStrategy(strategy).balanceOf(address(this));
        // How much the vault's position is worth.
        uint256 totalAssets_ = IStrategy(strategy).convertToAssets(
            strategyShares
        );
        // How much the vault had deposited to the strategy.
        uint256 currentDebt = strategies[strategy].currentDebt;

        // Compare reported assets vs. the current debt.
        if (totalAssets_ > currentDebt) {
            // We have a gain.
            unchecked {
                gain = totalAssets_ - currentDebt;
            }
        } else {
            // We have a loss.
            unchecked {
                loss = currentDebt - totalAssets_;
            }
        }

        // `sharesToBurn` is derived from amounts that would reduce the vaults PPS.
        // NOTE: this needs to be done before any pps changes
        uint256 sharesToBurn;
        // Only need to burn shares if there is a loss.
        if (loss > 0) {
            // The amount of shares we will want to burn to offset losses.
            sharesToBurn = _convertToShares(loss, MathUpgradeable.Rounding.Up);
        }

        // Shares to lock is any amounts that would otherwise increase the vault's PPS.
        uint256 newlyLockedShares;

        // Record any reported gains.
        if (gain > 0) {
            // NOTE: this will increase totalAssets
            strategies[strategy].currentDebt += gain;
            totalDebt += gain;

            // Vault will issue shares worth the profit to itself to lock and avoid instant PPS change.
            newlyLockedShares += _mintSharesForAmount(gain, address(this));
        }

        // Strategy is reporting a loss
        if (loss > 0) {
            strategies[strategy].currentDebt -= loss;
            totalDebt -= loss;
        }

        // NOTE: should be precise (no new unlocked shares due to above's burn of shares)
        // newlyLockedShares have already been minted/transfered to the vault, so they need to be subtracted
        // no risk of underflow because they have just been minted.

        uint256 previouslyLockedShares = super.balanceOf(address(this)) -
            newlyLockedShares;

        // Now that PPS has updated, we can burn the shares we intended to burn as a result of losses.
        // NOTE: If a value reduction (losses) has occurred, prioritize burning locked profit to avoid
        // negative impact on price per share. Price per share is reduced only if losses exceed locked value.
        if (sharesToBurn > 0) {
            // Can't burn more than the vault owns.
            sharesToBurn = MathUpgradeable.min(
                sharesToBurn,
                previouslyLockedShares + newlyLockedShares
            );
            _burn(address(this), sharesToBurn);

            // We burn first the newly locked shares, then the previously locked shares.
            uint256 sharesNotToLock = MathUpgradeable.min(
                sharesToBurn,
                newlyLockedShares
            );
            // Reduce the amounts to lock by how much we burned
            newlyLockedShares -= sharesNotToLock;
            previouslyLockedShares -= (sharesToBurn - sharesNotToLock);
        }

        // Update unlocking rate and time to fully unlocked.
        uint256 totalLockedShares = previouslyLockedShares + newlyLockedShares;
        if (totalLockedShares > 0) {
            uint256 previouslyLockedTime;
            uint256 _fullProfitUnlockDate = fullProfitUnlockDate;
            // Check if we need to account for shares still unlocking.
            if (_fullProfitUnlockDate > block.timestamp) {
                // There will only be previously locked shares if time remains.
                // We calculate this here since it will not occur every time we lock shares.
                previouslyLockedTime =
                    previouslyLockedShares *
                    (_fullProfitUnlockDate - block.timestamp);
            }

            // newProfitLockingPeriod is a weighted average between the remaining time of the previously locked shares and the profitMaxUnlockTime
            uint256 newProfitLockingPeriod = (previouslyLockedTime +
                newlyLockedShares *
                profitMaxUnlockTime) / totalLockedShares;
            // Calculate how many shares unlock per second.
            profitUnlockingRate =
                (totalLockedShares * MAX_BPS_EXTENDED) /
                newProfitLockingPeriod;
            // Calculate how long until the full amount of shares is unlocked.
            fullProfitUnlockDate = block.timestamp + newProfitLockingPeriod;
            // Update the last profitable report timestamp.
            lastProfitUpdate = block.timestamp;
        } else {
            // NOTE: only setting this to 0 will turn in the desired effect, no need
            // to update lastProfitUpdate or fullProfitUnlockDate
            profitUnlockingRate = 0;
        }

        // Record the report of profit timestamp.
        strategies[strategy].lastReport = block.timestamp;

        // We have to recalculate the fees paid for cases with an overall loss.
        emit StrategyReported(
            strategy,
            gain,
            loss,
            strategies[strategy].currentDebt
        );
    }

    //---------------SETTERS------------------------------------//

    /**
     * @notice Set the new default queue array.
     * @dev Will check each strategy to make sure it is active.
     * @param newDefaultQueue The new default queue array.
     */
    function setDefaultQueue(
        address[] memory newDefaultQueue
    ) external onlyAdmin {
        require(
            newDefaultQueue.length < MAX_QUEUE,
            "Queue length greater than MAX_QUEUE"
        );

        // Make sure every strategy in the new queue is active
        for (uint256 i; i < newDefaultQueue.length; ) {
            require(
                strategies[newDefaultQueue[i]].activation != 0,
                "!inactive"
            );
            unchecked {
                ++i;
            }
        }

        // Save the new queue
        defaultQueue = newDefaultQueue;

        emit UpdateDefaultQueue(newDefaultQueue);
    }

    /**
     * @notice Set the new deposit limit.
     * @dev Can not be changed if shutdown.
     * @param newDepositLimit The new deposit limit.
     */
    function setDepositLimit(uint256 newDepositLimit) external {
        require(!shutdown, "Vault is shutdown");
        require(
            hasRole(DEPOSIT_LIMIT_MANAGER, msg.sender),
            "Must have DEPOSIT_LIMIT_MANAGER role to set deposit limit"
        );

        depositLimit = newDepositLimit;

        emit UpdateDepositLimit(newDepositLimit);
    }

    /**
     * @notice Set the new minimum total idle.
     * @param newMinimumTotalIdle The new minimum total idle.
     */
    function setMinimumTotalIdle(uint256 newMinimumTotalIdle) external {
        require(
            hasRole(MINIMUM_IDLE_MANAGER, msg.sender),
            "Must have MINIMUM_IDLE_MANAGER role to set minimum total idle"
        );

        minTotalIdle = newMinimumTotalIdle;

        emit UpdateMinimumTotalIdle(newMinimumTotalIdle);
    }

    /**
     * @notice Set the new profit max unlock time.
     * @dev The time is denominated in seconds and must be more than 0
     *      and less than 1 year. We don't need to update locking period
     *      since the current period will use the old rate and on the next
     *      report it will be reset with the new unlocking time.
     * @param newProfitMaxUnlockTime The new profit max unlock time.
     */
    function setProfitMaxUnlockTime(
        uint256 newProfitMaxUnlockTime
    ) external onlyAdmin {
        // Must be > 0 so we can unlock shares
        require(newProfitMaxUnlockTime > 0, "Profit unlock time too low");

        // Must be less than one year for report cycles
        require(
            newProfitMaxUnlockTime <= 31556952,
            "Profit unlock time too long"
        );

        profitMaxUnlockTime = newProfitMaxUnlockTime;

        emit UpdateProfitMaxUnlockTime(newProfitMaxUnlockTime);
    }

    /**
     * @notice Step 1 of 2 in order to transfer the
     *         role manager to a new address. This will set
     *         the futureRoleManager. Which will then need
     *         to be accepted by the new manager.
     * @param newRoleManager The new role manager address.
     */

    function transferRoleManager(address newRoleManager) external {
        require(
            msg.sender == roleManager,
            "Must be role manaager to transfer the role"
        );

        futureRoleManager = newRoleManager;
    }

    /**
     * @notice Accept the role manager transfer.
     */
    function acceptRoleManager() external {
        require(
            msg.sender == futureRoleManager,
            "Must future role manaager to accept the role"
        );

        roleManager = msg.sender;
        futureRoleManager = address(0);

        emit UpdateRoleManager(msg.sender);
    }

    //------------------VAULT STATUS VIEWS------------------------//

    /**
     * @notice Get the amount of shares that have been unlocked.
     * @return The amount of shares that have been unlocked.
     */
    function unlockedShares() external view returns (uint256) {
        return _unlockedShares();
    }

    /**
     * @notice Get the price per share.
     * @dev This value offers limited precision. Integrations that require
     * exact precision should use convertToAssets or convertToShares instead.
     *
     * @return . The price per share.
     */
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    /**
     * @notice Get the available deposit limit.
     * @return The available deposit limit.
     */
    function availableDepositLimit() external view returns (uint256) {
        uint256 limit = depositLimit;
        uint256 assets = _totalAssets();

        if (limit > assets) {
            unchecked {
                return limit - assets;
            }
        }

        return 0;
    }

    /**
     * @notice Get the full default withdrawal queue currently set.
     * @return The current default withdrawal queue.
     */
    function getDefaultQueue() external view returns (address[] memory) {
        return defaultQueue;
    }

    //-------------------REPORTING MANAGEMENT------------------------//
    /**
     * @notice Process the report of a strategy.
     * @param strategy The strategy to process the report for.
     * @return The gain and loss of the strategy.
     */
    function processReport(
        address strategy
    ) external nonReentrant returns (uint256, uint256) {
        require(
            hasRole(STRATEGY_MANAGER, msg.sender),
            "Must have STRATEGY_MANAGER role"
        );
        return _processReport(strategy);
    }

    /**
     * @notice Used for manager to buy bad debt from the vault.
     * @dev This should only ever be used in an emergency in place
     *      of force revoking a strategy in order to not report a loss.
     *      It allows the DEBT_MANAGER role to buy the strategies debt
     *      for an equal amount of `asset`. It's important to note that
     *      this does rely on the strategies `convertToShares` function to
     *      determine the amount of shares to buy.
     * @param strategy The strategy to buy the debt for.
     * @param amount The amount of debt to buy from the vault.
     */
    function buyDebt(address strategy, uint256 amount) external nonReentrant {
        require(
            hasRole(DEBT_MANAGER, msg.sender),
            "Must have DEBT_MANAGER role"
        );
        require(strategies[strategy].activation != 0, "Not active");

        // Cache the current debt
        uint256 currentDebt = strategies[strategy].currentDebt;

        require(currentDebt > 0, "Nothing to buy");
        require(amount > 0, "Nothing to buy with");

        // Get the current shares value for the amount
        uint256 shares = IStrategy(strategy).convertToShares(amount);

        require(shares > 0, "Can't buy 0");
        require(
            shares <= IStrategy(strategy).balanceOf(address(this)),
            "Not enough shares"
        );

        SafeERC20Upgradeable.safeTransferFrom(
            assetUnderlying,
            msg.sender,
            address(this),
            amount
        );

        // Adjust if needed to not underflow on math
        uint256 bought = (currentDebt < amount) ? currentDebt : amount;

        // Lower strategy debt
        strategies[strategy].currentDebt -= bought;
        // lower total debt
        totalDebt -= bought;
        // Increase total idle
        totalIdle += bought;

        emit DebtUpdated(strategy, currentDebt, currentDebt - bought);

        // Transfer the strategies shares out.
        SafeERC20Upgradeable.safeTransfer(
            IERC20Upgradeable(strategy),
            msg.sender,
            shares
        );

        emit DebtPurchased(strategy, bought);
    }

    //----------------------STRATEGY MANAGEMENT------------------------------//

    /**
     * @notice Add a new strategy.
     * @param newStrategy The new strategy to add.
     */
    function addStrategy(address newStrategy) external {
        require(
            hasRole(STRATEGY_MANAGER, msg.sender),
            "Must have STRATEGY_MANAGER role"
        );
        _addStrategy(newStrategy);
    }

    /**
     * @notice Revoke a strategy.
     * @param strategy The strategy to revoke.
     */
    function revokeStrategy(address strategy) external {
        require(
            hasRole(STRATEGY_MANAGER, msg.sender),
            "Must have STRATEGY_MANAGER role"
        );
        _revokeStrategy(strategy, false);
    }

    /**
     * @notice Force revoke a strategy.
     * @dev The vault will remove the strategy and write off any debt left
     *      in it as a loss. This function is a dangerous function as it can force a
     *      strategy to take a loss. All possible assets should be removed from the
     *      strategy first via updateDebt. If a strategy is removed erroneously it
     *      can be re-added and the loss will be credited as profit. Fees will apply.
     * @param strategy The strategy to force revoke.
     */
    function forceRevokeStrategy(address strategy) external {
        require(
            hasRole(STRATEGY_MANAGER, msg.sender),
            "Must have STRATEGY_MANAGER role"
        );
        _revokeStrategy(strategy, true);
    }

    //----------------------------DEBT MANAGEMENT-----------------------------//
    /**
     * @notice Update the max debt for a strategy.
     * @param strategy The strategy to update the max debt for.
     * @param newMaxDebt The new max debt for the strategy.
     */
    function updateMaxDebtForStrategy(
        address strategy,
        uint256 newMaxDebt
    ) external {
        require(
            hasRole(DEBT_MANAGER, msg.sender),
            "Must have DEBT_MANAGER role"
        );
        require(strategies[strategy].activation != 0, "inactive strategy");

        strategies[strategy].maxDebt = newMaxDebt;

        emit UpdatedMaxDebtForStrategy(msg.sender, strategy, newMaxDebt);
    }

    /**
     * @notice Update the debt for a strategy.
     * @param strategy The strategy to update the debt for.
     * @param targetDebt The target debt for the strategy.
     * @return The amount of debt added or removed.
     */
    function updateDebt(
        address strategy,
        uint256 targetDebt
    ) external nonReentrant returns (uint256) {
        require(
            hasRole(DEBT_MANAGER, msg.sender),
            "Must have DEBT_MANAGER role"
        );
        return _updateDebt(strategy, targetDebt);
    }

    //------------------------EMERGENCY MANAGMENT----------------------//
    /**
     * @notice Shutdown the vault.
     */
    function shutdownVault() external onlyAdmin {
        require(!shutdown, "Vault already shut down");

        // Shutdown the vault.
        shutdown = true;

        // Set deposit limit to 0.
        depositLimit = 0;

        emit UpdateDepositLimit(0);

        emit Shutdown();
    }

    //----------------------SHARE MANAGEMENT--------------------------------//
    /**
     * @notice Deposit assets into the vault.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @return shares The amount of shares minted.
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override(ERC4626Upgradeable)
        nonReentrant
        returns (uint256 shares)
    {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        shares = _deposit(_msgSender(), receiver, assets);
    }

    /**
     * @notice Mint shares for the receiver.
     * @param shares The amount of shares to mint.
     * @param receiver The address to receive the shares.
     * @return The amount of assets deposited.
     */
    function mint(
        uint256 shares,
        address receiver
    ) public override(ERC4626Upgradeable) nonReentrant returns (uint256) {
        return _mintShares(msg.sender, receiver, shares);
    }

    /**
     * @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
     * @dev The default behavior is to not allow any loss.
     * @param assets The amount of asset to withdraw.
     * @param receiver The address to receive the assets.
     * @param owner The address who's shares are being burnt.
     * @param maxLoss Optional amount of acceptable loss in Basis Points.
     * @param _strategies Optional array of strategies to withdraw from.
     * @return The amount of shares actually burnt.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external nonReentrant returns (uint256) {
        uint256 shares = _convertToShares(assets, MathUpgradeable.Rounding.Up);
        _redeem(
            msg.sender,
            receiver,
            owner,
            assets,
            shares,
            maxLoss,
            _strategies
        );
        return shares;
    }

    /**
     * @notice Redeems an amount of shares of `owner`s shares sending funds to `receiver`.
     * @dev The default behavior is to allow losses to be realized.
     * @param shares The amount of shares to burn.
     * @param receiver The address to receive the assets.
     * @param owner The address whose shares are being burnt.
     * @param maxLoss Optional amount of acceptable loss in Basis Points.
     * @param _strategies Optional array of strategies to withdraw from.
     * @return The amount of assets actually withdrawn.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external nonReentrant returns (uint256) {
        uint256 assets = _convertToAssets(shares, MathUpgradeable.Rounding.Up);
        // Always return the actual amount of assets withdrawn.
        return
            _redeem(
                msg.sender,
                receiver,
                owner,
                assets,
                shares,
                maxLoss,
                _strategies
            );
    }

    /**
     * @notice Returns the current balance for a given '_account'.
     * @dev If the '_account` is the strategy then this will subtract
     * the amount of shares that have been unlocked since the last profit first.
     * @param account the address to return the balance for.
     * @return . The current balance in y shares of the '_account'.
     */
    function balanceOf(
        address account
    )
        public
        view
        override(ERC20Upgradeable, IERC20Upgradeable)
        returns (uint256)
    {
        if (account == address(this)) {
            return super.balanceOf(account) - _unlockedShares();
        }
        return super.balanceOf(account);
    }

    /**
     * @notice Get the address of the asset.
     * @return The address of the asset.
     */
    function asset()
        public
        view
        override(ERC4626Upgradeable)
        returns (address)
    {
        return address(assetUnderlying);
    }

    function totalAssets()
        public
        view
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        return _totalAssets();
    }

    function totalSupply()
        public
        view
        override(ERC20Upgradeable, IERC20Upgradeable)
        returns (uint256)
    {
        return _totalSupply();
    }

    /**
     * @notice Assess the share of unrealised losses that a strategy has.
     * @param strategy The address of the strategy.
     * @param assetsNeeded The amount of assets needed to be withdrawn.
     * @return The share of unrealised losses that the strategy has.
     */
    function assessShareOfUnrealizedLosses(
        address strategy,
        uint256 assetsNeeded
    ) external view returns (uint256) {
        require(
            strategies[strategy].currentDebt >= assetsNeeded,
            "Insufficient debt"
        );
        return _assessShareOfUnrealizedLosses(strategy, assetsNeeded);
    }
}