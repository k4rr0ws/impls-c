// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;


import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../libs/AMMLibrary.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IWPLS.sol";
import "../interfaces/IVaultRewards.sol";
import "../interfaces/IStrategy.sol";


pragma solidity ^0.8.19;

/**
 * @title Vault
 * @dev Access point for deposit/withdraw from strategies and rewards 
 */
contract VaultV1 is ERC20, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    address public constant WPLS = address(0xA1077a294dDE1B09bB078844df40758a5D0f9a27);

    address public Factory;
    address public Router;
    address public VaultRewards;
    address public Strategy;
    address public LPtoken;
    address public Token0;
    address public Token1;

    address[] public WPLStoToken0path;
    address[] public WPLStoToken1path;
    address[] public Token0toWPLSpath;
    address[] public Token1toWPLSpath;

    bool public strategySet;
    bool public rewardsSet;

    event PLSdeposited(uint256 amountPLS);
    event LPdeposited(uint256 amountLP);
    event SharesStaked(uint256 shares, address indexed account);
    event LPdepositedInStrategy(uint256 amountLP);
    event PLSwithdrawn(uint256 amountPLS);
    event LPwithdrawn(uint256 amountLP);
    event SharesWithdrawn(uint256 shares, address indexed account);
    event LPwithdrawnFromStrategy(uint256 amountLP);
    event VaultDecommissioned(uint256 decommissionTime);

    uint256 MAX_INT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    constructor(
        string memory _name, 
        string memory _symbol,
        address _LPtoken,
        address _Factory,
        address _Router
    ) ERC20(string(_name), string(_symbol)) {
        LPtoken = _LPtoken;
        Token0 = IPair(LPtoken).token0();
        Token1 = IPair(LPtoken).token1();
        Factory = _Factory;
        Router = _Router;

        WPLStoToken0path = [WPLS, Token0];
        WPLStoToken1path = [WPLS, Token1];
        Token0toWPLSpath = [Token0, WPLS];
        Token1toWPLSpath = [Token1, WPLS];

        IERC20(WPLS).safeApprove(Router, 0);
        IERC20(WPLS).safeApprove(Router, MAX_INT);
        IERC20(LPtoken).safeApprove(Router, 0);
        IERC20(LPtoken).safeApprove(Router, MAX_INT);
        IERC20(Token0).safeApprove(Router, 0);
        IERC20(Token0).safeApprove(Router, MAX_INT);
        IERC20(Token1).safeApprove(Router, 0);
        IERC20(Token1).safeApprove(Router, MAX_INT);
    }

    receive() external payable {}

    /**
     * @dev Strategies and reward contracts will be set once and not updated per vault
     */
    function setStrategy(address _Strategy) external onlyOwner {
        require(!strategySet, "VaultV1: Strategy address has already been set");
        Strategy = _Strategy;
        strategySet = true;
    }

    function setVaultRewards(address _VaultRewards) external onlyOwner {
        require(!rewardsSet, "VaultV1: Rewards address has already been set");
        VaultRewards = _VaultRewards;
        rewardsSet = true;
    }

    /**
     * @dev Balance helpers
     */
    function balanceLPinVault() public view returns (uint256) {
        return IERC20(LPtoken).balanceOf(address(this));
    }

    function balanceLPinStrategy() public view returns (uint256) {
        return IStrategy(Strategy).balanceLPinStrategy();
    }

    function balanceLPinSystem() public view returns (uint256) {
        return balanceLPinVault() + balanceLPinStrategy();
    }

    // Need to view shares owned through reward contract as an account will never actually hold vault shares
    function accountShareBalance(address account) public view returns (uint256) {
        return IVaultRewards(VaultRewards).balanceOf(account);
    }

    function getAccountLP(address account) public view returns (uint256) {
        return totalSupply() == 0 ? 0 : balanceLPinSystem() * accountShareBalance(account) / totalSupply();
    }

    function getPLSamountForAccountLP(address account) external view returns (uint256) {
        return getPLSamountForLPamount(getAccountLP(account));
    }

    function getLPamountForShares(uint256 shares) public view returns (uint256) {
        return totalSupply() == 0 ? 1e18 : balanceLPinSystem() * shares / totalSupply();
    }

    // Using {getAmountOut} to provide PLS value closer to what a withdraw would receive
    function getPLSamountForLPamount(uint256 amountLP) public view returns (uint256) {
        if (amountLP == 0) return 0;
        (uint256 reservesToken0, uint256 reservesToken1) = AMMLibrary.getReserves(Factory, Token0, Token1);

        uint256 totalSupplyLP = IERC20(LPtoken).totalSupply();

        uint256 amountToken0 = reservesToken0 * amountLP / totalSupplyLP;
        uint256 amountToken1 = reservesToken1 * amountLP / totalSupplyLP;

        if (Token0 == WPLS) {
            uint256 Token1toWPLS = AMMLibrary.getAmountOut(amountToken1, reservesToken1, reservesToken0);
            return amountToken0 + Token1toWPLS;
        } else if (Token1 == WPLS) {
            uint256 Token0toWPLS = AMMLibrary.getAmountOut(amountToken0, reservesToken0, reservesToken1);
            return amountToken1 + Token0toWPLS;
        } else {
            (uint256 reservesWPLS0, uint256 reserves0) = AMMLibrary.getReserves(Factory, WPLS, Token0);
            (uint256 reservesWPLS1, uint256 reserves1) = AMMLibrary.getReserves(Factory, WPLS, Token1);
            uint256 Token0toWPLS = AMMLibrary.getAmountOut(amountToken0, reserves0, reservesWPLS0);
            uint256 Token1toWPLS = AMMLibrary.getAmountOut(amountToken1, reserves1, reservesWPLS1);
            return Token0toWPLS + Token1toWPLS;
        }
    }

    // Using {quote} to provide more exact proportion of PLS held
    // Will be mostly called when calculating TVL for vault
    function getPLSquoteForLPamount(uint256 amountLP) public view returns (uint256) {
        if (amountLP == 0) return 0;
        (uint256 reservesToken0, uint256 reservesToken1) = AMMLibrary.getReserves(Factory, Token0, Token1);

        uint256 totalSupplyLP = IERC20(LPtoken).totalSupply();

        uint256 amountToken0 = reservesToken0 * amountLP / totalSupplyLP;
        uint256 amountToken1 = reservesToken1 * amountLP / totalSupplyLP;

        if (Token0 == WPLS) {
            uint256 Token1toWPLS = AMMLibrary.quote(amountToken1, reservesToken1, reservesToken0);
            return amountToken0 + Token1toWPLS;
        } else if (Token1 == WPLS) {
            uint256 Token0toWPLS = AMMLibrary.quote(amountToken0, reservesToken0, reservesToken1);
            return amountToken1 + Token0toWPLS;
        } else {
            (uint256 reservesWPLS0, uint256 reserves0) = AMMLibrary.getReserves(Factory, WPLS, Token0);
            (uint256 reservesWPLS1, uint256 reserves1) = AMMLibrary.getReserves(Factory, WPLS, Token1);
            uint256 Token0toWPLS = AMMLibrary.quote(amountToken0, reserves0, reservesWPLS0);
            uint256 Token1toWPLS = AMMLibrary.quote(amountToken1, reserves1, reservesWPLS1);
            return Token0toWPLS + Token1toWPLS;
        }
    }

    /**
     * @dev Deposit logic
     */
    function depositPLS() external payable nonReentrant whenNotPaused {
        uint256 amountPLS = msg.value;
        require(amountPLS > 0, "VaultV1: 0 PLS deposit");
        emit PLSdeposited(amountPLS);

        IWPLS(WPLS).deposit{value: amountPLS}();

        uint256 halfAmountWPLS = amountPLS / 2;

        if (Token0 == WPLS) {
            IRouter(Router).swapExactTokensForTokens(halfAmountWPLS, 0, WPLStoToken1path, address(this), block.timestamp + 120);    
        } else if (Token1 == WPLS) {
            IRouter(Router).swapExactTokensForTokens(halfAmountWPLS, 0, WPLStoToken0path, address(this), block.timestamp + 120);
        } else {
            IRouter(Router).swapExactTokensForTokens(halfAmountWPLS, 0, WPLStoToken0path, address(this), block.timestamp + 120);
            IRouter(Router).swapExactTokensForTokens(halfAmountWPLS, 0, WPLStoToken1path, address(this), block.timestamp + 120);
        }

        uint256 balanceToken0 = IERC20(Token0).balanceOf(address(this));
        uint256 balanceToken1 = IERC20(Token1).balanceOf(address(this));

        uint256 previousBalanceLPinSystem = balanceLPinSystem();

        (,, uint256 amountLP) = IRouter(Router).addLiquidity(Token0, Token1, balanceToken0, balanceToken1, 0, 0, address(this), block.timestamp + 120);

        _deposit(amountLP, previousBalanceLPinSystem);
    }

    function depositLP(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "VaultV1: 0 LP deposit");
        emit LPdeposited(amount);

        uint256 previousBalanceLPinSystem = balanceLPinSystem();

        IERC20(LPtoken).safeTransferFrom(msg.sender, address(this), amount);

        _deposit(amount, previousBalanceLPinSystem);
    }

    function _deposit(uint256 amount, uint256 systemBalance) internal {
        uint256 shares = 0;
        
        if (totalSupply() == 0) {
            shares = amount;
        } else {
            shares = (amount * totalSupply()) / systemBalance;
        }

        // mint shares to the vault, then deposit on behalf of msg.sender
        _mint(address(this), shares);
        _approve(address(this), VaultRewards, shares);
        IVaultRewards(VaultRewards).stakeFromVault(shares, msg.sender);
        emit SharesStaked(shares, msg.sender);

        IERC20(LPtoken).safeTransfer(Strategy, amount);
        IStrategy(Strategy).deposit();
        emit LPdepositedInStrategy(amount);
    }

    /**
     * @dev Withdraw logic
     */
    function withdrawPLS(uint256 sharesToWithdraw) external nonReentrant {
        uint256 sharesOwned = accountShareBalance(msg.sender);
        require(sharesToWithdraw <= sharesOwned, "VaultV1: Insufficient share balance for withdraw");

        uint256 amountLPforWithdraw = _withdraw(sharesToWithdraw);

        IRouter(Router).removeLiquidity(Token0, Token1, amountLPforWithdraw, 0, 0, address(this), block.timestamp + 120);

        uint256 balanceToken0 = IERC20(Token0).balanceOf(address(this));
        uint256 balanceToken1 = IERC20(Token1).balanceOf(address(this));

        if (Token0 == WPLS) {
            IRouter(Router).swapExactTokensForTokens(balanceToken1, 0, Token1toWPLSpath, address(this), block.timestamp + 120);
        } else if (Token1 == WPLS) {
            IRouter(Router).swapExactTokensForTokens(balanceToken0, 0, Token0toWPLSpath, address(this), block.timestamp + 120);
        } else {
            IRouter(Router).swapExactTokensForTokens(balanceToken0, 0, Token0toWPLSpath, address(this), block.timestamp + 120);
            IRouter(Router).swapExactTokensForTokens(balanceToken1, 0, Token1toWPLSpath, address(this), block.timestamp + 120);
        }

        uint256 balanceWPLS = IERC20(WPLS).balanceOf(address(this));

        IWPLS(WPLS).withdraw(balanceWPLS);

        (bool success, ) = msg.sender.call{value: balanceWPLS}("");
        require(success, "VaultV1: Unable to transfer PLS");

        emit PLSwithdrawn(balanceWPLS);
    }

    function withdrawLP(uint256 sharesToWithdraw) external nonReentrant {
        uint256 sharesOwned = accountShareBalance(msg.sender);
        require(sharesToWithdraw <= sharesOwned, "VaultV1: Insufficient share balance for withdraw");

        uint256 amountLPforWithdraw = _withdraw(sharesToWithdraw);

        IERC20(LPtoken).safeTransfer(msg.sender, amountLPforWithdraw);
        
        emit LPwithdrawn(amountLPforWithdraw);
    }

    function _withdraw(uint256 shares) internal returns (uint256 amountLPforWithdraw) {
        amountLPforWithdraw = getLPamountForShares(shares);

        IVaultRewards(VaultRewards).withdrawToVault(shares, msg.sender);
        _burn(address(this), shares);

        emit SharesWithdrawn(shares, msg.sender);

        uint256 balanceLPinVaultBefore = balanceLPinVault();
        if (balanceLPinVaultBefore < amountLPforWithdraw) {
            uint256 amountLPToWithdrawFromStrategy = amountLPforWithdraw - balanceLPinVaultBefore;

            IStrategy(Strategy).withdraw(amountLPToWithdrawFromStrategy);
            emit LPwithdrawnFromStrategy(amountLPToWithdrawFromStrategy);

            // This logic handles a withdraw fee applied in the strategy
            // Cycle strategies will not apply a withdraw fee but this will remain in case
            //
            uint256 balanceLPinVaultAfter = balanceLPinVault();
            uint256 difference = balanceLPinVaultAfter - balanceLPinVaultBefore;
            if (difference < amountLPToWithdrawFromStrategy) {
                amountLPforWithdraw = balanceLPinVaultBefore + difference;
            }
        }
    }

    /**
     * @dev To be called when the underlying strategy is no longer viable
     * The Vault/Strategy/Rewards will be moved into decommissioned mode
     * LP from the strategy will be transfered back to the vault and deposits will be disabled
     * Reward distribution will be ended for the reward contract
     * Participants will be able to withdraw their PLS/LP and claim remaining rewards
     *
     * WARNING: Decommissioning the strategy is irreversable
     */
    function decommissionVault() external onlyOwner {
        IStrategy(Strategy).decommissionStrategy();

        emit VaultDecommissioned(block.timestamp);

        _pause();
    }
}