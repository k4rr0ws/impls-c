/** @type import('hardhat/config').HardhatUserConfig */
require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  networks: {
    testnet: {
       chainId: 943,
       url: "https://rpc.v4.testnet.pulsechain.com",
       accounts: [''],
       gasPrice: 50000000000,
    },
    pulse: {
      chainId: 369,
      url: "https://rpc.pulsechain.com",
      accounts: [''],
   },
   hardhat: {
    accounts: {
      count: 10,
      initialIndex: 0,
      accountsBalance: "1000000000000000000000000000000000000000",
    },
    forking: {
      url: "https://rpc.pulsechain.com",
      enabled: true
    },
  }
  }
};
