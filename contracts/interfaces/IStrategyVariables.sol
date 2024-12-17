// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IStrategyVariables {
    function harvestFeeBasisPoints() external returns (uint256);
    function callFeeBasisPoints() external view returns (uint256);
}
