// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IDistributor {
    function distribute(address caller) external;
}