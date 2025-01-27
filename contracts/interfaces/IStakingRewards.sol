// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;


interface IStakingRewards {
    // Views
    function lastTimeRewardApplicable() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function getRewardForDuration() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stakingToken() external view returns (address);
    
    // Mutative
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function exit() external;
    function notifyRewardAmount(uint256 reward) external;
}