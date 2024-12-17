// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IMasterChefPulseX.sol";
import "../../interfaces/IRouter.sol";
import "../../interfaces/IProtocolAddresses.sol";
import "../../interfaces/IPair.sol";
import "../../interfaces/IStrategyVariables.sol";

/**
 * @title MasterChef strategy for PulseX exchange
 * @dev INC rewards
 */
contract MasterChefPulseXStrategy is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    address public constant WPLS = address(0xA1077a294dDE1B09bB078844df40758a5D0f9a27);

    address public Router;
    address public MasterChef;
    address public RewardToken;
    address public Vault;
    address public LPtoken;
    address public Token0;
    address public Token1;
    uint8 public poolID;

    address public ProtocolAddresses;
    address public StrategyVariables;

    address[] public RewardTokenToWPLSpath;
    address[] public RewardTokenToToken0path;
    address[] public RewardTokenToToken1path;

    uint256 public constant BASIS_POINT_DIVISOR = 10000;

    event ProtocolAddressesUpdated(address ProtocolAddresses);
    event Deposit(uint256 amount);
    event Withdraw(uint256 amount);
    event HarvestRun(address indexed caller, uint256 amount);
    event HarvestFeeProcessed(uint256 amount);
    event CallFeeProcessed(uint256 amount);

    uint256 MAX_INT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    constructor(
        address _LPtoken,
        uint8 _poolID,
        address _Vault,
        address _StrategyVariables,
        address _MasterChef,
        address _RewardToken,
        address _Router
    ) {
        LPtoken = _LPtoken;
        Token0 = IPair(LPtoken).token0();
        Token1 = IPair(LPtoken).token1();
        poolID = _poolID;
        Vault = _Vault;
        StrategyVariables = _StrategyVariables;
        MasterChef = _MasterChef;
        RewardToken = _RewardToken;
        Router = _Router;

        RewardTokenToWPLSpath = [RewardToken, WPLS];

        if (Token0 == WPLS) {
            RewardTokenToToken0path = [RewardToken, WPLS];
        } else if (Token0 != RewardToken) {
            RewardTokenToToken0path = [RewardToken, WPLS, Token0];
        }

        if (Token1 == WPLS) {
            RewardTokenToToken1path = [RewardToken, WPLS];
        } else if (Token1 != RewardToken) {
            RewardTokenToToken1path = [RewardToken, WPLS, Token1];
        }

        IERC20(RewardToken).safeApprove(Router, 0);
        IERC20(RewardToken).safeApprove(Router, MAX_INT);
        IERC20(Token0).safeApprove(Router, 0);
        IERC20(Token0).safeApprove(Router, MAX_INT);
        IERC20(Token1).safeApprove(Router, 0);
        IERC20(Token1).safeApprove(Router, MAX_INT);
    }

    receive() external payable {}

    modifier onlyVault() {
        require(msg.sender == Vault, "MasterChefPulseXStrategy: Caller is not the Vault");
        _;
    }

    function setProtocolAddresses(address _ProtocolAddresses) external onlyOwner {
        ProtocolAddresses = _ProtocolAddresses;
        emit ProtocolAddressesUpdated(ProtocolAddresses);
    }

    function balanceLP() public view returns (uint256) {
        return IERC20(LPtoken).balanceOf(address(this));
    }

    function masterChefBalanceLP() public view returns (uint256 amount) {
        (amount,) = IMasterChefPulseX(MasterChef).userInfo(poolID, address(this));
    }

    function balanceLPinStrategy() external view returns (uint256) {
        return balanceLP() + masterChefBalanceLP();
    }

    function balanceRewardToken() public view returns (uint256) {
        return IERC20(RewardToken).balanceOf(address(this));
    }

    // Withdraws from MasterChef claim pending rewards, so better to show pending + balance
    function getRewardsEarned() external view returns (uint256) {
        uint256 pendingRewards = IMasterChefPulseX(MasterChef).pendingInc(poolID, address(this));
        return pendingRewards + balanceRewardToken();
    }

    /**
     * @dev Deposits will be paused when strategy has been decommissioned
     */
    function deposit() public whenNotPaused {
        uint256 balance = balanceLP();
        require(balance > 0, "MasterChefPulseXStrategy: Deposit called with 0 balance");
        IERC20(LPtoken).safeIncreaseAllowance(MasterChef, balance);
        IMasterChefPulseX(MasterChef).deposit(poolID, balance);
        emit Deposit(balance);
    }

    /**
     * @dev Uses available balance in strategy, withdrawing from Masterchef to make up difference
     */
    function withdraw(uint256 amount) external onlyVault {
        uint256 balance = balanceLP();

        if (balance < amount) {
            IMasterChefPulseX(MasterChef).withdraw(poolID, amount - balance);
            balance = balanceLP();
        }

        if (balance > amount) {
            balance = amount;
        }

        IERC20(LPtoken).safeTransfer(Vault, balance);
        emit Withdraw(amount);
    }

    function harvest() external whenNotPaused nonReentrant {
        require(!Address.isContract(msg.sender), "MasterChefPulseXStrategy: Caller is not an EOA");
        IMasterChefPulseX(MasterChef).deposit(poolID, 0);
        uint256 harvestAmount = balanceRewardToken();
        _processFees(harvestAmount);
        _addLiquidity();
        deposit();
        emit HarvestRun(msg.sender, harvestAmount);
    }

    /**
     * @dev Harvest fee and Call fee processed together
     */
    function _processFees(uint256 harvestAmount) internal {
        uint256 harvestFeeBasisPoints = IStrategyVariables(StrategyVariables).harvestFeeBasisPoints();
        uint256 callFeeBasisPoints = IStrategyVariables(StrategyVariables).callFeeBasisPoints();
        uint256 totalFeeBasisPoints = harvestFeeBasisPoints + callFeeBasisPoints;

        uint256 harvestAmountFee = harvestAmount * totalFeeBasisPoints / BASIS_POINT_DIVISOR;

        IRouter(Router).swapExactTokensForTokens(harvestAmountFee, 0, RewardTokenToWPLSpath, address(this), block.timestamp + 120);

        uint256 balanceWPLS = IERC20(WPLS).balanceOf(address(this));

        uint256 WPLSforProcessor = balanceWPLS * harvestFeeBasisPoints / totalFeeBasisPoints;
        uint256 WPLSforCaller = balanceWPLS - (WPLSforProcessor);

        address HarvestProcessor = IProtocolAddresses(ProtocolAddresses).HarvestProcessor();
        IERC20(WPLS).safeTransfer(HarvestProcessor, WPLSforProcessor);
        emit HarvestFeeProcessed(WPLSforProcessor);

        IERC20(WPLS).safeTransfer(msg.sender, WPLSforCaller);
        emit CallFeeProcessed(WPLSforCaller);
    }

    function _addLiquidity() internal {
        uint256 halfRewardToken = balanceRewardToken() / (2);

        if (Token0 != RewardToken) {
            IRouter(Router).swapExactTokensForTokens(halfRewardToken, 0, RewardTokenToToken0path, address(this), block.timestamp + 120);
        }

        if (Token1 != RewardToken) {
            IRouter(Router).swapExactTokensForTokens(halfRewardToken, 0, RewardTokenToToken1path, address(this), block.timestamp + 120);
        }

        uint256 balanceToken0 = IERC20(Token0).balanceOf(address(this));
        uint256 balanceToken1 = IERC20(Token1).balanceOf(address(this));

        IRouter(Router).addLiquidity(Token0, Token1, balanceToken0, balanceToken1, 0, 0, address(this), block.timestamp + 120);
    }

    /**
     * @dev This will be called once when the Vault/Strategy is being decommissioned
     * Remaining rewards will be sent to the HarvestProcessor
     * All LP tokens will be sent back to the vault and can be withdrawn from there
     * Deposits will be paused
     *
     * WARNING: The strategy will not be able to restart
     */
    function decommissionStrategy() external onlyVault {
        IMasterChefPulseX(MasterChef).deposit(poolID, 0);
        uint256 receivedRewardToken = balanceRewardToken();
        if (receivedRewardToken > 0) {
            _processFees(receivedRewardToken);
        }

        IMasterChefPulseX(MasterChef).emergencyWithdraw(poolID);

        uint256 balance = balanceLP();
        IERC20(LPtoken).safeTransfer(Vault, balance);

        _pause();
    }
}
