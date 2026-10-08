// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsTokenParams} from "../src/IPons.sol";
import {PonsPredict} from "./PonsPredict.sol";

interface IERC20Meta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDistributors {
    function setDistributor(address distributor, bool status) external;
}

interface ICurveBuy {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

interface IHookPolicyAdmin {
    function owner() external view returns (address);
    function protocolFeeShareBps() external view returns (uint256);
    function setProtocolFeeShareBps(uint256 bps) external;
}

/// @notice On a Robinhood Chain fork, against Pons itself: the launch contract as the swarm deploys it, the team's ETH
///         sent in, the vanity salt mined for it, the launch at the mined address with the opening buy, the 1:1
///         claim once the Robinhood timelock makes it a distributor, the release of what no holder can claim, and the
///         way back out if the team decides against launching. Needs ROBINHOOD_RPC_URL (the public RPC is behind
///         Cloudflare and refuses a fork's bulk reads); skips without it.
contract PonsLaunchForkTest is Test {
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant IMDSTR = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F; // Robinhood's IMDSTR
    address constant TIMELOCK = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14; // Robinhood timelock, IMDSTR's owner
    address constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059; // the team wallet (the deployer)

    IMD6900PonsLaunch l;

    function setUp() public {
        string memory rpc_ = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        l = new IMD6900PonsLaunch(TEAM, FACTORY, IMDSTR, TIMELOCK);
        PonsTokenParams memory m = l.meta();
        m.expectedEconomics = l.factory().previewLaunchEconomics(l.launchConfigId(), address(0));
        vm.prank(TEAM);
        l.setMeta(m);
        vm.deal(TEAM, 5 ether);
    }

    function _fund(uint256 eth) internal {
        vm.prank(TEAM);
        (bool ok,) = address(l).call{value: eth}("");
        assertTrue(ok, "the team's ETH, a plain transfer");
    }

    /// @dev A two-digit prefix keeps the test quick; the real launch mines 0x6900 the same way (MineVanity.t.sol)
    function _launch(uint256 eth) internal returns (address token, uint256 bought) {
        _fund(eth);
        (bool found, bytes32 salt, address predicted,) = PonsPredict.mine(l, bytes("69"), 0, 5_000);
        assertTrue(found, "mined");
        vm.prank(TEAM);
        (token, bought) = l.launch(salt, predicted, 0, 0);
        assertEq(token, predicted, "where it was mined for");
    }

    function test_fork_LaunchesAtTheMinedAddress_andBuysFirst() public {
        (address token, uint256 bought) = _launch(2 ether);
        assertEq(uint160(token) >> 152, 0x69, "the vanity prefix");
        assertEq(l.pons(), token);
        assertEq(IERC20Meta(token).name(), "Identity.MD 6900");
        assertEq(IERC20Meta(token).symbol(), "IMD6900");
        assertEq(IERC20Meta(token).balanceOf(address(l)), bought, "the opening buy, held for claims");
        assertEq(address(l).balance, 0, "every wei bought the coin (bar Pons' launch fee)");
        emit log_named_decimal_uint("coin bought with 2 ETH (millions)", bought / 1e6, 18);
        emit log_named_decimal_uint("share of the supply", bought * 1e18 / IERC20Meta(token).totalSupply(), 16);
        assertGt(bought, 0);
    }

    function test_fork_TheOpeningBuyBeatsTheNextBuyer() public {
        (address token, uint256 bought) = _launch(1 ether);
        address next = makeAddr("the next buyer");
        vm.deal(next, 1 ether);
        vm.warp(block.timestamp + 60); // past any snipe window
        vm.prank(next);
        uint256 theirs = ICurveBuy(l.curve()).buy{value: 1 ether}(1 ether, 0, next);
        assertGt(bought, theirs, "the same ETH bought more, first");
        assertEq(IERC20Meta(token).balanceOf(next), theirs);
    }

    function test_fork_ClaimOneToOne_onceADistributor() public {
        (address token,) = _launch(2 ether);
        vm.startPrank(TEAM);
        IERC20Meta(IMDSTR).approve(address(l), 1_000_000e18);
        vm.expectRevert(); // IMDSTR moves only to and from distributors
        l.claim(1_000_000e18);
        vm.stopPrank();

        vm.prank(TIMELOCK); // the Robinhood timelock's op (12h)
        IDistributors(IMDSTR).setDistributor(address(l), true);
        uint256 before = IERC20Meta(IMDSTR).balanceOf(TEAM);
        vm.prank(TEAM);
        l.claim(1_000_000e18);
        assertEq(IERC20Meta(token).balanceOf(TEAM), 1_000_000e18, "1:1");
        assertEq(before - IERC20Meta(IMDSTR).balanceOf(TEAM), 1_000_000e18);
        assertEq(IERC20Meta(IMDSTR).balanceOf(address(l)), 1_000_000e18, "kept here");
    }

    function test_fork_NoReleaseWithoutGlobalSupplyCeiling() public {
        (address token, uint256 bought) = _launch(2 ether);
        uint256 supply = IERC20Meta(IMDSTR).totalSupply();
        emit log_named_decimal_uint("IMDSTR on Robinhood (millions)", supply / 1e6, 18);
        // Robinhood supply alone is not a safe reserve for this OFT. No guessed Ethereum ceiling in this test.
        assertEq(l.releasable(), 0);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.release(0, TEAM);
        assertEq(IERC20Meta(token).balanceOf(address(l)), bought, "all inventory retained");
    }

    /// @dev The coin's creator fees, Pons' own escrow and all: a trade, then anyone harvests, 70% to the pot bridge
    ///      (Ethereum's NFT pot), 30% ops; the Robinhood timelock is the only other way ETH leaves
    function test_fork_HarvestSendsTheFeesToThePot() public {
        _launch(2 ether);
        address buyer = makeAddr("a buyer");
        vm.deal(buyer, 1 ether);
        vm.warp(block.timestamp + 60);
        vm.prank(buyer);
        ICurveBuy(l.curve()).buy{value: 1 ether}(1 ether, 0, buyer);

        address pot = l.POT_BRIDGE();
        (uint256 potBefore, uint256 teamBefore) = (pot.balance, TEAM.balance);
        uint256 split = l.harvest(bytes32(0));
        emit log_named_decimal_uint("fees harvested after 3 ETH of buys", split, 18);
        assertGt(split, 0.1 ether, "the creator's 70% of 1% plus the 5.9% tax, on 3 ETH");
        assertEq(pot.balance - potBefore, split * 7_000 / 10_000, "70% to the NFT pot's bridge");
        assertEq(TEAM.balance - teamBefore, split * 3_000 / 10_000, "30% ops");
        assertEq(address(l).balance, 0);

        // after the launch the team can't take ETH out; the timelock can
        vm.deal(address(l), 0.01 ether);
        vm.prank(TEAM);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.withdrawEth(TEAM, 0);
        vm.prank(TIMELOCK);
        l.recoverEth(TEAM, 0);
        assertEq(address(l).balance, 0);
    }

    function test_fork_TheEthComesBackIfWeDontLaunch() public {
        _fund(2 ether);
        uint256 before = TEAM.balance;
        vm.prank(TEAM);
        l.withdrawEth(TEAM, 0);
        assertEq(TEAM.balance - before, 2 ether);
        assertEq(address(l).balance, 0);
        assertEq(l.pons(), address(0), "nothing launched");
    }

    function test_fork_ANewBrandMinesAnotherAddress() public {
        (, bytes32 oldSalt, address before,) = PonsPredict.mine(l, bytes("69"), 0, 5_000);
        PonsTokenParams memory m = l.meta();
        m.logo = "https://imd6900.pages.dev/icon-512.png";
        vm.prank(TEAM);
        l.setMeta(m);
        (bool found,, address after_,) = PonsPredict.mine(l, bytes("69"), 0, 5_000);
        assertTrue(found);
        assertTrue(after_ != before, "the details are part of the address");
        // and the old salt no longer lands at the old address: launch refuses it
        _fund(1 ether);
        vm.prank(TEAM);
        vm.expectRevert(); // NotWhereMined: the old salt lands the new details somewhere else
        l.launch(oldSalt, before, 0, 0);
    }

    function test_fork_ChangedFeePolicyRejectsPreviouslyPinnedEconomics() public {
        _fund(1 ether);
        (bool found, bytes32 salt, address predicted,) = PonsPredict.mine(l, bytes("69"), 0, 5_000);
        assertTrue(found);
        bytes32 pinned = l.meta().expectedEconomics;
        IHookPolicyAdmin hook = IHookPolicyAdmin(l.factory().memeHook());
        uint256 oldShare = hook.protocolFeeShareBps();
        address admin = hook.owner();
        vm.prank(admin);
        hook.setProtocolFeeShareBps(oldShare == 0 ? 1 : oldShare - 1);
        bytes32 changed = l.factory().previewLaunchEconomics(l.launchConfigId(), address(0));
        assertTrue(changed != pinned);
        vm.prank(TEAM);
        vm.expectRevert(abi.encodeWithSignature("LaunchEconomicsMismatch(bytes32,bytes32)", pinned, changed));
        l.launch(salt, predicted, 0, 0);
        assertEq(l.pons(), address(0));
        assertEq(address(l).balance, 1 ether);
    }
}
