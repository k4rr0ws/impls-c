// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IVaultRewards {
    function lastTimeRewardApplicable() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function getRewardForDuration() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function stakeFromVault(uint256 amount, address account) external;
    function withdrawToVault(uint256 amount, address account) external;
    function getReward() external;
}
