// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {RateLimiter} from "../src/RateLimiter.sol";

/// @title DeployRateLimiter
/// @notice Reviewable deployment script for the demo `RateLimiter` on Sepolia (chain id 11155111).
///
/// `run()` reads the configuration from the environment and hands it to `deploy`, which the tests
/// call directly with `demoConfig()`. Tests never touch the environment.
///
/// Environment variables (all optional, defaults are the documented demo parameters):
///   RATE_LIMITER_CAPACITY         whole credits per bucket           default 10
///   RATE_LIMITER_REFILL_INTERVAL  seconds per credit                 default 60
contract DeployRateLimiter is Script {
    struct Config {
        uint256 capacity;
        uint256 refillInterval;
    }

    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;

    /// @notice The documented demo parameters: 10 credits, one credit every 60 seconds.
    function demoConfig() public pure returns (Config memory) {
        return Config({capacity: 10, refillInterval: 60});
    }

    /// @notice Configuration from the environment, falling back to `demoConfig()`.
    function configFromEnv() public view returns (Config memory config) {
        Config memory demo = demoConfig();
        config.capacity = vm.envOr("RATE_LIMITER_CAPACITY", demo.capacity);
        config.refillInterval = vm.envOr("RATE_LIMITER_REFILL_INTERVAL", demo.refillInterval);
    }

    /// @notice Deploy with `config`. Pure deployment logic, no environment access, no broadcast.
    function deploy(Config memory config) public returns (RateLimiter limiter) {
        limiter = new RateLimiter(config.capacity, config.refillInterval);
    }

    /// @notice Entry point for `forge script`. Refuses to run against Ethereum mainnet.
    function run() external returns (RateLimiter limiter) {
        require(block.chainid != 1, "DeployRateLimiter: mainnet deployment is not authorised");
        Config memory config = configFromEnv();
        vm.startBroadcast();
        limiter = deploy(config);
        vm.stopBroadcast();
    }
}
