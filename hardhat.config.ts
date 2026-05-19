import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import HardhatContractSizer from "@solidstate/hardhat-contract-sizer";
import { configVariable, defineConfig } from "hardhat/config";
import "dotenv/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, HardhatContractSizer],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    forkMainnet: {
      type: "edr-simulated",
      chainType: "l1",
      forking: {
        url: configVariable("MAINNET_RPC_URL"),
      },
    },
    forkBase: {
      type: "edr-simulated",
      chainType: "op",
      forking: {
        url: configVariable("BASE_RPC_URL"),
      },
    },
    forkSepolia: {
      type: "edr-simulated",
      chainType: "l1",
      forking: {
        url: configVariable("SEPOLIA_RPC_URL"),
      },
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
    mainnet: {
      type: "http",
      chainType: "l1",
      url: configVariable("MAINNET_RPC_URL"),
      accounts: [configVariable("MAINNET_PRIVATE_KEY")],
    },
    base: {
      type: "http",
      chainType: "op",
      url: configVariable("BASE_RPC_URL"),
      accounts: [configVariable("BASE_PRIVATE_KEY")],
    },
  },
  contractSizer: {
    runOnCompile: true,
    except: [/Test$/],
  },
});
