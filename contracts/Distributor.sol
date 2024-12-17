// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./libs/AMMLibrary.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IProtocolAddresses.sol";
import "./interfaces/IProcessor.sol";
import "./interfaces/IWPLS.sol";
import "./interfaces/IStakingRewards.sol";
import "./interfaces/IIMPLSVault.sol";

/**
 * @title Distributor
 * @dev IMPLS vault reward distribution logic
 */
contract Distributor is Ownable {
    using SafeERC20 for IERC20;

    address public ProtocolAddresses;
    address public Proxy;
    address public CoreRewards;

    uint256 public distributionCost;
    uint256 public coreRewardsBasisPoints;

    address public constant IMPLS = address(0x5f63BC3d5bd234946f18d24e98C324f629D9d60e);
    address public constant WPLS = address(0xA1077a294dDE1B09bB078844df40758a5D0f9a27);
    address public constant Factory = address(0x1715a3E4A142d8b698131108995174F37aEBA10D);
    address public constant Router = address(0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02);

    address[] public swapPath = [IMPLS, WPLS];

    uint256 public constant BP_DIVISOR = 10000;

    struct RewardData {
        address StakingRewards;
        uint256 weight;
    }

    struct NormalizedRewardData {
        address StakingRewards;
        uint256 normalizedTVL;
    }

    RewardData[] public rewards;

    event RewardContractAdded(address StakingRewards);
    event RewardContractDeleted(address StakingRewards);
    event RewardWeightUpdated(address StakingRewards, uint256 weight);
    event IMPLSDistributedTotal(uint256 amount);
    event IMPLSDistributed(address StakingRewards, uint256 amount);
    event DistributionCostUpdated(uint256 distributionCost);
    event ProtocolAddressesUpdated(address ProtocolAddresses);
    event ProxyUpdated(address Proxy);
    event CoreRewardsUpdated(address CoreRewards);
    event CoreRewardsBasisPointsUpdated(uint256 coreRewardsBasisPoints);

    constructor(uint256 _distributionCost, uint256 _coreRewardsBasisPoints) {
        distributionCost = _distributionCost;
        coreRewardsBasisPoints = _coreRewardsBasisPoints;
        emit DistributionCostUpdated(distributionCost);
        emit CoreRewardsBasisPointsUpdated(coreRewardsBasisPoints);
    }

    receive() external payable {}

    modifier onlyProxy() {
        require(msg.sender == Proxy, "Distributor: Caller must be the Proxy");
        _;
    }

    /**
     * @dev External address management
     */
    function setProtocolAddresses(address _ProtocolAddresses) external onlyOwner {
        ProtocolAddresses = _ProtocolAddresses;
        emit ProtocolAddressesUpdated(ProtocolAddresses);
    }

    function setProxy(address _Proxy) external onlyOwner {
        Proxy = _Proxy;
        emit ProxyUpdated(Proxy);
    }

    function setCoreRewards(address _CoreRewards) external onlyOwner {
        CoreRewards = _CoreRewards;
        emit CoreRewardsUpdated(CoreRewards);
    }

    /**
     * @dev Vault reward data management
     *
     * Do not add CoreRewards to the vault rewards array
     */
    function addRewardData(address StakingRewards) external onlyOwner {
        // Initialize weight at 10 to allow unidirectional adjustment
        for (uint i; i < rewards.length; i++) {
            require(rewards[i].StakingRewards != StakingRewards, "Distributor: Reward contract has already been added");
        }
        rewards.push(RewardData(StakingRewards, 10));
        emit RewardContractAdded(StakingRewards);
    }

    function deleteRewardData(uint256 index) external onlyOwner {
        require(index < rewards.length, "Distributor: Index out of bounds");
        address StakingRewards = rewards[index].StakingRewards;
        for (uint i = index; i < rewards.length - 1; i++) {
            rewards[i] = rewards[i + 1];
        }
        rewards.pop();
        emit RewardContractDeleted(StakingRewards);
    }

    function updateRewardWeight(address StakingRewards, uint256 weight) external onlyOwner {
        for (uint i; i < rewards.length; i++) {
            if (rewards[i].StakingRewards == StakingRewards) {
                rewards[i].weight = weight;
                emit RewardWeightUpdated(StakingRewards, weight);
                break;
            }
        }
    }

    /**
     * @dev Core reward data management
     */
    function setCoreRewardsBasisPoints(uint256 _coreRewardsBasisPoints) external onlyOwner {
        require(_coreRewardsBasisPoints < BP_DIVISOR, "Distributor: Basis Points out of bounds");
        coreRewardsBasisPoints = _coreRewardsBasisPoints;
        emit CoreRewardsBasisPointsUpdated(coreRewardsBasisPoints);
    }

    /**
     * @dev Set the approximate current cost of the distribute function in wei
     * @dev Will need to be updated whenever reward array is updated
     */
    function setDistributionCost(uint256 _distributionCost) external onlyOwner {
        distributionCost = _distributionCost;
        emit DistributionCostUpdated(distributionCost);
    }

    /**
     * @dev Reward data getters
     */
    function getRewardWeight(address StakingRewards) external view returns (uint256) {
        for (uint i; i < rewards.length; i++) {
            if (rewards[i].StakingRewards == StakingRewards) {
                return rewards[i].weight;
            }
        }
        revert("StakingReward contract does not exist in rewards collection");
    }

    function getRewardIndex(address StakingRewards) external view returns (uint256) {
        for (uint i; i < rewards.length; i++) {
            if (rewards[i].StakingRewards == StakingRewards) {
                return i;
            }
        }
        revert("StakingReward contract does not exist in rewards collection");
    }

    function getTotalWeight() public view returns (uint256 totalWeight) {
        for (uint i; i < rewards.length; i++) {
            totalWeight = totalWeight + rewards[i].weight;
        }
    }

    function getVaultRewardsCount() external view returns (uint256) {
        return rewards.length;
    }

    function implsBalance() public view returns (uint256) {
        return IERC20(IMPLS).balanceOf(address(this));
    }

    /**
     * @dev TVL helpers
     */
    function getCoreRewardsTVL() public view returns (uint256) {
        address coreLP = IStakingRewards(CoreRewards).stakingToken();
        uint256 totalSupplyCoreLP = IERC20(coreLP).totalSupply();
        uint256 amountCoreLPstaked = IStakingRewards(CoreRewards).totalSupply();
        (uint256 reservesWPLS,) = AMMLibrary.getReserves(Factory, WPLS, IMPLS);
        uint256 amountPLS = (reservesWPLS * amountCoreLPstaked) / totalSupplyCoreLP;
        // WPLS + IMPLS 
        return amountPLS * 2;
    }

    function getVaultTVL(address StakingRewards) public view returns (uint256) {
        address Vault = IStakingRewards(StakingRewards).stakingToken();
        uint256 totalLPinVault = IIMPLSVault(Vault).balanceLPinSystem();
        return IIMPLSVault(Vault).getPLSquoteForLPamount(totalLPinVault);
    }

    /**
     * @dev Call fee kickback logic, sending {distributionCost} in WPLS to caller
     */
    function _processKickback(address caller) internal {
        (uint256 reservesWPLS, uint256 reservesIMPLS) = AMMLibrary.getReserves(Factory, WPLS, IMPLS);
        uint256 amountIMPLStoSwap = AMMLibrary.getAmountIn(distributionCost, reservesIMPLS, reservesWPLS);

        IERC20(IMPLS).safeIncreaseAllowance(Router, amountIMPLStoSwap);
        IUniswapV2Router(Router).swapExactTokensForTokens(amountIMPLStoSwap, 0, swapPath, address(this), block.timestamp + 120);

        uint256 balanceWPLS = IERC20(WPLS).balanceOf(address(this));
        IWPLS(WPLS).withdraw(balanceWPLS);

        (bool success, ) = caller.call{value: balanceWPLS}("");
        require(success, "Distributor: Unable to transfer WPLS");
    }

    /**
     * @dev Distribution function
     *
     * Normalizes output based on correlated WPLS TVL of Vaults, applying custom weighting
     * Core Rewards takes a fixed percent of the distribution
     *
     */
    function distribute(address caller) external onlyProxy {
        uint256 amountToDistribute = implsBalance();
        require(amountToDistribute > 0, "Distributor: No IMPLS to distribute");

        // Send emission amount back to processor
        address Processor = IProtocolAddresses(ProtocolAddresses).HarvestProcessor();
        uint256 emissionAmount = IProcessor(Processor).emission();
        uint256 processorBalance = IERC20(IMPLS).balanceOf(Processor);
        if (processorBalance < emissionAmount) {
            IERC20(IMPLS).safeTransfer(Processor, emissionAmount - processorBalance);
        }

        _processKickback(caller);

        // IMPLS is used for the caller kickback, read balance again
        amountToDistribute = implsBalance();
        emit IMPLSDistributedTotal(amountToDistribute);

        // Core Rewards distribution
        uint256 amountForCoreRewards = amountToDistribute * coreRewardsBasisPoints / BP_DIVISOR;
        IERC20(IMPLS).safeTransfer(CoreRewards, amountForCoreRewards);
        IStakingRewards(CoreRewards).notifyRewardAmount(amountForCoreRewards);
        emit IMPLSDistributed(CoreRewards, amountForCoreRewards);

        amountToDistribute = implsBalance();

        uint256 totalNormalizedTVL;
        NormalizedRewardData[] memory normalizedRewards = new NormalizedRewardData[](rewards.length);

        // Loop through the vaults, storing the weight normalized TVL
        for (uint i; i < rewards.length; i++) {
            uint256 vaultTVL = getVaultTVL(rewards[i].StakingRewards);
            uint256 vaultTVLnormalized = vaultTVL * rewards[i].weight;
            totalNormalizedTVL = totalNormalizedTVL + vaultTVLnormalized;
            normalizedRewards[i].normalizedTVL = vaultTVLnormalized;
            normalizedRewards[i].StakingRewards = rewards[i].StakingRewards;
        }

        for (uint i; i < normalizedRewards.length; i++) {
            address destination = normalizedRewards[i].StakingRewards;
            uint256 amountToSend;
            if (i == normalizedRewards.length - 1) {
                amountToSend = implsBalance(); // send remainder to last vault reward contract
            } else {
                amountToSend = (amountToDistribute * normalizedRewards[i].normalizedTVL) / totalNormalizedTVL;
            }
            IERC20(IMPLS).safeTransfer(destination, amountToSend);
            IStakingRewards(destination).notifyRewardAmount(amountToSend);
            emit IMPLSDistributed(destination, amountToSend);
        }
        
    }
}
