// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IProcessor.sol";
import "./interfaces/IDistributor.sol";
import "./interfaces/IProtocolAddresses.sol";

contract DistributionProxy is Ownable, ReentrancyGuard, Pausable {
    address public ProtocolAddresses;
    uint256 public lastDistribution;

    uint256 public constant frequency = 1 days;

    constructor(uint256 _lastDistribution) {
        lastDistribution = _lastDistribution;
    }

    function togglePause() external onlyOwner {
        paused() ? _unpause() : _pause();
    }

    function setProtocolAddresses(address _ProtocolAddresses) external onlyOwner {
        ProtocolAddresses = _ProtocolAddresses;
    }

    function distributeRewards() external nonReentrant whenNotPaused {
        require(!Address.isContract(msg.sender), "DistributionProxy: Caller is not an EOA");

        require(block.timestamp > (lastDistribution + frequency), "DistributionProxy: Distribution timer has not elapsed");

        // In case over a day lapses between distributions, bring lastDistribution up to most current time
        while (block.timestamp > (lastDistribution + frequency)) {
            lastDistribution = lastDistribution + frequency;
        }

        IProcessor(IProtocolAddresses(ProtocolAddresses).HarvestProcessor()).process();
        IDistributor(IProtocolAddresses(ProtocolAddresses).Distributor()).distribute(msg.sender);
    }
}
