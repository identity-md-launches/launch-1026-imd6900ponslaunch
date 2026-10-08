// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture, MockToken, MockCurve} from "./IMD6900PonsLaunch.t.sol";
import {IMD6900PonsLaunch} from "src/IMD6900PonsLaunch.sol";
import {IPonsCurve, IPonsFeeEscrow, IPonsMemeHook, PonsTokenParams} from "src/IPons.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract LaunchFailurePathsTest is LaunchFixture {
    function _claim(uint256 amount) internal {
        vm.startPrank(holder);
        imdstr.approve(address(l), amount);
        l.claim(amount);
        vm.stopPrank();
    }

    function _openRedeem(uint16 tax) internal {
        vm.startPrank(OWNER);
        l.setRedeemOpen(true);
        l.setRedeemTaxBps(tax);
        vm.stopPrank();
    }

    function _assertUnlaunched(address expected, uint256 held) internal view {
        assertEq(l.pons(), address(0));
        assertEq(l.curve(), address(0));
        assertEq(l.launchEth(), 0);
        assertEq(l.launchBought(), 0);
        assertEq(expected.code.length, 0, "failed launch must roll back CREATE2");
        assertEq(address(l).balance, held, "opening funds must remain withdrawable");
        assertEq(address(factory).balance, 0, "factory cannot retain fee on failure");
    }

    function test_AllOwnerEntrypointsRejectAnUnprivilegedCaller() public {
        PonsTokenParams memory m = l.meta();
        address[] memory to = new address[](1);
        uint16[] memory shares = new uint16[](1);
        (to[0], shares[0]) = (holder, 10_000);
        bytes[] memory calls = new bytes[](13);
        calls[0] = abi.encodeCall(l.setMeta, (m));
        calls[1] = abi.encodeCall(l.setLaunchConfig, (7));
        calls[2] = abi.encodeCall(l.setClaimSupplyCeiling, (200_000_000e18));
        calls[3] = abi.encodeCall(l.withdrawEth, (holder, 1));
        calls[4] = abi.encodeCall(l.launch, (bytes32(0), holder, 0, 0));
        calls[5] = abi.encodeCall(l.setPayees, (to, shares));
        calls[6] = abi.encodeCall(l.handOff, (holder));
        calls[7] = abi.encodeCall(l.release, (1, holder));
        calls[8] = abi.encodeCall(l.releaseAsEth, (1, 0, holder));
        calls[9] = abi.encodeCall(l.releaseImdstr, (1, holder));
        calls[10] = abi.encodeCall(l.setRedeemOpen, (true));
        calls[11] = abi.encodeCall(l.setRedeemTaxBps, (0));
        calls[12] = abi.encodeCall(l.renounceOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(holder);
            (bool ok, bytes memory reason) = address(l).call(calls[i]);
            assertFalse(ok, "privileged call succeeded");
            assertEq(reason, abi.encodeWithSelector(Ownable.Unauthorized.selector));
        }
        assertEq(l.owner(), OWNER);
        assertFalse(l.redeemOpen());
    }

    function test_PrelaunchDistributionAndReleaseAreClosed() public {
        vm.expectRevert(IMD6900PonsLaunch.NotLaunched.selector);
        l.collect(bytes32(0));
        vm.expectRevert(IMD6900PonsLaunch.NotLaunched.selector);
        l.harvest(bytes32(0));
        vm.expectRevert(IMD6900PonsLaunch.NotLaunched.selector);
        l.split(holder);
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.NotLaunched.selector);
        l.handOff(holder);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.release(1, holder);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseAsEth(1, 0, holder);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseImdstr(1, holder);
        vm.stopPrank();
    }

    function test_LaunchSlippageRevertsCreationAndCanRetrySameSalt() public {
        bytes32 salt = keccak256("slippage rollback");
        address expected = factory.predict(salt);
        uint256 fee = factory.launchFee();
        uint256 bought = (1 ether - fee) * 250_000_000;
        vm.deal(address(l), 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(bytes("min"));
        l.launch(salt, expected, 0, bought + 1);
        _assertUnlaunched(expected, 1 ether);
        vm.prank(OWNER);
        (address token, uint256 actual) = l.launch(salt, expected, 0, bought);
        assertEq(token, expected);
        assertEq(actual, bought);
        assertEq(address(l).balance, 0);
    }

    function test_TooLargeOpeningBuyRollsBackFactoryAndCallValue() public {
        address expected = factory.predict(bytes32(0));
        uint256 ownerBefore = OWNER.balance;
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.NoEth.selector);
        l.launch{value: 1 ether}(bytes32(0), expected, 1 ether, 0);
        _assertUnlaunched(expected, 0);
        assertEq(OWNER.balance, ownerBefore);
    }

    function test_InsufficientFactoryFeeDoesNotCommitLaunch() public {
        uint256 amount = factory.launchFee() - 1;
        address expected = factory.predict(bytes32(0));
        vm.deal(address(l), amount);
        vm.prank(OWNER);
        vm.expectRevert(); // EVM cannot forward more ETH than is held.
        l.launch(bytes32(0), expected, 0, 0);
        _assertUnlaunched(expected, amount);
    }

    function test_OneWeiOpeningBuyAndFrozenConfiguration() public {
        uint256 fee = factory.launchFee();
        _launch(fee + 1);
        assertEq(l.launchEth(), 1);
        assertEq(l.launchBought(), 250_000_000);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.setLaunchConfig(type(uint256).max);
        assertEq(l.launchConfigId(), 0);
    }

    function test_EmptySymbolAndMaximumCreatorTax() public {
        PonsTokenParams memory m = l.meta();
        bytes32 previous = keccak256(abi.encode(m));
        m.symbol = "";
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.BadMeta.selector);
        l.setMeta(m);
        assertEq(keccak256(abi.encode(l.meta())), previous);
        m.symbol = "IMD6900";
        m.creatorTaxBps = 1_000;
        m.creatorFeeRecipient = holder;
        m.buybackEnabled = true;
        vm.prank(OWNER);
        l.setMeta(m);
        assertEq(l.meta().creatorTaxBps, 1_000);
        assertEq(l.meta().creatorFeeRecipient, address(l));
        assertFalse(l.meta().buybackEnabled);
    }

    function test_InvalidPayeeArraysRollBackExistingPayees() public {
        address[] memory to = new address[](1);
        uint16[] memory shares = new uint16[](1);
        (to[0], shares[0]) = (holder, 10_000);
        vm.prank(OWNER);
        l.setPayees(to, shares);
        (address[] memory beforeTo, uint16[] memory beforeShares) = l.payees();
        bytes32 beforeHash = keccak256(abi.encode(beforeTo, beforeShares));
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.BadPayees.selector);
        l.setPayees(new address[](0), new uint16[](0));
        vm.expectRevert(IMD6900PonsLaunch.BadPayees.selector);
        l.setPayees(new address[](9), new uint16[](9));
        vm.expectRevert(IMD6900PonsLaunch.BadPayees.selector);
        l.setPayees(to, new uint16[](0));
        shares[0] = type(uint16).max;
        vm.expectRevert(IMD6900PonsLaunch.BadPayees.selector);
        l.setPayees(to, shares);
        vm.stopPrank();
        (to, shares) = l.payees();
        assertEq(keccak256(abi.encode(to, shares)), beforeHash);
    }

    function test_EightPayeesKeepRoundingDustAndShrinkingRemovesStaleEntries() public {
        _launch(1 ether);
        address[] memory to = new address[](8);
        uint16[] memory shares = new uint16[](8);
        for (uint256 i; i < 8; ++i) {
            to[i] = makeAddr(string.concat("payee", vm.toString(i)));
            shares[i] = 1_250;
        }
        vm.prank(OWNER);
        l.setPayees(to, shares);
        vm.deal(address(this), 17);
        l.addFees{value: 17}();
        assertEq(l.split(), 17);
        for (uint256 i; i < 8; ++i) {
            assertEq(to[i].balance, 2);
        }
        assertEq(address(l).balance, 1);
        address[] memory single = new address[](1);
        uint16[] memory full = new uint16[](1);
        (single[0], full[0]) = (holder, 10_000);
        vm.prank(OWNER);
        l.setPayees(single, full);
        l.split();
        assertEq(holder.balance, 1);
        assertEq(address(l).balance, 0);
        for (uint256 i; i < 8; ++i) {
            assertEq(to[i].balance, 2);
        }
    }

    function test_ClaimZeroMissingAllowanceAndInsufficientBalanceAreAtomic() public {
        MockToken token = MockToken(_launch(1 ether));
        uint256 initial = imdstr.balanceOf(holder);
        vm.startPrank(holder);
        vm.expectRevert(IMD6900PonsLaunch.ZeroAmount.selector);
        l.claim(0);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        l.claim(1);
        imdstr.approve(address(l), type(uint256).max);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        l.claim(initial + 1);
        vm.stopPrank();
        assertEq(imdstr.balanceOf(holder), initial);
        assertEq(token.balanceOf(holder), 0);
        assertEq(l.claimed(), 0);
        assertEq(imdstr.allowance(holder, address(l)), type(uint256).max);
    }

    function test_ClaimInventoryShortfallDoesNotTakeLegacyTokens() public {
        MockToken token = MockToken(_launch(factory.launchFee() + 1));
        uint256 amount = token.balanceOf(address(l)) + 1;
        uint256 before = imdstr.balanceOf(holder);
        vm.startPrank(holder);
        imdstr.approve(address(l), amount);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        l.claim(amount);
        vm.stopPrank();
        assertEq(imdstr.balanceOf(holder), before);
        assertEq(imdstr.balanceOf(address(l)), 0);
        assertEq(imdstr.allowance(holder, address(l)), amount);
        assertEq(l.claimed(), 0);
    }

    function test_RestrictedLegacyTransferDoesNotCreditAClaim() public {
        MockToken token = MockToken(_launch(1 ether));
        vm.prank(holder);
        imdstr.approve(address(l), 1e18);
        bytes memory transfer = abi.encodeCall(imdstr.transferFrom, (holder, address(l), 1e18));
        // IMDSTR refuses moves until this launch is an authorized distributor.
        vm.mockCallRevert(address(imdstr), transfer, abi.encodeWithSignature("NotDistributor()"));
        vm.prank(holder);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        l.claim(1e18);
        assertEq(token.balanceOf(holder), 0);
        assertEq(l.claimed(), 0);
        vm.clearMockedCalls();
        vm.prank(holder);
        l.claim(1e18);
        assertEq(token.balanceOf(holder), 1e18);
    }

    function test_RedeemZeroSlippageAndMissingApprovalAreAtomic() public {
        MockToken token = MockToken(_launch(1 ether));
        _claim(100);
        _openRedeem(6_900);
        vm.startPrank(holder);
        vm.expectRevert(IMD6900PonsLaunch.ZeroAmount.selector);
        l.redeem(0, 0);
        vm.expectRevert(IMD6900PonsLaunch.Short.selector);
        l.redeem(100, 32);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        l.redeem(100, 31);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 100);
        assertEq(imdstr.balanceOf(address(l)), 100);
        assertEq(l.redeemed(), 0);
    }

    function test_RedeemInsufficientLegacyBackingRollsBackCoinTransfer() public {
        MockToken token = MockToken(_launch(1 ether));
        _claim(100);
        vm.prank(OWNER);
        l.releaseImdstr(0, OWNER);
        _openRedeem(0);
        vm.startPrank(holder);
        token.approve(address(l), 100);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        l.redeem(100, 100);
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 100);
        assertEq(token.allowance(holder, address(l)), 100);
        assertEq(l.redeemed(), 0);
    }

    function _roundTrip(uint256 amount, uint16 tax) internal {
        MockToken token = MockToken(_launch(1 ether));
        uint256 initialLegacy = imdstr.balanceOf(holder);
        uint256 initialInventory = token.balanceOf(address(l));
        _claim(amount);
        _openRedeem(tax);
        vm.startPrank(holder);
        token.approve(address(l), amount);
        uint256 out = l.redeem(amount, 1);
        vm.stopPrank();
        assertGt(out, 0);
        assertLe(out, amount, "round trip must not create legacy tokens");
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(l)), initialInventory);
        assertEq(imdstr.balanceOf(holder) + imdstr.balanceOf(address(l)), initialLegacy);
        assertEq(l.claimed(), amount);
        assertEq(l.redeemed(), out);
        // The toll is rounded down, within one base unit of the exact rational toll.
        uint256 paidTax = amount - out;
        assertLe(paidTax * 10_000, amount * tax);
        assertLt(amount * tax - paidTax * 10_000, 10_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ClaimRedeemRoundTripConservesTokens(uint256 amount, uint16 tax) public {
        _roundTrip(bound(amount, 1, imdstr.balanceOf(holder)), uint16(bound(tax, 0, 9_000)));
    }

    function test_OneBaseUnitRedeemStillReturnsSomethingAtMaximumTax() public {
        _roundTrip(1, 9_000);
    }

    function test_FullHolderBalanceRoundTripAtZeroTax() public {
        _roundTrip(imdstr.balanceOf(holder), 0);
    }

    function test_FailedReleaseSaleRollsBackInventoryAndAllowance() public {
        MockToken token = MockToken(_launch(1 ether));
        uint256 inventory = token.balanceOf(address(l));
        uint256 free = l.releasable();
        vm.prank(OWNER);
        vm.expectRevert(bytes("min"));
        l.releaseAsEth(free, free / 250_000_000 + 1, OWNER);
        assertEq(token.balanceOf(address(l)), inventory);
        assertEq(token.allowance(address(l), l.curve()), 0);
        assertEq(token.balanceOf(l.curve()), 0);
        vm.prank(OWNER);
        l.releaseAsEth(free, free / 250_000_000, OWNER);
        assertEq(token.balanceOf(address(l)), l.claimReserve());
        assertEq(token.allowance(address(l), l.curve()), 0);
    }

    function test_ReleasesRejectMaximumAmountWithoutMovingTokens() public {
        MockToken token = MockToken(_launch(1 ether));
        _claim(100);
        uint256 inventory = token.balanceOf(address(l));
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.release(type(uint256).max, OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseAsEth(type(uint256).max, 0, OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseImdstr(type(uint256).max, OWNER);
        vm.stopPrank();
        assertEq(token.balanceOf(address(l)), inventory);
        assertEq(imdstr.balanceOf(address(l)), 100);
    }

    function test_RefusedAndExcessiveEthWithdrawalsPreserveFunds() public {
        vm.deal(address(l), 1 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        l.withdrawEth(address(factory), 0);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        l.withdrawEth(OWNER, 1 ether + 1);
        vm.stopPrank();
        assertEq(address(l).balance, 1 ether);
        vm.prank(TIMELOCK);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        l.recoverEth(address(factory), 0);
        assertEq(address(l).balance, 1 ether);
        vm.prank(TIMELOCK);
        l.recoverEth(holder, 0);
        assertEq(holder.balance, 1 ether);
        vm.prank(TIMELOCK);
        vm.expectRevert(IMD6900PonsLaunch.NoEth.selector);
        l.recoverEth(holder, 0);
    }

    function test_CurveSweepFailureStillCollectsAlreadyBookedFeesOnlyOnce() public {
        _launch(1 ether);
        vm.deal(address(this), 123);
        factory.feeEscrow().book{value: 123}(address(l));
        bytes memory reason = abi.encodeWithSignature("SweepUnavailable()");
        vm.mockCallRevert(l.curve(), abi.encodeCall(IPonsCurve.sweepFees, (0)), reason);
        vm.expectEmit(false, false, false, true, address(l));
        emit IMD6900PonsLaunch.SweepFailed(reason);
        assertEq(l.collect(bytes32(0)), 123);
        assertEq(l.collect(bytes32(0)), 0);
        assertEq(address(l).balance, 123);
        assertEq(factory.feeEscrow().balanceOf(address(l)), 0);
    }

    function test_GraduatedCollectSkipsCurveAndZeroPoolThenSweepsSpecifiedPool() public {
        _launch(1 ether);
        vm.mockCall(l.curve(), abi.encodeCall(IPonsCurve.graduated, ()), abi.encode(true));
        address hook = factory.memeHook();
        vm.expectCall(l.curve(), abi.encodeCall(IPonsCurve.sweepFees, (0)), 0);
        vm.expectCall(hook, abi.encodeCall(IPonsMemeHook.sweepPoolFees, (bytes32(0), 0, 0)), 0);
        assertEq(l.collect(bytes32(0)), 0);
        bytes32 pool = keccak256("pool");
        bytes memory sweep = abi.encodeCall(IPonsMemeHook.sweepPoolFees, (pool, 0, 0));
        vm.mockCall(hook, sweep, bytes(""));
        vm.expectCall(hook, sweep, 1);
        assertEq(l.collect(pool), 0);
        assertEq(address(l).balance, 0);
    }

    function test_EscrowClaimFailureRollsBackTheSweep() public {
        _launch(1 ether);
        MockCurve curve = MockCurve(payable(l.curve()));
        uint256 pending = curve.pending();
        vm.mockCallRevert(
            address(factory.feeEscrow()), abi.encodeCall(IPonsFeeEscrow.claim, ()), bytes("escrow unavailable")
        );
        vm.expectRevert(bytes("escrow unavailable"));
        l.harvest(bytes32(0));
        assertEq(curve.pending(), pending);
        assertEq(factory.feeEscrow().balanceOf(address(l)), 0);
        assertEq(address(l).balance, 0);
        vm.clearMockedCalls();
        assertEq(l.collect(bytes32(0)), pending);
    }
}
