// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IIMPLS {
    function authorize(uint256 amount) external;
    function impls(uint256 amountIn) external;
    function setDistributor(address _Distributor) external;
    function setScalingFactor(uint256 _scalingFactor) external;
}