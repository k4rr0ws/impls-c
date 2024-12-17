// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IWPLS.sol";
import "./interfaces/IStakingRewards.sol";
import "./interfaces/IIMPLS.sol";

/**
 * @title Processor
 * @dev Transfer to PLS rewards, team and control daily emission
 */
contract Processor is Ownable {
    using SafeERC20 for IERC20;

    address public constant IMPLS = address(0x5f63BC3d5bd234946f18d24e98C324f629D9d60e);
    address public constant WPLS = address(0xA1077a294dDE1B09bB078844df40758a5D0f9a27);
    uint256 public constant BP_DIV = 10000;

    address public PLSRewards;
    address public Proxy;
    address public Team;
    uint256 public teamBP;
    uint256 public emission;

    event RewardsProcessed(uint256 amountIMPLS);
    event PLSRewardsUpdated(address PLSRewards);
    event ProxyUpdated(address Proxy);
    event TeamUpdated(address Team);
    event TeamBPUpdated(uint256 teamBP);
    event EmissionUpdated(uint256 newEmission);

    constructor(
        address _PLSRewards,
        address _Proxy,
        address _Team,
        uint256 _teamBP,
        uint256 _emission
    ) {
        PLSRewards = _PLSRewards;
        Proxy = _Proxy;
        Team = _Team;
        teamBP = _teamBP;
        emission = _emission;
    }

    receive() external payable {}

    modifier onlyProxy() {
        require(msg.sender == Proxy, "Processor: Caller must be the Proxy");
        _;
    }

    /**
     * @dev Owner Controls
     */
    function setEmission(uint256 newEmission) external onlyOwner {
        emission = newEmission;
        emit EmissionUpdated(newEmission);
    }

    function setPLSRewards(address _PLSRewards) external onlyOwner {
        PLSRewards = _PLSRewards;
        emit PLSRewardsUpdated(PLSRewards);
    }

    function setProxy(address _Proxy) external onlyOwner {
        Proxy = _Proxy;
        emit ProxyUpdated(Proxy);
    }

    function setTeam(address _Team) external onlyOwner {
        Team = _Team;
        emit TeamUpdated(Team);
    }

    function setTeamBP(uint256 _teamBP) external onlyOwner {
        teamBP = _teamBP;
        emit TeamBPUpdated(teamBP);
    }

    // In case rewards need to be cleared for update
    function clearRewards() external onlyOwner {
        IERC20(IMPLS).safeTransfer(msg.sender, balanceIMPLS());
    }

    function balanceWPLS() public view returns (uint256) {
        return IERC20(WPLS).balanceOf(address(this));
    }

    function balanceIMPLS() public view returns (uint256) {
        return IERC20(IMPLS).balanceOf(address(this));
    }

    function process() external onlyProxy {
        uint256 balancePLS = address(this).balance;
        if (balancePLS > 0) {
            IWPLS(WPLS).deposit{value: balancePLS}();
        }

        uint256 balWPLS = balanceWPLS();
        uint256 teamFee = (balWPLS * teamBP) / BP_DIV;
        IERC20(WPLS).safeTransfer(Team, teamFee);
        uint256 rewardAmount = balanceWPLS();
        IERC20(WPLS).safeTransfer(PLSRewards, rewardAmount);
        IStakingRewards(PLSRewards).notifyRewardAmount(rewardAmount);

        uint256 balIMPLS = balanceIMPLS();
        uint256 amountToSend = balIMPLS < emission ? balIMPLS : emission;
        IIMPLS(IMPLS).authorize(amountToSend);
        IIMPLS(IMPLS).impls(amountToSend);

        emit RewardsProcessed(amountToSend);
    }
}
