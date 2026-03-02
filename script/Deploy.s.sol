// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {FaightersEscrow} from "../src/FaightersEscrow.sol";

contract Deploy is Script {
    uint256 internal constant BASE_MAINNET_CHAIN_ID = 8453;

    /// @notice Deploys FaightersEscrow with resolver and owner loaded from env.
    /// @dev Required env vars: PRIVATE_KEY, RESOLVER_ADDRESS, OWNER_ADDRESS.
    function run() external returns (FaightersEscrow escrow) {
        require(block.chainid == BASE_MAINNET_CHAIN_ID, "Deploy: wrong chain");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address resolver = vm.envAddress("RESOLVER_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        escrow = new FaightersEscrow(resolver, owner);
        vm.stopBroadcast();
    }
}
