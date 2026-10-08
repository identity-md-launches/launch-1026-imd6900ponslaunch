// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture, MockToken, MockEscrow} from "./IMD6900PonsLaunch.t.sol";
import {IMD6900PonsLaunch} from "src/IMD6900PonsLaunch.sol";
import {PonsTokenParams} from "src/IPons.sol";

/// @dev Only the selectors explicitly targeted below run during the campaign. Token minting models
///      bridge arrivals within the pinned global ceiling; no handler manufactures Pons inventory.
contract LaunchTokenHandler is Test {
    IMD6900PonsLaunch public immutable launch;
    MockToken public immutable legacy;
    MockToken public immutable coin;
    address public immutable owner;
    address[3] public actors;
    uint256 public immutable initialCoin;
    uint256 public immutable initialLegacySupply;
    uint256 public immutable ceiling;
    address public immutable initialCurve;
    bytes32 public immutable initialMeta;

    uint256 public claimedIn;
    uint256 public redeemedIn;
    uint256 public redeemedOut;
    uint256 public coinReleased;
    uint256 public legacyReleased;
    uint256 public coinDonated;
    uint256 public legacyDonated;
    uint256 public bridgedIn;
    uint256 public bridgedOut;

    constructor(IMD6900PonsLaunch l, MockToken oldToken, address[3] memory users) {
        launch = l;
        legacy = oldToken;
        coin = MockToken(l.pons());
        owner = l.owner();
        actors = users;
        initialCoin = coin.balanceOf(address(l));
        initialLegacySupply = oldToken.totalSupply();
        ceiling = l.claimSupplyCeiling();
        initialCurve = l.curve();
        initialMeta = keccak256(abi.encode(l.meta()));
    }

    function claim(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = legacy.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        uint256 before = coin.balanceOf(actor);
        vm.startPrank(actor);
        legacy.approve(address(launch), amount);
        launch.claim(amount);
        vm.stopPrank();
        claimedIn += amount;
        assertEq(coin.balanceOf(actor) - before, amount, "claim is exactly 1:1");
        assertEq(legacy.balanceOf(actor), balance - amount);
    }

    function redeem(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = coin.balanceOf(actor);
        uint256 backing = legacy.balanceOf(address(launch));
        if (balance == 0 || backing == 0) return;
        amount = bound(amount, 1, balance < backing ? balance : backing);
        vm.startPrank(actor);
        coin.approve(address(launch), amount);
        if (!launch.redeemOpen()) {
            vm.expectRevert(IMD6900PonsLaunch.RedeemClosed.selector);
            launch.redeem(amount, 0);
        } else {
            uint256 before = legacy.balanceOf(actor);
            uint256 out = launch.redeem(amount, 1);
            assertEq(legacy.balanceOf(actor) - before, out);
            assertEq(coin.balanceOf(actor), balance - amount);
            assertGt(out, 0);
            assertLe(out, amount);
            redeemedIn += amount;
            redeemedOut += out;
        }
        vm.stopPrank();
    }

    function redeemPolicy(bool open, uint16 tax) external {
        tax = uint16(bound(tax, 0, 9_000));
        vm.startPrank(owner);
        launch.setRedeemTaxBps(tax);
        launch.setRedeemOpen(open);
        vm.stopPrank();
    }

    function release(uint256 actorSeed, uint256 amount, bool sell, bool all) external {
        uint256 free = launch.releasable();
        if (free == 0) return;
        amount = all ? free : bound(amount, 1, free);
        address actor = actors[actorSeed % 3];
        uint256 before = coin.balanceOf(actor);
        uint256 ethBefore = actor.balance;
        vm.prank(owner);
        if (sell) {
            uint256 out = launch.releaseAsEth(all ? 0 : amount, 0, actor);
            assertEq(actor.balance - ethBefore, out);
        } else {
            launch.release(all ? 0 : amount, actor);
            assertEq(coin.balanceOf(actor) - before, amount);
        }
        coinReleased += amount;
        assertEq(coin.allowance(address(launch), launch.curve()), 0, "no residual sell approval");
    }

    function releaseLegacy(uint256 actorSeed, uint256 amount, bool all) external {
        uint256 held = legacy.balanceOf(address(launch));
        if (held == 0) return;
        amount = all ? held : bound(amount, 1, held);
        address actor = actors[actorSeed % 3];
        uint256 before = legacy.balanceOf(actor);
        bool open = launch.redeemOpen();
        bool short = coin.balanceOf(address(launch)) < launch.claimReserve() + amount;
        vm.prank(owner);
        if (open) {
            vm.expectRevert(IMD6900PonsLaunch.RedeemIsOpen.selector);
            launch.releaseImdstr(all ? 0 : amount, actor);
        } else if (short) {
            vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
            launch.releaseImdstr(all ? 0 : amount, actor);
        } else {
            launch.releaseImdstr(all ? 0 : amount, actor);
            assertEq(legacy.balanceOf(actor) - before, amount);
            legacyReleased += amount;
        }
    }

    function donate(uint256 actorSeed, uint256 amount, bool oldToken) external {
        address actor = actors[actorSeed % 3];
        MockToken token = oldToken ? legacy : coin;
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        token.transfer(address(launch), amount);
        if (oldToken) legacyDonated += amount;
        else coinDonated += amount;
    }

    function bridge(uint256 actorSeed, uint256 amount, bool arriving) external {
        address actor = actors[actorSeed % 3];
        if (arriving) {
            uint256 remaining = ceiling - legacy.totalSupply();
            if (remaining == 0) return;
            amount = bound(amount, 1, remaining);
            legacy.mint(actor, amount);
            bridgedIn += amount;
        } else {
            uint256 balance = legacy.balanceOf(actor);
            if (balance == 0) return;
            amount = bound(amount, 1, balance);
            legacy.burn(actor, amount);
            bridgedOut += amount;
        }
    }

    function attemptReconfiguration(uint256 seed) external {
        PonsTokenParams memory changed = launch.meta();
        changed.name = "changed after launch";
        vm.startPrank(owner);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        launch.setMeta(changed);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        launch.setLaunchConfig(seed);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        launch.setClaimSupplyCeiling(seed);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        launch.launch(bytes32(seed), address(coin), 0, 0);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        launch.withdrawEth(owner, 0);
        vm.stopPrank();
    }

    function assertAccounting() external view {
        uint256 heldCoin = coin.balanceOf(address(launch));
        uint256 heldLegacy = legacy.balanceOf(address(launch));
        assertEq(heldCoin + claimedIn + coinReleased, initialCoin + redeemedIn + coinDonated);
        assertEq(heldLegacy + redeemedOut + legacyReleased, claimedIn + legacyDonated);
        assertEq(launch.claimed(), claimedIn);
        assertEq(launch.redeemed(), redeemedOut);
        assertEq(coin.totalSupply(), initialCoin, "no call sequence changes Pons supply");
        assertEq(legacy.totalSupply() + bridgedOut, initialLegacySupply + bridgedIn);
        // Full backing is a precondition of this campaign, and every tested action must preserve it.
        assertGe(heldCoin + heldLegacy, ceiling, "claim rights lost their backing");
        assertGe(heldCoin, launch.claimReserve());
        assertEq(launch.pons(), address(coin));
        assertEq(launch.curve(), initialCurve);
        assertEq(launch.claimSupplyCeiling(), ceiling);
        assertEq(keccak256(abi.encode(launch.meta())), initialMeta);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is LaunchFixture {
    LaunchTokenHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        l.setClaimSupplyCeiling(200_000_000e18);
        _launch(1 ether);
        address other = makeAddr("everyone else");
        address third = makeAddr("third holder");
        vm.prank(other);
        imdstr.transfer(third, 30_000_000e18);
        handler = new LaunchTokenHandler(l, imdstr, [holder, other, third]);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.claim.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.redeemPolicy.selector;
        selectors[3] = handler.release.selector;
        selectors[4] = handler.releaseLegacy.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.bridge.selector;
        selectors[7] = handler.attemptReconfiguration.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_InventoryAndCountersMatchAllTokenFlows() public view {
        handler.assertAccounting();
    }

    /// @dev Exercise actual claim liveness after each random sequence, including all remaining
    ///      bridgeable supply. The reserve inequality alone would miss a permanently closed claim path.
    function afterInvariant() public {
        uint256 arriving = l.claimSupplyCeiling() - imdstr.totalSupply();
        if (arriving != 0) handler.bridge(0, arriving, true);
        for (uint256 i; i < 3; ++i) {
            uint256 balance = imdstr.balanceOf(handler.actors(i));
            if (balance != 0) handler.claim(i, balance);
        }
        handler.assertAccounting();
        assertEq(l.claimReserve(), 0, "every outstanding holder could claim");
    }

    function test_HandlerExercisesClaimsRedeemsReleasesAndBridgeArrivals() public {
        handler.claim(0, 100e18);
        handler.redeemPolicy(true, 6_900);
        handler.redeem(0, 50e18);
        handler.donate(0, 1e18, false);
        handler.donate(1, 1e18, true);
        handler.redeemPolicy(false, 0);
        handler.releaseLegacy(2, 1e18, false);
        handler.release(1, 1e18, false, false);
        handler.release(2, 1e18, true, false);
        handler.bridge(0, 100_000_000e18, true);
        handler.claim(0, type(uint256).max);
        handler.bridge(1, 1e18, false);
        handler.attemptReconfiguration(1);
        handler.assertAccounting();
        assertGt(handler.claimedIn(), 0);
        assertGt(handler.redeemedOut(), 0);
        assertGt(handler.legacyReleased(), 0);
        assertGt(handler.coinReleased(), 0);
    }
}

contract InvariantFeePayee {
    bool public refusing;

    function setRefusing(bool value) external {
        refusing = value;
    }

    receive() external payable {
        require(!refusing, "refusing");
    }
}

/// @dev ETH is injected only through receive/addFees or a funded escrow. Recoveries go to a separate
///      sink so the conservation equation remains independent of credits and timelock shortfalls.
contract LaunchFeeHandler is Test {
    IMD6900PonsLaunch public immutable launch;
    MockEscrow public immutable escrow;
    address public immutable timelock;
    address public immutable recoverySink;
    InvariantFeePayee[4] public recipients;
    uint256 public injected;
    uint256 public recovered;
    uint256[4] public allocated;

    constructor(IMD6900PonsLaunch l, MockEscrow e) {
        launch = l;
        escrow = e;
        timelock = l.timelock();
        recoverySink = makeAddr("timelock recovery sink");
        for (uint256 i; i < 4; ++i) {
            recipients[i] = new InvariantFeePayee();
        }
        changePayees(0, 5_000, false);
    }

    function deposit(uint96 amount, uint8 route) external {
        amount = uint96(bound(amount, 1, 10 ether));
        vm.deal(address(this), amount);
        if (route % 3 == 0) {
            launch.addFees{value: amount}();
        } else if (route % 3 == 1) {
            (bool ok,) = address(launch).call{value: amount}("");
            assertTrue(ok);
        } else {
            escrow.book{value: amount}(address(launch));
        }
        injected += amount;
    }

    function changePayees(uint256 seed, uint16 share, bool duplicate) public {
        uint256 first = seed % 4;
        uint256 second = duplicate ? first : (first + 1) % 4;
        share = uint16(bound(share, 0, 10_000));
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], to[1]) = (address(recipients[first]), address(recipients[second]));
        (bps[0], bps[1]) = (share, 10_000 - share);
        address owner = launch.owner();
        vm.prank(owner);
        launch.setPayees(to, bps);
    }

    function refusal(uint256 seed, bool refuse) external {
        recipients[seed % 4].setRefusing(refuse);
    }

    function collect() external {
        uint256 before = address(launch).balance;
        uint256 pending = escrow.balanceOf(address(launch));
        assertEq(launch.collect(bytes32(0)), pending);
        assertEq(address(launch).balance, before + pending);
        assertEq(escrow.balanceOf(address(launch)), 0);
    }

    function split(bool harvest) external {
        uint256 held = address(launch).balance;
        if (harvest) held += escrow.balanceOf(address(launch));
        uint256 owed = launch.totalPendingEth();
        uint256 fresh = held > owed ? held - owed : 0;
        (address[] memory to, uint16[] memory shares) = launch.payees();
        // Model only the advertised pro-rata allocation, independently of payout success/retries.
        // Balances plus outstanding credits below must equal these lifetime entitlements.
        for (uint256 i; i < to.length; ++i) {
            for (uint256 j; j < 4; ++j) {
                if (to[i] == address(recipients[j])) allocated[j] += fresh * shares[i] / 10_000;
            }
        }
        uint256 actual = harvest ? launch.harvest(bytes32(0)) : launch.split();
        assertEq(actual, fresh);
    }

    function retry(uint256 seed) external {
        address to = address(recipients[seed % 4]);
        uint256 before = to.balance;
        uint256 credit = launch.pendingEth(to);
        uint256 paid = launch.split(to);
        assertEq(to.balance - before, paid);
        assertEq(launch.pendingEth(to) + paid, credit, "retry must not allocate new fees");
    }

    function recover(uint96 amount, bool all) external {
        uint256 held = address(launch).balance;
        if (held == 0) return;
        uint256 take = all ? held : bound(amount, 1, held);
        uint256 debt = launch.totalPendingEth();
        vm.prank(timelock);
        launch.recoverEth(recoverySink, all ? 0 : take);
        recovered += take;
        assertEq(launch.totalPendingEth(), debt, "recovery does not forgive unpaid credits");
    }

    function transferOwnership(uint256 seed) external {
        address owner = launch.owner();
        vm.prank(owner);
        launch.transferOwnership(address(recipients[seed % 4]));
    }

    function assertAccounting() external view {
        uint256 paid;
        uint256 debt;
        for (uint256 i; i < 4; ++i) {
            address payee = address(recipients[i]);
            uint256 credit = launch.pendingEth(payee);
            assertEq(payee.balance + credit, allocated[i], "a payee lost or gained someone else's credit");
            paid += payee.balance;
            debt += credit;
        }
        assertEq(launch.totalPendingEth(), debt, "aggregate debt disagrees with individual credits");
        assertEq(recoverySink.balance, recovered);
        assertEq(
            address(launch).balance + escrow.balanceOf(address(launch)) + paid + recovered,
            injected,
            "ETH vanished or was paid twice"
        );
        // Timelock recovery is explicitly allowed to leave credits temporarily unfunded.
        assertLe(debt, address(launch).balance + recovered);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchFeeInvariantTest is LaunchFixture {
    LaunchFeeHandler internal handler;

    function setUp() public override {
        super.setUp();
        _launch(1 ether);
        l.harvest(bytes32(0)); // Settle opening fees before starting the independent fee ledger.
        assertEq(address(l).balance, 0);
        handler = new LaunchFeeHandler(l, factory.feeEscrow());
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.changePayees.selector;
        selectors[2] = handler.refusal.selector;
        selectors[3] = handler.collect.selector;
        selectors[4] = handler.split.selector;
        selectors[5] = handler.retry.selector;
        selectors[6] = handler.recover.selector;
        selectors[7] = handler.transferOwnership.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EthAndEveryPayeesEntitlementAreConserved() public view {
        handler.assertAccounting();
    }

    function test_HandlerExercisesRefusalsRecoveryAndRemovedPayeeRetries() public {
        handler.refusal(0, true);
        handler.deposit(1 ether, 0);
        handler.split(false);
        handler.recover(0.25 ether, false);
        handler.changePayees(2, 7_000, false);
        handler.transferOwnership(3);
        handler.deposit(1 ether, 2);
        handler.collect();
        handler.refusal(0, false);
        handler.retry(0);
        handler.deposit(1, 1);
        handler.split(true);
        handler.assertAccounting();
        assertEq(address(handler.recipients(0)).balance, 0.5 ether);
        assertEq(handler.recovered(), 0.25 ether);
    }
}
