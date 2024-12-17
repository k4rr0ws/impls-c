// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IIMPLSVault {
    function balanceLPinSystem() external view returns (uint256);
    function getPLSquoteForLPamount(uint256 amountLP) external view returns (uint256);
}
