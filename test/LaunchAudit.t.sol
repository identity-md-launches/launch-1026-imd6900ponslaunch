// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture, MockToken, MockEscrow} from "./IMD6900PonsLaunch.t.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {IPonsCurve, IPonsMemeHook, PonsTokenParams} from "../src/IPons.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract SwitchablePayee {
    bool public refusing = true;

    function accept() external {
        refusing = false;
    }

    receive() external payable {
        require(!refusing, "refused");
    }
}

contract ReenteringPayee {
    IMD6900PonsLaunch immutable launch;
    bool public reentered;

    constructor(IMD6900PonsLaunch l) {
        launch = l;
    }

    receive() external payable {
        (reentered,) = address(launch).call(abi.encodeWithSignature("split(address)", address(this)));
    }
}

contract LaunchAuditTest is LaunchFixture {
    function _fees(uint256 amount) internal {
        vm.deal(address(this), amount);
        l.addFees{value: amount}();
    }

    function _twoPayees(address a, address b, uint16 share) internal {
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], to[1], bps[0], bps[1]) = (a, b, share, 10_000 - share);
        vm.prank(OWNER);
        l.setPayees(to, bps);
    }

    function _claim(address who, uint256 amount) internal {
        vm.startPrank(who);
        imdstr.approve(address(l), amount);
        l.claim(amount);
        vm.stopPrank();
    }

    function test_RefusedFeesSurviveRepeatedSplitsAndNewFees() public {
        _launch(1 ether);
        SwitchablePayee refuser = new SwitchablePayee();
        address ops = makeAddr("ops");
        _twoPayees(address(refuser), ops, 5_000);
        _fees(1 ether);
        l.split();
        for (uint256 i; i < 10; ++i) {
            l.split();
        }
        assertEq(ops.balance, 0.5 ether);
        assertEq(l.pendingEth(address(refuser)), 0.5 ether);
        assertEq(address(l).balance, 0.5 ether);
        _fees(1 ether);
        l.split();
        assertEq(ops.balance, 1 ether);
        assertEq(l.totalPendingEth(), 1 ether);
        refuser.accept();
        l.split();
        assertEq(address(refuser).balance, 1 ether);
        assertEq(l.totalPendingEth(), 0);
        assertEq(address(l).balance, 0);
    }

    function test_RemovedPayeeKeepsItsOwnCredit() public {
        _launch(1 ether);
        SwitchablePayee oldPayee = new SwitchablePayee();
        address ops = makeAddr("ops");
        _twoPayees(address(oldPayee), ops, 5_000);
        _fees(1 ether);
        l.split();
        _twoPayees(OWNER, ops, 5_000);
        l.split();
        assertEq(ops.balance, 0.5 ether);
        oldPayee.accept();
        assertEq(l.split(address(oldPayee)), 0.5 ether);
        assertEq(address(oldPayee).balance, 0.5 ether);
        assertEq(l.split(address(oldPayee)), 0);
        assertEq(l.totalPendingEth(), 0);
    }

    function test_TimelockMayRecoverRetainedFeesAndFutureFeesRestoreCredits() public {
        _launch(1 ether);
        SwitchablePayee refuser = new SwitchablePayee();
        address ops = makeAddr("ops");
        _twoPayees(address(refuser), ops, 5_000);
        _fees(1 ether);
        l.split();
        vm.prank(TIMELOCK);
        l.recoverEth(OWNER, 0.2 ether);
        refuser.accept();
        assertEq(l.split(address(refuser)), 0.3 ether);
        assertEq(l.totalPendingEth(), 0.2 ether);
        assertEq(l.split(), 0);
        _fees(0.4 ether);
        assertEq(l.split(), 0.2 ether, "only ETH beyond the unpaid credit is new fees");
        assertEq(address(refuser).balance, 0.6 ether);
        assertEq(ops.balance, 0.6 ether);
        assertEq(l.totalPendingEth(), 0);
        assertEq(address(l).balance, 0);
    }

    function test_FullTimelockRecoveryDoesNotUnderflowSplit() public {
        _launch(1 ether);
        SwitchablePayee refuser = new SwitchablePayee();
        _twoPayees(address(refuser), OWNER, 5_000);
        _fees(1 ether);
        l.split();
        vm.prank(TIMELOCK);
        l.recoverEth(OWNER, 0);
        assertEq(l.split(), 0);
        assertEq(l.split(address(refuser)), 0);
        assertEq(l.pendingEth(address(refuser)), 0.5 ether);
        _fees(0.5 ether);
        refuser.accept();
        l.split();
        assertEq(address(refuser).balance, 0.5 ether);
        assertEq(l.totalPendingEth(), 0);
    }

    function test_SplitReentrancyCannotSpendACreditTwice() public {
        _launch(1 ether);
        ReenteringPayee recipient = new ReenteringPayee(l);
        _twoPayees(address(recipient), OWNER, 5_000);
        _fees(1 ether);
        l.split();
        assertFalse(recipient.reentered());
        assertEq(address(recipient).balance, 0.5 ether);
        assertEq(l.totalPendingEth(), 0);
    }

    function testFuzz_RefusedCreditAndRoundingAreConserved(uint96 incoming, uint16 share, uint8 repeats) public {
        uint256 amount = bound(uint256(incoming), 1, 100 ether);
        share = uint16(bound(uint256(share), 0, 10_000));
        repeats = uint8(bound(uint256(repeats), 1, 10));
        _launch(1 ether);
        SwitchablePayee refuser = new SwitchablePayee();
        address ops = makeAddr("ops");
        _twoPayees(address(refuser), ops, share);
        _fees(amount);
        l.split();
        uint256 credit = amount * share / 10_000;
        for (uint256 i; i < repeats; ++i) {
            l.split();
        }
        assertGe(l.pendingEth(address(refuser)), credit, "a refused share never shrinks");
        assertEq(ops.balance + address(l).balance, amount);
        assertEq(l.totalPendingEth(), l.pendingEth(address(refuser)));
        refuser.accept();
        l.split();
        assertEq(l.totalPendingEth(), 0);
        assertEq(address(refuser).balance + ops.balance + address(l).balance, amount);
        assertLe(address(l).balance, 1, "only division dust remains");
    }

    function test_RenunciationCannotBurnDefaultOpsFees() public {
        _launch(1 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.OwnershipRequired.selector);
        l.renounceOwnership();
        assertEq(l.owner(), OWNER);
        uint256 zeroBefore = address(0).balance;
        uint256 ownerBefore = OWNER.balance;
        _fees(1 ether);
        l.split();
        assertEq(address(0).balance, zeroBefore);
        assertEq(OWNER.balance - ownerBefore, 0.3 ether);
        assertEq(l.POT_BRIDGE().balance, 0.7 ether);
    }

    function test_DefaultOpsFollowsOwnershipButOldCreditDoesNot() public {
        _launch(1 ether);
        SwitchablePayee oldOwner = new SwitchablePayee();
        vm.prank(OWNER);
        l.transferOwnership(address(oldOwner));
        _fees(1 ether);
        l.split();
        assertEq(l.pendingEth(address(oldOwner)), 0.3 ether);
        vm.prank(address(oldOwner));
        l.transferOwnership(OWNER);
        uint256 before = OWNER.balance;
        l.split();
        assertEq(OWNER.balance, before);
        oldOwner.accept();
        l.split(address(oldOwner));
        assertEq(address(oldOwner).balance, 0.3 ether);
    }

    function test_ReleaseReservesForFutureBridgeIns() public {
        vm.prank(OWNER);
        l.setClaimSupplyCeiling(200_000_000e18);
        address token = _launch(1 ether);
        vm.prank(OWNER);
        l.release(0, OWNER);
        assertEq(MockToken(token).balanceOf(address(l)), 200_000_000e18);
        address bridger = makeAddr("bridger");
        imdstr.mint(bridger, 100_000_000e18); // OFT bridge-in: local supply grows within the global ceiling.
        _claim(bridger, 100_000_000e18);
        _claim(holder, 10_000_000e18);
        _claim(makeAddr("everyone else"), 90_000_000e18);
        assertEq(MockToken(token).balanceOf(address(l)), 0);
        assertEq(l.claimReserve(), 0);
    }

    function test_ReleaseAsEthAlsoReservesForBridgeIns() public {
        vm.prank(OWNER);
        l.setClaimSupplyCeiling(200_000_000e18);
        address token = _launch(1 ether);
        vm.prank(OWNER);
        l.releaseAsEth(0, 0, OWNER);
        assertEq(MockToken(token).balanceOf(address(l)), 200_000_000e18);
        assertEq(MockToken(token).allowance(address(l), l.curve()), 0);
    }

    function test_UnsetCeilingDisablesBothTokenReleasePaths() public {
        l = new IMD6900PonsLaunch(OWNER, address(factory), address(imdstr), TIMELOCK);
        _pinEconomics();
        address token = _launch(1 ether);
        assertEq(l.releasable(), 0);
        assertEq(l.claimReserve(), type(uint256).max);
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.release(0, OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseAsEth(1, 0, OWNER);
        vm.stopPrank();
        _claim(holder, 1e18);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseImdstr(0, OWNER);
        assertEq(MockToken(token).balanceOf(holder), 1e18, "claims stay open");
    }

    function test_CeilingOnlyOwnerBoundedAndFrozenAtLaunch() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        l.setClaimSupplyCeiling(200_000_000e18);
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.setClaimSupplyCeiling(0);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.setClaimSupplyCeiling(99_000_000e18);
        vm.stopPrank();
        _launch(1 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.setClaimSupplyCeiling(100_000_000e18);
    }

    function test_UnderfundedCeilingAllowsClaimsButNoReleases() public {
        vm.prank(OWNER);
        l.setClaimSupplyCeiling(500_000_000e18);
        address token = _launch(1 ether); // About 250M, not full global backing.
        assertGt(l.claimReserve(), MockToken(token).balanceOf(address(l)));
        assertEq(l.releasable(), 0);
        _claim(holder, 1e18);
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.release(1, OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseImdstr(1, OWNER);
        vm.stopPrank();
    }

    function test_LocalSupplyAbovePinnedCeilingIncreasesReserve() public {
        _launch(1 ether);
        imdstr.mint(holder, 10_000_000e18);
        assertEq(l.claimReserve(), 110_000_000e18);
    }

    function test_ReleaseImdstrCannotRecirculateUnbackedClaimRights() public {
        address token = _launch(1 ether);
        _claim(holder, 10_000_000e18);
        vm.startPrank(OWNER);
        l.release(0, OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.releaseImdstr(0, OWNER);
        vm.stopPrank();
        assertEq(imdstr.balanceOf(address(l)), 10_000_000e18, "failed transfer rolled back");
        assertEq(MockToken(token).balanceOf(address(l)), 90_000_000e18);
        // Replenish inventory before restoring claim rights.
        MockToken(token).mint(address(l), 10_000_000e18);
        vm.prank(OWNER);
        l.releaseImdstr(0, OWNER);
        _claim(OWNER, 10_000_000e18);
        _claim(makeAddr("everyone else"), 90_000_000e18);
        assertEq(MockToken(token).balanceOf(address(l)), 0);
    }

    function test_LaunchRequiresAnExplicitExpectedAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.ExpectedTokenRequired.selector);
        l.launch{value: 1 ether}(bytes32(0), address(0), 0, 0);
        assertEq(l.pons(), address(0));
    }

    function test_LaunchRequiresEconomicsPinnedBeforehand() public {
        PonsTokenParams memory m = l.meta();
        m.expectedEconomics = bytes32(0);
        vm.prank(OWNER);
        l.setMeta(m);
        address expected = factory.predict(bytes32(0));
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.EconomicsNotPinned.selector);
        l.launch{value: 1 ether}(bytes32(0), expected, 0, 0);
    }

    function test_ChangedEconomicsRevertsWithoutLosingOpeningFunds() public {
        factory.setEconomics(keccak256("changed fee policy"));
        bytes32 salt = keccak256("reviewed salt");
        address expected = factory.predict(salt);
        vm.deal(address(l), 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(bytes("economics"));
        l.launch(salt, expected, 0, 0);
        assertEq(address(l).balance, 1 ether);
        assertEq(l.pons(), address(0));
        _pinEconomics(); // Owner explicitly reviews and accepts the new terms.
        vm.prank(OWNER);
        l.launch(salt, expected, 0, 0);
        assertEq(l.pons(), expected);
    }

    function test_SetMetaCannotRedirectCreatorFeesOrEnableBuyback() public {
        PonsTokenParams memory m = l.meta();
        m.creatorFeeRecipient = OWNER;
        m.buybackEnabled = true;
        vm.prank(OWNER);
        l.setMeta(m);
        _launch(1 ether);
        (,,,,, address recipient,, bool buyback,,) = factory.last();
        assertEq(recipient, address(l));
        assertFalse(buyback);
    }

    function test_OwnerCanRouteAllFeesToItself_TrustAssumption() public {
        _launch(1 ether);
        _twoPayees(OWNER, OWNER, 5_000);
        _fees(1 ether);
        uint256 before = OWNER.balance;
        l.split();
        assertEq(OWNER.balance - before, 1 ether);
        assertEq(l.totalPendingEth(), 0, "duplicate payees do not double-spend a credit");
    }

    function test_PoolConversionFailureStillClaimsBookedEscrow() public {
        _launch(1 ether);
        bytes32 pool = keccak256("graduated pool");
        vm.mockCall(l.curve(), abi.encodeCall(IPonsCurve.graduated, ()), abi.encode(true));
        bytes memory failure = abi.encodeWithSignature("InternalSwapRequiresOperator()");
        vm.mockCallRevert(
            address(factory.memeHook()), abi.encodeCall(IPonsMemeHook.sweepPoolFees, (pool, 0, 0)), failure
        );
        MockEscrow escrow = factory.feeEscrow();
        vm.deal(address(this), 1 ether);
        escrow.book{value: 1 ether}(address(l));
        vm.expectEmit(false, false, false, true, address(l));
        emit IMD6900PonsLaunch.SweepFailed(failure);
        assertEq(l.collect(pool), 1 ether);
        assertEq(escrow.balanceOf(address(l)), 0);
        assertEq(address(l).balance, 1 ether);
    }
}
