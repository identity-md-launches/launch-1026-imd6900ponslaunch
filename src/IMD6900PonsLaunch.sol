// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPonsCurve, IPonsFactory, IPonsFeeEscrow, IPonsMemeHook, PonsSocials, PonsTokenParams} from "./IPons.sol";

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @title IMD6900PonsLaunch - launches Identity.MD 6900 (IMD6900) as a Pons coin on Robinhood Chain
/// @notice Deployed by the IMD swarm. Its constructor only writes down its owner, Pons and IMDSTR; it calls
///         nothing. Then:
///          1. the team sends it ETH (a plain transfer): the opening buy. Until the launch, {withdrawEth} sends any of
///             it back, so nothing is committed by sending. After it, every wei here is the coin's fees;
///          2. the owner may correct the brand ({setMeta}: Pons writes it into the coin for good) and mines the coin's
///             vanity address for THIS contract, which is the coin's deployer as far as Pons is concerned
///             (test/MineVanity.t.sol);
///          3. {launch}: Pons creates the coin and its curve, and this contract buys first with the ETH it holds,
///             before anyone else can trade a coin that didn't exist a moment earlier (as the coin's deployer it pays
///             no snipe tax). It refuses if the coin wouldn't land at the address the owner mined for.
///         The coin it buys backs a 1:1 swap for Robinhood's old IMDSTR ({claim}), as the Robinhood → Pons plan has it:
///         IMDSTR in, the coin out, never the other way unless the owner opens {redeem} (taxed). What the IMDSTR in
///         existence can't claim is the owner's to {release}: it can never reach coin an IMDSTR holder could claim.
///         IMDSTR moves only to and from Robinhood distributors, so claiming opens once the Robinhood timelock makes
///         this contract one.
///
///         It is also the coin's fee distributor. Pons pays the coin's creator fees (its 70% of the 1% base fee and the
///         whole 5.9% creator tax) to this contract and nothing else ({launch} forces it), and the perps pool and its
///         hook pay theirs in with {addFees}. {harvest} (anyone) pulls Pons' fees and splits all the ETH here to the
///         payees: the pot bridge (ETH to Ethereum's NFT pot, where it buys identity.md machines for the swarm), the
///         perps pool, ops. Otherwise, after the launch, ETH leaves only through the Robinhood timelock
///         ({recoverEth}): never straight to the owner.
contract IMD6900PonsLaunch is Ownable, ReentrancyGuard {
    IPonsFactory public immutable factory;
    /// @notice Robinhood's IMDSTR, the old token that swaps 1:1 for the coin
    address public immutable imdstr;
    /// @notice The Robinhood timelock: the one way ETH leaves after the launch other than {split} ({recoverEth}),
    ///         public for its whole delay
    address public immutable timelock;

    /// @notice The brand as it launched on Ethereum: Identity.MD 6900, IMD6900. {meta} launches with these until
    ///         the owner sets other details ({setMeta}); the creator fees go to the owner by default.
    string public constant NAME = "Identity.MD 6900";
    string public constant SYMBOL = "IMD6900";
    string public constant LOGO = "https://imd6900.pages.dev/logo.png";
    string public constant DESCRIPTION =
        "Identity.MD 6900 on Robinhood Chain: the identity.md machine strategy, the meme branch of the IMD swarm.";
    string public constant TWITTER = "https://x.com/IMD6900";
    string public constant WEBSITE = "https://imd6900.pages.dev";
    /// @notice Pons' 1% base fee plus this: 6.9% all in, the Ethereum pool's rate. Permanent once launched.
    uint16 public constant CREATOR_TAX_BPS = 590;
    /// @notice The most creator tax {setMeta} accepts (Pons' own cap)
    uint16 public constant MAX_CREATOR_TAX_BPS = 1_000;
    /// @notice {redeem}'s toll never exceeds this: a redeem always returns something
    uint16 public constant MAX_REDEEM_TAX_BPS = 9_000;

    /// @notice PonsPotBridge on Robinhood: takes ETH and bridges it (Across) to the Ethereum launch hook, which feeds
    ///         IMD6900's NFT pot. The default payees: 70% there, 30% the owner (ops), until the owner sets the perps
    ///         pool in (the plan: 70% pot, 10% perps, 20% ops).
    address public constant POT_BRIDGE = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    uint16 public constant POT_BPS = 7_000;
    uint256 public constant MAX_PAYEES = 8;

    /// @notice Pons launch config 0: 1B supply, 1% curve fee, graduation at 4.2 ETH
    uint256 public launchConfigId;
    /// @dev The owner's details, once set; until then {meta} is the brand above
    PonsTokenParams internal _meta;
    bool public metaSet;

    /// @notice The coin and its curve, once launched
    address public pons;
    address public curve;
    /// @notice ETH the opening buy spent, and the coin it landed
    uint256 public launchEth;
    uint256 public launchBought;

    /// @dev The owner's payees once set (fixed-size: no hashed storage slots); until then the default above
    address[8] internal _payees;
    uint16[8] internal _shares;
    uint8 internal _payeeCount;

    bool public redeemOpen;
    /// @notice Taken off a {redeem}: the toll on the road home to Ethereum (IMDSTR bridges, the coin doesn't)
    uint16 public redeemTaxBps = 6_900;
    /// @notice IMDSTR swapped in and out since the launch
    uint256 public claimed;
    uint256 public redeemed;

    event MetaSet(string name, string symbol, string logo, uint16 creatorTaxBps, address creatorFeeRecipient);
    event LaunchConfigSet(uint256 launchConfigId);
    event EthWithdrawn(address to, uint256 amount);
    event Launched(address pons, address curve, uint256 ethSpent, uint256 bought);
    event Claimed(address indexed account, uint256 amount);
    event Redeemed(address indexed account, uint256 amountIn, uint256 imdstrOut, uint256 tax);
    event Released(address to, uint256 amount);
    event ImdstrReleased(address to, uint256 amount);
    event RedeemOpenSet(bool open);
    event RedeemTaxSet(uint16 bps);
    event FeesReceived(address indexed from, uint256 amount);
    event Collected(uint256 eth);
    event SweepFailed(bytes reason);
    event Split(uint256 amount);
    event PayFailed(address payee, uint256 amount);
    event PayeesSet(address[] payees, uint16[] shares);
    event HandedOff(address newRecipient);
    event EthRecovered(address to, uint256 amount);

    error AlreadyLaunched();
    error NotLaunched();
    error BadMeta();
    error TaxTooHigh();
    error NoEth();
    error NotWhereMined(address token);
    error ZeroAmount();
    error RedeemClosed();
    error RedeemIsOpen();
    error Short();
    /// @notice More than what IMDSTR holders can't claim
    error Reserved();
    error BadPayees();
    error NotTimelock();

    /// @dev Writes nothing but the owner and three addresses (no strings: their storage slots would sit in the
    ///      creation code as raw data, which reads as instructions to a code scan)
    constructor(address owner_, address factory_, address imdstr_, address timelock_) {
        _initializeOwner(owner_);
        factory = IPonsFactory(factory_);
        imdstr = imdstr_;
        timelock = timelock_;
    }

    /// @notice Before the launch, the opening buy's ETH (anyone may send it, only the owner can take it back with
    ///         {withdrawEth}); after it, fees: Pons' escrow pays its claims here
    receive() external payable {}

    /// @notice The perps pool's and its hook's fees (they call their fee sink's addFees)
    function addFees() external payable {
        emit FeesReceived(msg.sender, msg.value);
    }

    /// @notice The coin's details as they would launch now (the salt comes with {launch}): the owner's if set,
    ///         else the brand. The creator fees go to this contract either way, the fee distributor.
    function meta() public view returns (PonsTokenParams memory m) {
        if (metaSet) {
            m = _meta;
        } else {
            m.name = NAME;
            m.symbol = SYMBOL;
            m.logo = LOGO;
            m.description = DESCRIPTION;
            m.socials = PonsSocials(TWITTER, "", "", WEBSITE, "");
            m.creatorTaxBps = CREATOR_TAX_BPS;
        }
        m.creatorFeeRecipient = address(this);
        m.buybackEnabled = false; // the fees come out as ETH
    }

    /// @notice Who the fees are split to, and their shares in basis points
    function payees() public view returns (address[] memory to, uint16[] memory bps) {
        uint256 n = _payeeCount;
        if (n == 0) {
            (to, bps) = (new address[](2), new uint16[](2));
            (to[0], bps[0], to[1], bps[1]) = (POT_BRIDGE, POT_BPS, owner(), 10_000 - POT_BPS);
            return (to, bps);
        }
        (to, bps) = (new address[](n), new uint16[](n));
        for (uint256 i; i < n; ++i) (to[i], bps[i]) = (_payees[i], _shares[i]);
    }

    /*                                 OWNER                                */

    /// @notice Sends ETH held here to `to` (all of it with 0): the way out of a launch the team decides against.
    ///         Before the launch only: after it, the ETH here is the coin's fees and leaves through {split}, or
    ///         through the timelock's {recoverEth}.
    function withdrawEth(address to, uint256 amount) external onlyOwner nonReentrant {
        if (pons != address(0)) revert AlreadyLaunched();
        if (amount == 0) amount = address(this).balance;
        if (amount == 0) revert NoEth();
        SafeTransferLib.safeTransferETH(to, amount);
        emit EthWithdrawn(to, amount);
    }

    /// @notice Corrects the coin's details before the launch. Pons writes them into the coin and nothing can change
    ///         them after; they are also part of what the vanity salt is mined for, so mine again after any change.
    function setMeta(PonsTokenParams calldata m) external onlyOwner {
        if (pons != address(0)) revert AlreadyLaunched();
        if (bytes(m.name).length == 0 || bytes(m.symbol).length == 0) revert BadMeta();
        if (m.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert TaxTooHigh();
        _meta = m;
        metaSet = true;
        emit MetaSet(m.name, m.symbol, m.logo, m.creatorTaxBps, address(this));
    }

    function setLaunchConfig(uint256 id) external onlyOwner {
        if (pons != address(0)) revert AlreadyLaunched();
        launchConfigId = id;
        emit LaunchConfigSet(id);
    }

    /// @notice Launches the coin and buys first with `buyEth` of the ETH held here (all of it with 0, the ETH sent
    ///         with this call included); any ETH left over goes back to the owner, so what comes here afterwards is
    ///         fees only. Reverts unless the coin lands at `expectedToken` (zero: anywhere), so a salt mined for other
    ///         details can never launch a coin at the wrong address.
    /// @param minTokensOut the opening buy's floor
    function launch(bytes32 salt, address expectedToken, uint256 buyEth, uint256 minTokensOut)
        external
        payable
        onlyOwner
        nonReentrant
        returns (address token, uint256 bought)
    {
        if (pons != address(0)) revert AlreadyLaunched();
        PonsTokenParams memory p = meta(); // the creator fees to this contract, buyback off
        p.salt = salt;
        if (p.expectedEconomics == bytes32(0)) p.expectedEconomics = factory.previewLaunchEconomics(launchConfigId, address(0));
        uint256 fee = factory.launchFee();
        address curve_;
        (token, curve_) = factory.launchToken{value: fee}(p, launchConfigId, address(0));
        if (expectedToken != address(0) && token != expectedToken) revert NotWhereMined(token);
        (pons, curve) = (token, curve_);

        uint256 spend = buyEth == 0 ? address(this).balance : buyEth;
        if (spend == 0 || spend > address(this).balance) revert NoEth();
        bought = IPonsCurve(curve_).buy{value: spend}(spend, minTokensOut, address(this));
        (launchEth, launchBought) = (spend, bought);
        if (address(this).balance != 0) SafeTransferLib.safeTransferETH(owner(), address(this).balance);
        emit Launched(token, curve_, spend, bought);
    }

    /// @notice Sets who the fees are split to: up to {MAX_PAYEES}, shares in basis points summing to 10,000. The perps
    ///         pool joins here once it exists.
    function setPayees(address[] calldata to, uint16[] calldata bps) external onlyOwner {
        uint256 n = to.length;
        if (n == 0 || n > MAX_PAYEES || n != bps.length) revert BadPayees();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (to[i] == address(0)) revert BadPayees();
            (_payees[i], _shares[i]) = (to[i], bps[i]);
            sum += bps[i];
        }
        if (sum != 10_000) revert BadPayees();
        _payeeCount = uint8(n);
        emit PayeesSet(to, bps);
    }

    /// @notice Hands the coin's creator fees to another recipient for good (a successor distributor). Harvest first:
    ///         what Pons' escrow already holds for this contract stays claimable here.
    function handOff(address newRecipient) external onlyOwner {
        if (pons == address(0)) revert NotLaunched();
        factory.transferCreatorFeeRecipient(pons, newRecipient);
        emit HandedOff(newRecipient);
    }

    /*                        THE ROBINHOOD TIMELOCK                        */

    /// @notice Sends ETH held here to `to` (all of it with 0), at any time: the escape hatch for the fees after the
    ///         launch (a payee that refused its share, a split the team wants to stop), behind the timelock's delay.
    function recoverEth(address to, uint256 amount) external nonReentrant {
        if (msg.sender != timelock) revert NotTimelock();
        if (amount == 0) amount = address(this).balance;
        if (amount == 0) revert NoEth();
        SafeTransferLib.safeTransferETH(to, amount);
        emit EthRecovered(to, amount);
    }

    /*                         THE FEE DISTRIBUTOR                         */

    /// @notice Books the coin's pending fees into Pons' escrow and claims this contract's ETH from it. Before
    ///         graduation the curve holds them; after, the meme hook, for `graduatedPoolId` (the graduated pool's id;
    ///         ignored before). A sweep that can't run doesn't stop the claim. Anyone.
    function collect(bytes32 graduatedPoolId) public nonReentrant returns (uint256 got) {
        address c = curve;
        if (c == address(0)) revert NotLaunched();
        if (!IPonsCurve(c).graduated()) {
            try IPonsCurve(c).sweepFees(0) {} catch (bytes memory reason) { emit SweepFailed(reason); }
        } else if (graduatedPoolId != bytes32(0)) {
            try IPonsMemeHook(factory.memeHook()).sweepPoolFees(graduatedPoolId, 0, 0) {}
            catch (bytes memory reason) { emit SweepFailed(reason); }
        }
        IPonsFeeEscrow escrow = IPonsFeeEscrow(factory.feeEscrow());
        if (escrow.balanceOf(address(this)) != 0) got = escrow.claim();
        emit Collected(got);
    }

    /// @notice Pays all the ETH here to the payees, pro rata. After the launch only (before it, the ETH is the opening
    ///         buy's). A payee that refuses its share leaves it here for the next split. Anyone.
    function split() public nonReentrant returns (uint256 amount) {
        if (pons == address(0)) revert NotLaunched();
        amount = address(this).balance;
        if (amount == 0) return 0;
        (address[] memory to, uint16[] memory bps) = payees();
        for (uint256 i; i < to.length; ++i) {
            uint256 part = (amount * bps[i]) / 10_000;
            if (part == 0) continue;
            (bool ok,) = to[i].call{value: part}("");
            if (!ok) emit PayFailed(to[i], part);
        }
        emit Split(amount);
    }

    /// @notice {collect} then {split}: Pons' fees to the pot, the perps pool and ops in one call. Anyone.
    function harvest(bytes32 graduatedPoolId) external returns (uint256) {
        collect(graduatedPoolId);
        return split();
    }

    /// @notice The coin beyond what all the IMDSTR outside this contract could claim: the owner's
    function releasable() public view returns (uint256) {
        if (pons == address(0)) return 0;
        uint256 held = SafeTransferLib.balanceOf(pons, address(this));
        uint256 owed = IERC20Supply(imdstr).totalSupply() - SafeTransferLib.balanceOf(imdstr, address(this));
        return held > owed ? held - owed : 0;
    }

    /// @notice Sends `amount` of the coin no IMDSTR holder can claim (all of it with 0) to `to`: the perps pool's seed,
    ///         or the team's
    function release(uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 free = releasable();
        if (amount == 0) amount = free;
        if (amount == 0 || amount > free) revert Reserved();
        SafeTransferLib.safeTransfer(pons, to, amount);
        emit Released(to, amount);
    }

    /// @notice Sells `amount` of the releasable coin into its curve and sends the ETH to `to`
    function releaseAsEth(uint256 amount, uint256 minEthOut, address to) external onlyOwner nonReentrant returns (uint256 out) {
        uint256 free = releasable();
        if (amount == 0) amount = free;
        if (amount == 0 || amount > free) revert Reserved();
        SafeTransferLib.safeApprove(pons, curve, amount);
        out = IPonsCurve(curve).sell(amount, minEthOut, to);
        SafeTransferLib.safeApprove(pons, curve, 0);
        emit Released(to, amount);
    }

    /// @notice Sends the IMDSTR collected by claims to `to` (all of it with 0) while {redeem} is closed: on Ethereum it
    ///         is IMD6900 again. Claims never need it (they pay out the coin), only {redeem} does.
    function releaseImdstr(uint256 amount, address to) external onlyOwner nonReentrant {
        if (redeemOpen) revert RedeemIsOpen();
        uint256 held = SafeTransferLib.balanceOf(imdstr, address(this));
        if (amount == 0) amount = held;
        if (amount == 0 || amount > held) revert Reserved();
        SafeTransferLib.safeTransfer(imdstr, to, amount);
        emit ImdstrReleased(to, amount);
    }

    function setRedeemOpen(bool open) external onlyOwner {
        redeemOpen = open;
        emit RedeemOpenSet(open);
    }

    /// @notice Start it above the gap between the coin's price and IMD6900's on Ethereum, so the round trip never
    ///         pays, and lower it as the two converge
    function setRedeemTaxBps(uint16 bps) external onlyOwner {
        if (bps > MAX_REDEEM_TAX_BPS) revert TaxTooHigh();
        redeemTaxBps = bps;
        emit RedeemTaxSet(bps);
    }

    /*                                ANYONE                                */

    /// @notice IMDSTR in, the coin out, 1:1 (approve IMDSTR first). The IMDSTR stays here.
    function claim(uint256 amount) external nonReentrant {
        if (pons == address(0)) revert NotLaunched();
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(imdstr, msg.sender, address(this), amount);
        SafeTransferLib.safeTransfer(pons, msg.sender, amount);
        claimed += amount;
        emit Claimed(msg.sender, amount);
    }

    /// @notice The coin in, IMDSTR out less {redeemTaxBps}, while the owner keeps it open (approve the coin first)
    function redeem(uint256 amount, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (!redeemOpen) revert RedeemClosed();
        if (amount == 0) revert ZeroAmount();
        uint256 tax = (amount * redeemTaxBps) / 10_000;
        out = amount - tax;
        if (out < minOut) revert Short();
        SafeTransferLib.safeTransferFrom(pons, msg.sender, address(this), amount);
        SafeTransferLib.safeTransfer(imdstr, msg.sender, out);
        redeemed += out;
        emit Redeemed(msg.sender, amount, out, tax);
    }
}
