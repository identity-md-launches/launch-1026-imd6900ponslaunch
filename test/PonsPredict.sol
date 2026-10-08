// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsTokenParams} from "../src/IPons.sol";

struct FeePolicySnapshot {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps;
    uint16 buybackBurnBps;
    uint16 hookFeeBps;
    uint16 maxInternalPriceImpactBps;
}

struct Socials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

/// @dev PonsV2LaunchDeployer.LaunchDeployment, field for field
struct LaunchDeployment {
    address pairToken;
    address creatorFeeRecipient;
    address originalDeployer;
    address feePolicy;
    FeePolicySnapshot policy;
    address feeEscrow;
    address buybackVault;
    uint256 phantomQuote;
    uint256 curveFeeBps;
    uint256 creatorTaxBps;
    bool buybackEnabled;
    uint256 graduationThreshold;
    uint256 supply;
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    Socials socials;
}

struct LaunchConfig {
    uint256 supply;
    uint256 curveFeeBps;
    uint256 phantomQuote;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    bool enabled;
}

interface IDeployerView {
    function predictLaunchAddresses(LaunchDeployment calldata params) external view returns (address token, address curve);
}

interface IFactoryView {
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);
    function launchDeployer() external view returns (address);
    function memeHook() external view returns (address);
    function feeEscrow() external view returns (address);
    function buybackVault() external view returns (address);
}

interface IHookView {
    function currentFeePolicy() external view returns (FeePolicySnapshot memory);
}

/// @notice Where Pons will put the coin a launch contract launches with a given salt. Pons derives the coin and its
///         curve with CREATE2 from its launch deployer, salted with keccak(originalDeployer, salt), over init code
///         that carries every detail of the launch; `predictLaunchAddresses` is Pons' own answer, so this asks it.
///         The original deployer is the launch contract (it calls launchToken), so its address must exist first:
///         mine after the swarm has deployed it, and again after any {setMeta}.
library PonsPredict {
    IFactoryView internal constant FACTORY = IFactoryView(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);

    /// @dev Everything but the salt, as {IMD6900PonsLaunch.launch} would launch now
    function deployment(IMD6900PonsLaunch l) internal view returns (IDeployerView deployer, LaunchDeployment memory p) {
        deployer = IDeployerView(FACTORY.launchDeployer());
        LaunchConfig memory cfg = FACTORY.getLaunchConfig(l.launchConfigId());
        PonsTokenParams memory m = l.meta();
        p = LaunchDeployment({
            pairToken: address(0),
            creatorFeeRecipient: m.creatorFeeRecipient,
            originalDeployer: address(l),
            feePolicy: FACTORY.memeHook(),
            policy: IHookView(FACTORY.memeHook()).currentFeePolicy(),
            feeEscrow: FACTORY.feeEscrow(),
            buybackVault: FACTORY.buybackVault(),
            phantomQuote: cfg.phantomQuote,
            curveFeeBps: cfg.curveFeeBps,
            creatorTaxBps: m.creatorTaxBps,
            buybackEnabled: false,
            graduationThreshold: cfg.graduationThreshold,
            supply: cfg.supply,
            salt: bytes32(0),
            name: m.name,
            symbol: m.symbol,
            logo: m.logo,
            description: m.description,
            socials: Socials(m.socials.twitter, m.socials.telegram, m.socials.discord, m.socials.website, m.socials.farcaster)
        });
    }

    /// @notice The first salt from `start` within `tries` whose coin address starts with `prefix` (hex digits, e.g.
    ///         "6900"); `found` false if none
    function mine(IMD6900PonsLaunch l, bytes memory prefix, uint256 start, uint256 tries)
        internal
        view
        returns (bool found, bytes32 salt, address token, address curve)
    {
        (IDeployerView deployer, LaunchDeployment memory p) = deployment(l);
        uint256 bits = prefix.length * 4;
        uint256 want;
        for (uint256 i; i < prefix.length; ++i) want = (want << 4) | _nibble(prefix[i]);
        for (uint256 i = start; i < start + tries; ++i) {
            p.salt = bytes32(i);
            (token, curve) = deployer.predictLaunchAddresses(p);
            if (uint160(token) >> (160 - bits) == want) return (true, bytes32(i), token, curve);
        }
    }

    function _nibble(bytes1 c) private pure returns (uint256) {
        uint8 b = uint8(c);
        if (b >= 0x30 && b <= 0x39) return b - 0x30;
        if (b >= 0x61 && b <= 0x66) return b - 0x57;
        if (b >= 0x41 && b <= 0x46) return b - 0x37;
        revert("prefix: hex digits only");
    }
}
