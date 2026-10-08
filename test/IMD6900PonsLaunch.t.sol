// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsTokenParams, PonsSocials} from "../src/IPons.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev An ERC-20 for the tests: the stand-in coin and the stand-in IMDSTR
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function burn(address from, uint256 a) external {
        balanceOf[from] -= a;
        totalSupply -= a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Pons' fee escrow: holds what the curve booked for a recipient, pays it out on claim
contract MockEscrow {
    mapping(address => uint256) public balanceOf;

    function book(address r) external payable {
        balanceOf[r] += msg.value;
    }

    function claim() external returns (uint256 a) {
        a = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "claim");
    }
}

/// @dev A curve at a fixed 250M coin per ETH both ways; it keeps 6.6% of every buy as the creator's fee until swept
contract MockCurve {
    MockToken public immutable token;
    MockEscrow public immutable escrow;
    address public immutable recipient;
    uint256 public pending;

    constructor(MockToken t, MockEscrow e, address r) {
        (token, escrow, recipient) = (t, e, r);
    }

    function graduated() external pure returns (bool) {
        return false;
    }

    function sweepFees(uint256) external {
        require(msg.sender == recipient, "only the creator fee recipient");
        uint256 a = pending;
        pending = 0;
        escrow.book{value: a}(recipient);
    }

    function buy(uint256 quoteIn, uint256 minOut, address to) external payable returns (uint256 out) {
        require(msg.value == quoteIn, "value");
        pending += quoteIn * 660 / 10_000;
        out = quoteIn * 250_000_000;
        require(out >= minOut, "min");
        token.mint(to, out);
    }

    function sell(uint256 tokensIn, uint256 minOut, address to) external returns (uint256 out) {
        token.transferFrom(msg.sender, address(this), tokensIn);
        out = tokensIn / 250_000_000;
        require(out >= minOut, "min");
        payable(to).transfer(out);
    }

    receive() external payable {}
}

/// @dev Pons' factory, as far as the launch sees it
contract MockFactory {
    PonsTokenParams public last;
    uint256 public constant launchFee = 0.0005 ether;
    MockEscrow public immutable feeEscrow = new MockEscrow();
    address public constant memeHook = address(0xbeef);
    mapping(address => address) public recipientOf;

    function transferCreatorFeeRecipient(address token, address to) external {
        require(msg.sender == recipientOf[token], "not the recipient");
        recipientOf[token] = to;
    }

    function previewLaunchEconomics(uint256, address) external pure returns (bytes32) {
        return keccak256("economics");
    }

    function launchToken(PonsTokenParams calldata p, uint256, address) external payable returns (address token, address curve) {
        require(msg.value == launchFee, "fee");
        require(p.expectedEconomics == keccak256("economics"), "economics");
        last = p;
        MockToken t = new MockToken{salt: p.salt}();
        MockCurve c = new MockCurve(t, feeEscrow, p.creatorFeeRecipient);
        recipientOf[address(t)] = p.creatorFeeRecipient;
        return (address(t), address(c));
    }

    function predict(bytes32 salt) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(MockToken).creationCode))))));
    }
}

/// @notice The launch contract offline: it deploys where nothing it names exists (IMD's fresh-chain run), passes IMD's
///         admission scan and limits, holds the team's ETH and gives it back, and launches, claims, releases and
///         redeems as it should (against a stand-in Pons; test/PonsLaunch.fork.t.sol runs the real one).
contract IMD6900PonsLaunchTest is Test {
    address constant OWNER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant IMDSTR = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant TIMELOCK = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14; // Robinhood's (12h)
    uint256 constant TX_GAS_CAP = 1 << 24; // EIP-7825
    uint256 constant INITCODE_CAP = 49_152; // EIP-3860

    MockFactory factory;
    MockToken imdstr;
    IMD6900PonsLaunch l;
    address holder = makeAddr("an IMDSTR holder");

    function setUp() public {
        factory = new MockFactory();
        imdstr = new MockToken();
        imdstr.mint(holder, 10_000_000e18);
        imdstr.mint(makeAddr("everyone else"), 90_000_000e18); // 100M IMDSTR in all
        l = new IMD6900PonsLaunch(OWNER, address(factory), address(imdstr), TIMELOCK);
        vm.deal(OWNER, 10 ether);
    }

    /* ── IMD's admission ─────────────────────────────────────────── */

    function test_DeploysOnAFreshChain() public {
        assertEq(PONS_FACTORY.code.length + IMDSTR.code.length, 0, "a fresh chain: neither exists");
        IMD6900PonsLaunch f = new IMD6900PonsLaunch(OWNER, PONS_FACTORY, IMDSTR, TIMELOCK);
        assertEq(f.owner(), OWNER);
        assertEq(address(f.factory()), PONS_FACTORY);
        assertEq(f.imdstr(), IMDSTR);
        assertEq(f.timelock(), TIMELOCK);
        PonsTokenParams memory m = f.meta();
        assertEq(m.name, "Identity.MD 6900");
        assertEq(m.symbol, "IMD6900");
        assertEq(m.creatorTaxBps, 590);
        assertEq(m.creatorFeeRecipient, address(f), "the fees: to the contract, the distributor");
        (address[] memory to, uint16[] memory bps) = f.payees();
        assertEq(to.length, 2);
        assertEq(to[0], f.POT_BRIDGE());
        assertEq(bps[0], 7_000, "70% to the NFT pot");
        assertEq(to[1], OWNER);
        assertEq(bps[1], 3_000);
        assertEq(m.socials.twitter, "https://x.com/IMD6900");
        assertEq(f.pons(), address(0));
    }

    function test_FitsOneTransaction() public {
        bytes memory init = abi.encodePacked(type(IMD6900PonsLaunch).creationCode, abi.encode(OWNER, PONS_FACTORY, IMDSTR, TIMELOCK));
        assertLt(init.length, INITCODE_CAP, "initcode");
        uint256 g = gasleft();
        new IMD6900PonsLaunch(OWNER, PONS_FACTORY, IMDSTR, TIMELOCK);
        uint256 used = g - gasleft() + 53_000 + 40 * init.length;
        emit log_named_uint("deploy gas, calldata included", used);
        assertLt(used, TX_GAS_CAP);
    }

    function test_PassesTheAdmissionScan() public {
        _scan(type(IMD6900PonsLaunch).creationCode, "creation code");
        _scan(address(l).code, "runtime");
        // and with the owner's own details stored
        PonsTokenParams memory m = l.meta();
        m.description = "a longer description than thirty-one bytes, stored in its own slots";
        vm.prank(OWNER);
        l.setMeta(m);
        _scan(address(l).code, "runtime after setMeta");
    }

    /// @dev IMD reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT
    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }

    /* ── the team's ETH ──────────────────────────────────────────── */

    function test_EthComesInAndGoesBackToTheOwner() public {
        vm.prank(OWNER);
        (bool ok,) = address(l).call{value: 2 ether}("");
        assertTrue(ok, "a plain transfer");
        assertEq(address(l).balance, 2 ether);

        vm.prank(makeAddr("someone"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        l.withdrawEth(makeAddr("someone"), 0);

        address wallet = makeAddr("team wallet");
        vm.prank(OWNER);
        l.withdrawEth(wallet, 0.5 ether);
        assertEq(wallet.balance, 0.5 ether);
        vm.prank(OWNER);
        l.withdrawEth(wallet, 0); // the rest
        assertEq(wallet.balance, 2 ether);
        assertEq(address(l).balance, 0);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.NoEth.selector);
        l.withdrawEth(wallet, 0);
    }

    /* ── the brand ───────────────────────────────────────────────── */

    function test_MetaOnlyTheOwner_bounded_untilTheLaunch() public {
        PonsTokenParams memory m = l.meta();
        m.logo = "https://example.org/logo.png";
        vm.expectRevert(Ownable.Unauthorized.selector);
        l.setMeta(m);

        m.creatorTaxBps = 1_001;
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.TaxTooHigh.selector);
        l.setMeta(m);

        m.creatorTaxBps = 590;
        m.name = "";
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.BadMeta.selector);
        l.setMeta(m);

        m.name = "Identity.MD 6900";
        vm.prank(OWNER);
        l.setMeta(m);
        assertEq(l.meta().logo, "https://example.org/logo.png");

        _launch(1 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.setMeta(m);
    }

    /* ── the launch ──────────────────────────────────────────────── */

    function _launch(uint256 eth) internal returns (address token) {
        vm.prank(OWNER);
        (bool ok,) = address(l).call{value: eth}("");
        assertTrue(ok);
        bytes32 salt = keccak256("mined");
        address expected = factory.predict(salt);
        vm.prank(OWNER);
        (token,) = l.launch(salt, expected, 0, 0);
    }

    function test_LaunchBuysFirstWithAllTheEth() public {
        address token = _launch(2 ether);
        assertEq(l.pons(), token);
        (, string memory symbol,,,,,,,,) = factory.last();
        assertEq(symbol, "IMD6900");
        (,,,,, address recipient, uint16 tax, bool buyback,,) = factory.last();
        assertEq(recipient, address(l), "the creator fees: this contract's, the distributor");
        assertEq(tax, 590);
        assertFalse(buyback);
        assertEq(address(l).balance, 0, "all of it bought the coin");
        assertEq(l.launchEth(), 2 ether - 0.0005 ether, "everything but Pons' launch fee");
        assertEq(MockToken(token).balanceOf(address(l)), (2 ether - 0.0005 ether) * 250_000_000);

        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.launch(bytes32(0), address(0), 0, 0);
    }

    function test_LaunchRefusesAnAddressItWasNotMinedFor() public {
        vm.prank(OWNER);
        (bool ok,) = address(l).call{value: 1 ether}("");
        assertTrue(ok);
        bytes32 salt = keccak256("mined");
        (address elsewhere, address there) = (factory.predict(keccak256("another salt")), factory.predict(salt));
        vm.prank(OWNER); // the predictions above, not in the call's arguments: they'd use up the prank
        vm.expectRevert(abi.encodeWithSelector(IMD6900PonsLaunch.NotWhereMined.selector, there));
        l.launch(salt, elsewhere, 0, 0);
    }

    function test_LaunchOnlyTheOwner_andWithEth() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        l.launch(bytes32(0), address(0), 0, 0);
        vm.deal(address(l), 0.0005 ether); // only the fee: nothing to buy with
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.NoEth.selector);
        l.launch(bytes32(0), address(0), 0, 0);
    }

    function test_LaunchWithTheEthSentAlong_partOfIt_theRestBackToTheOwner() public {
        uint256 before = OWNER.balance;
        vm.prank(OWNER);
        l.launch{value: 1 ether}(keccak256("s"), address(0), 0.5 ether, 0);
        assertEq(l.launchEth(), 0.5 ether);
        assertEq(address(l).balance, 0, "what isn't spent goes back: after the launch only fees come here");
        assertEq(before - OWNER.balance, 0.5 ether + 0.0005 ether);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.withdrawEth(OWNER, 0);
    }

    /* ── the fee distributor ─────────────────────────────────────── */

    function test_HarvestSplitsPonsFeesToThePotAndOps() public {
        _launch(2 ether); // the opening buy's own fee is booked too
        address buyer = makeAddr("a buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        MockCurve(payable(l.curve())).buy{value: 1 ether}(1 ether, 0, buyer);
        uint256 fees = MockCurve(payable(l.curve())).pending();
        assertGt(fees, 0);
        uint256 ownerBefore = OWNER.balance;
        uint256 split = l.harvest(bytes32(0)); // anyone
        assertEq(split, fees);
        assertEq(l.POT_BRIDGE().balance, fees * 7_000 / 10_000, "70% to the NFT pot's bridge");
        assertEq(OWNER.balance - ownerBefore, fees * 3_000 / 10_000, "30% ops");
        assertEq(address(l).balance, 0);
    }

    function test_AddFeesFromThePerpsPool_splitWithEverythingElse() public {
        _launch(1 ether);
        l.harvest(bytes32(0)); // the opening buy's fee out first
        address pool = makeAddr("perps pool");
        address ops = makeAddr("ops");
        address[] memory to = new address[](3);
        uint16[] memory bps = new uint16[](3);
        (to[0], to[1], to[2]) = (l.POT_BRIDGE(), pool, ops);
        (bps[0], bps[1], bps[2]) = (7_000, 1_000, 2_000);
        vm.prank(OWNER);
        l.setPayees(to, bps);
        vm.deal(pool, 1 ether);
        vm.prank(pool);
        l.addFees{value: 1 ether}();
        uint256 potBefore = l.POT_BRIDGE().balance;
        l.split();
        assertEq(l.POT_BRIDGE().balance - potBefore, 0.7 ether);
        assertEq(pool.balance, 0.1 ether);
        assertEq(ops.balance, 0.2 ether);
    }

    function test_SplitNotBeforeTheLaunch_theEthIsTheOpeningBuys() public {
        vm.prank(OWNER);
        (bool ok,) = address(l).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(IMD6900PonsLaunch.NotLaunched.selector);
        l.split();
        assertEq(address(l).balance, 1 ether);
    }

    function test_SetPayeesBounded_onlyTheOwner() public {
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], to[1], bps[0], bps[1]) = (makeAddr("a"), makeAddr("b"), 5_000, 4_999);
        vm.expectRevert(Ownable.Unauthorized.selector);
        l.setPayees(to, bps);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.BadPayees.selector);
        l.setPayees(to, bps); // 99.99%
        to[1] = address(0);
        bps[1] = 5_000;
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.BadPayees.selector);
        l.setPayees(to, bps);
    }

    /// @dev A payee that refuses ETH doesn't stop the others; its share waits for the next split
    function test_ARefusingPayeeKeepsItsShareHere() public {
        _launch(1 ether);
        l.harvest(bytes32(0));
        address[] memory to = new address[](2);
        uint16[] memory bps = new uint16[](2);
        (to[0], to[1], bps[0], bps[1]) = (address(factory), makeAddr("ops"), 5_000, 5_000); // the factory takes no ETH
        vm.prank(OWNER);
        l.setPayees(to, bps);
        vm.deal(address(this), 1 ether);
        l.addFees{value: 1 ether}();
        l.split();
        assertEq(makeAddr("ops").balance, 0.5 ether);
        assertEq(address(l).balance, 0.5 ether, "kept for the next split");
    }

    /// @dev After the launch the owner can't take ETH; the Robinhood timelock can, behind its delay
    function test_TimelockRecoversEth_theOwnerCant() public {
        _launch(1 ether);
        vm.deal(address(this), 1 ether);
        l.addFees{value: 1 ether}();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.AlreadyLaunched.selector);
        l.withdrawEth(OWNER, 0);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.NotTimelock.selector);
        l.recoverEth(OWNER, 0);
        uint256 held = address(l).balance;
        address to = makeAddr("wherever the timelock op says");
        vm.prank(TIMELOCK);
        l.recoverEth(to, 0);
        assertEq(to.balance, held);
        assertEq(address(l).balance, 0);
    }

    function test_HandOffTheFees() public {
        address token = _launch(1 ether);
        address next = makeAddr("a successor distributor");
        vm.expectRevert(Ownable.Unauthorized.selector);
        l.handOff(next);
        vm.prank(OWNER);
        l.handOff(next);
        assertEq(factory.recipientOf(token), next);
    }

    /* ── after: claims, releases, redeems ────────────────────────── */

    function test_ClaimOneToOne() public {
        address token = _launch(1 ether);
        vm.startPrank(holder);
        imdstr.approve(address(l), 4_000_000e18);
        l.claim(4_000_000e18);
        vm.stopPrank();
        assertEq(MockToken(token).balanceOf(holder), 4_000_000e18);
        assertEq(imdstr.balanceOf(address(l)), 4_000_000e18, "the IMDSTR stays here");
        assertEq(l.claimed(), 4_000_000e18);
    }

    function test_ClaimNotBeforeTheLaunch() public {
        vm.prank(holder);
        vm.expectRevert(IMD6900PonsLaunch.NotLaunched.selector);
        l.claim(1);
    }

    /// @dev 1 ETH buys ~250M of the coin; 100M IMDSTR exists, so ~150M is the owner's, never a holder's 1:1
    function test_ReleaseOnlyWhatNoHolderCanClaim() public {
        address token = _launch(1 ether);
        uint256 held = MockToken(token).balanceOf(address(l));
        assertEq(l.releasable(), held - 100_000_000e18);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.Reserved.selector);
        l.release(held, OWNER);
        vm.prank(OWNER);
        l.release(0, OWNER);
        assertEq(MockToken(token).balanceOf(address(l)), 100_000_000e18, "every IMDSTR can still claim");
        assertEq(l.releasable(), 0);
        // a claim keeps it whole: one IMDSTR in, one coin out
        vm.startPrank(holder);
        imdstr.approve(address(l), 1e18);
        l.claim(1e18);
        vm.stopPrank();
        assertEq(l.releasable(), 0);
    }

    function test_ReleaseAsEth() public {
        _launch(1 ether);
        uint256 free = l.releasable();
        address wallet = makeAddr("team wallet");
        vm.prank(OWNER);
        uint256 out = l.releaseAsEth(free, 0, wallet);
        assertEq(out, free / 250_000_000);
        assertEq(wallet.balance, out);
    }

    function test_RedeemTaxed_onlyWhenOpen_andIMDSTROnlyWhenClosed() public {
        address token = _launch(1 ether);
        vm.startPrank(holder);
        imdstr.approve(address(l), 2_000_000e18);
        l.claim(2_000_000e18);
        MockToken(token).approve(address(l), 1_000_000e18);
        vm.expectRevert(IMD6900PonsLaunch.RedeemClosed.selector);
        l.redeem(1_000_000e18, 0);
        vm.stopPrank();

        vm.prank(OWNER);
        l.setRedeemOpen(true);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.RedeemIsOpen.selector);
        l.releaseImdstr(0, OWNER);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900PonsLaunch.TaxTooHigh.selector);
        l.setRedeemTaxBps(9_001);

        uint256 before = imdstr.balanceOf(holder);
        vm.prank(holder);
        uint256 out = l.redeem(1_000_000e18, 0);
        assertEq(out, 1_000_000e18 * 3_100 / 10_000, "69% toll by default");
        assertEq(imdstr.balanceOf(holder) - before, out);

        vm.prank(OWNER);
        l.setRedeemOpen(false);
        vm.prank(OWNER);
        l.releaseImdstr(0, OWNER);
        assertEq(imdstr.balanceOf(OWNER), 2_000_000e18 - out);
    }
}
