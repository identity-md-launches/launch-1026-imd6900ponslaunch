// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsPredict} from "./PonsPredict.sol";

/// @notice Mines the salt that puts the coin at a vanity address, for the launch contract the swarm deployed, with the
///         details it holds now (run it again after any setMeta). A test rather than a script so the loop runs inside
///         the EVM against a Robinhood fork, with no RPC round trip per try (~5k tries a second; 0x6900 takes ~65k on
///         average). Feed the salt and the address it prints to {launch}.
///
///     LAUNCH=0x… PREFIX=6900 TRIES=300000 forge test --match-test test_mine -vv   (ROBINHOOD_RPC_URL set)
contract MineVanityTest is Test {
    function test_mine() public {
        address launch = vm.envOr("LAUNCH", address(0));
        if (launch == address(0)) vm.skip(true);
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        bytes memory prefix = bytes(vm.envOr("PREFIX", string("6900")));
        uint256 start = vm.envOr("START", uint256(0));
        uint256 tries = vm.envOr("TRIES", uint256(300_000));
        console2.log("mining a coin address starting 0x%s for the launch contract %s", string(prefix), launch);
        (bool found, bytes32 salt, address token, address curve) = PonsPredict.mine(IMD6900PonsLaunch(payable(launch)), prefix, start, tries);
        if (!found) {
            console2.log("no hit in %s tries: rerun with START=%s", tries, start + tries);
            return;
        }
        console2.log("coin ", token);
        console2.log("curve", curve);
        console2.log("salt");
        console2.logBytes32(salt);
    }
}
