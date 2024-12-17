// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;


interface IProcessor {
    function process() external;
     function emission() external view returns (uint256);
}
