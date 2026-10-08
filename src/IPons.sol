// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The slice of Pons V2 on Robinhood Chain this launch uses, from its verified sources (robin.etherscan.io:
///         factory 0x7ed598bcef8bd9edd8c97a195c6d13f40801ec7e).
///
///         A coin launched there trades on a bonding curve until it graduates to a Uniswap v4 pool. Every curve trade
///         books a 1% fee (30% Pons, 70% the creator) plus the creator's own tax (all the creator's, at most 10%),
///         paid to the creator fee recipient through Pons' fee escrow: the curve (after graduation, the meme hook)
///         books them with `sweepFees`, and the recipient claims its ETH from the escrow. The coin's name, symbol,
///         logo, description and socials are written once, when it launches, and nothing can change them after.

struct PonsSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

/// @dev PonsV2LaunchFactory.TokenParams, field for field
struct PonsTokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    /// @dev Store the reviewed previewLaunchEconomics(configId, pairToken) digest before launching.
    ///      This adapter requires a nonzero pin; Pons reverts if its terms no longer match.
    bytes32 expectedEconomics;
    /// @dev CREATE2 salt for the curve and the coin: mined for a vanity coin address
    bytes32 salt;
}

interface IPonsFactory {
    function launchFee() external view returns (uint256);
    function launchToken(PonsTokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    /// @notice Only the current creator fee recipient may hand its fees to a new address
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function feeEscrow() external view returns (address);
    function memeHook() external view returns (address);
}

interface IPonsFeeEscrow {
    function claim() external returns (uint256 amount);
    function balanceOf(address recipient) external view returns (uint256);
}

interface IPonsMemeHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
    /// @notice Books the creator's pending fees into the fee escrow (the creator fee recipient may call it)
    function sweepFees(uint256 minBuybackTokensOut) external;
    function graduated() external view returns (bool);
}
