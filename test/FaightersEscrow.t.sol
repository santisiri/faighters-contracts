// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FaightersEscrow} from "../src/FaightersEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract FaightersEscrowTest is Test {
    event ResolverUpdated(address indexed previousResolver, address indexed newResolver);
    event HouseFeeConfigUpdated(
        uint256 indexed previousOwnerFeeBps,
        uint256 indexed previousResolverFeeBps,
        uint256 newOwnerFeeBps,
        uint256 newResolverFeeBps
    );
    event FightCreated(bytes32 indexed fightId, address indexed playerA, address indexed token, uint256 stakeAmount);
    event FightJoined(bytes32 indexed fightId, address indexed playerB);
    event HouseFeesDistributed(
        bytes32 indexed fightId,
        address indexed tokenUsed,
        uint256 ownerFeeAmount,
        uint256 resolverFeeAmount,
        uint256 burnInputAmount
    );
    event FightResolved(
        bytes32 indexed fightId,
        address indexed winner,
        address indexed tokenUsed,
        uint256 winnerPayout,
        uint256 houseCutInput,
        uint256 sairiBurned
    );
    event FightCancelled(bytes32 indexed fightId, address indexed cancelledBy);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    FaightersEscrow internal escrow;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal sairi;
    MockSwapRouter internal router;

    address internal owner;
    address internal resolver;
    address internal playerA;
    address internal playerB;
    address internal attacker;

    uint256 internal constant STAKE_18 = 10 ether;
    uint256 internal constant STAKE_6 = 100e6;
    uint256 internal constant START_18 = 1_000 ether;
    uint256 internal constant START_6 = 10_000e6;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function setUp() external {
        owner = makeAddr("owner");
        resolver = makeAddr("resolver");
        playerA = makeAddr("playerA");
        playerB = makeAddr("playerB");
        attacker = makeAddr("attacker");

        escrow = new FaightersEscrow(resolver, owner);

        MockERC20 tokenImplementation = new MockERC20("Mock", "MOCK");
        vm.etch(escrow.WETH(), address(tokenImplementation).code);
        vm.etch(escrow.USDC(), address(tokenImplementation).code);
        vm.etch(escrow.USDT(), address(tokenImplementation).code);
        vm.etch(escrow.SAIRI(), address(tokenImplementation).code);

        weth = MockERC20(escrow.WETH());
        usdc = MockERC20(escrow.USDC());
        usdt = MockERC20(escrow.USDT());
        sairi = MockERC20(escrow.SAIRI());

        MockSwapRouter routerImplementation = new MockSwapRouter();
        vm.etch(escrow.SWAP_ROUTER(), address(routerImplementation).code);
        router = MockSwapRouter(escrow.SWAP_ROUTER());

        _mintBaseBalances();
    }

    function testConstructorSetsOwnerAndResolver() external view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.resolver(), resolver);
    }

    function testConstructorSetsDefaultHouseFeeBps() external view {
        assertEq(escrow.ownerFeeBps(), escrow.DEFAULT_OWNER_FEE_BPS());
        assertEq(escrow.resolverFeeBps(), escrow.DEFAULT_RESOLVER_FEE_BPS());
    }

    function testConstructorRevertsOnZeroResolver() external {
        vm.expectRevert(FaightersEscrow.ZeroAddress.selector);
        new FaightersEscrow(address(0), owner);
    }

    function testSetResolverByOwner() external {
        address newResolver = makeAddr("newResolver");

        vm.expectEmit(true, true, false, false, address(escrow));
        emit ResolverUpdated(resolver, newResolver);

        vm.prank(owner);
        escrow.setResolver(newResolver);

        assertEq(escrow.resolver(), newResolver);
    }

    function testSetResolverRevertsForNonOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        escrow.setResolver(makeAddr("newResolver"));
    }

    function testSetResolverRevertsOnZeroAddress() external {
        vm.expectRevert(FaightersEscrow.ZeroAddress.selector);
        vm.prank(owner);
        escrow.setResolver(address(0));
    }

    function testSetHouseFeeBpsByOwner() external {
        uint256 newOwnerFeeBps = 750;
        uint256 newResolverFeeBps = 1250;

        vm.expectEmit(true, true, true, true, address(escrow));
        emit HouseFeeConfigUpdated(
            escrow.DEFAULT_OWNER_FEE_BPS(), escrow.DEFAULT_RESOLVER_FEE_BPS(), newOwnerFeeBps, newResolverFeeBps
        );

        vm.prank(owner);
        escrow.setHouseFeeBps(newOwnerFeeBps, newResolverFeeBps);

        assertEq(escrow.ownerFeeBps(), newOwnerFeeBps);
        assertEq(escrow.resolverFeeBps(), newResolverFeeBps);
    }

    function testSetHouseFeeBpsRevertsForNonOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        escrow.setHouseFeeBps(100, 100);
    }

    function testSetHouseFeeBpsRevertsWhenInvalidSplit() external {
        vm.expectRevert(FaightersEscrow.InvalidHouseFeeSplit.selector);
        vm.prank(owner);
        escrow.setHouseFeeBps(BPS_DENOMINATOR, 1);
    }

    function testPauseAndUnpauseByOwner() external {
        vm.prank(owner);
        escrow.pause();
        assertTrue(escrow.paused());

        vm.prank(owner);
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function testPauseRevertsForNonOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        escrow.pause();
    }

    function testUnpauseRevertsForNonOwner() external {
        vm.prank(owner);
        escrow.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        escrow.unpause();
    }

    function testPausedBlocksCreateJoinResolveAndCancel() external {
        bytes32 fightIdCreate = _fightId("paused-create");
        _approveToken(address(usdc), playerA, STAKE_6);

        vm.prank(owner);
        escrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(playerA);
        escrow.createFight(fightIdCreate, address(usdc), STAKE_6);

        vm.prank(owner);
        escrow.unpause();
        _createAndJoin(_fightId("paused-flow"), address(usdc), STAKE_6);
        bytes32 fightId = _fightId("paused-flow");

        vm.prank(owner);
        escrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA, 1);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(resolver);
        escrow.cancelFight(fightId);

        vm.prank(owner);
        escrow.unpause();

        bytes32 fightIdJoin = _fightId("paused-join");
        _createOnly(fightIdJoin, address(usdc), STAKE_6);
        vm.prank(owner);
        escrow.pause();

        _approveToken(address(usdc), playerB, STAKE_6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(playerB);
        escrow.joinFight(fightIdJoin);
    }

    function testCreateFightEmitsAndStoresState() external {
        bytes32 fightId = _fightId("create");
        _approveToken(address(usdc), playerA, STAKE_6);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FightCreated(fightId, playerA, address(usdc), STAKE_6);

        vm.prank(playerA);
        escrow.createFight(fightId, address(usdc), STAKE_6);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.fightId, fightId);
        assertEq(fight.tokenUsed, address(usdc));
        assertEq(fight.stakeAmount, STAKE_6);
        assertEq(fight.playerA, playerA);
        assertEq(fight.playerB, address(0));
        assertTrue(fight.playerAStaked);
        assertFalse(fight.playerBStaked);
        assertFalse(fight.resolved);
        assertEq(fight.winner, address(0));
        assertEq(usdc.balanceOf(address(escrow)), STAKE_6);
    }

    function testCreateFightForByResolverEmitsAndStoresState() external {
        bytes32 fightId = _fightId("create-for");
        _approveToken(address(usdc), playerA, STAKE_6);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FightCreated(fightId, playerA, address(usdc), STAKE_6);

        vm.prank(resolver);
        escrow.createFightFor(fightId, address(usdc), STAKE_6, playerA);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.playerA, playerA);
        assertEq(usdc.balanceOf(address(escrow)), STAKE_6);
        assertEq(escrow.reservedTokenBalance(address(usdc)), STAKE_6);
    }

    function testCreateFightWithDeadlinesStoresValues() external {
        bytes32 fightId = _fightId("create-deadlines");
        uint256 joinDeadline = block.timestamp + 1 days;
        uint256 resolveDeadline = block.timestamp + 2 days;

        _approveToken(address(usdc), playerA, STAKE_6);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(fightId, address(usdc), STAKE_6, joinDeadline, resolveDeadline);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.joinDeadline, joinDeadline);
        assertEq(fight.resolveDeadline, resolveDeadline);
    }

    function testCreateFightForRevertsForNonResolver() external {
        vm.expectRevert(FaightersEscrow.ResolverOnly.selector);
        vm.prank(attacker);
        escrow.createFightFor(_fightId("create-for-auth"), address(usdc), STAKE_6, playerA);
    }

    function testCreateFightForRevertsOnZeroPlayerA() external {
        vm.expectRevert(FaightersEscrow.ZeroAddress.selector);
        vm.prank(resolver);
        escrow.createFightFor(_fightId("create-for-zero"), address(usdc), STAKE_6, address(0));
    }

    function testCreateFightForWithDeadlinesByResolver() external {
        bytes32 fightId = _fightId("create-for-deadlines");
        uint256 joinDeadline = block.timestamp + 4 hours;
        uint256 resolveDeadline = block.timestamp + 9 hours;

        _approveToken(address(usdc), playerA, STAKE_6);
        vm.prank(resolver);
        escrow.createFightForWithDeadlines(fightId, address(usdc), STAKE_6, playerA, joinDeadline, resolveDeadline);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.playerA, playerA);
        assertEq(fight.joinDeadline, joinDeadline);
        assertEq(fight.resolveDeadline, resolveDeadline);
    }

    function testCreateFightWithDeadlinesRevertsWhenJoinDeadlineNotFuture() external {
        _approveToken(address(usdc), playerA, STAKE_6);
        vm.expectRevert(FaightersEscrow.InvalidDeadlineWindow.selector);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(
            _fightId("bad-join-deadline"), address(usdc), STAKE_6, block.timestamp, block.timestamp + 1 days
        );
    }

    function testCreateFightWithDeadlinesRevertsWhenResolveDeadlineNotFuture() external {
        _approveToken(address(usdc), playerA, STAKE_6);
        vm.expectRevert(FaightersEscrow.InvalidDeadlineWindow.selector);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(
            _fightId("bad-resolve-deadline"), address(usdc), STAKE_6, block.timestamp + 1 days, block.timestamp
        );
    }

    function testCreateFightWithDeadlinesRevertsWhenResolveNotAfterJoin() external {
        _approveToken(address(usdc), playerA, STAKE_6);
        vm.expectRevert(FaightersEscrow.InvalidDeadlineWindow.selector);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(
            _fightId("bad-window-order"), address(usdc), STAKE_6, block.timestamp + 2 days, block.timestamp + 1 days
        );
    }

    function testCreateFightRevertsWithZeroFightId() external {
        _approveToken(address(usdc), playerA, STAKE_6);
        vm.expectRevert(FaightersEscrow.InvalidFightId.selector);
        vm.prank(playerA);
        escrow.createFight(bytes32(0), address(usdc), STAKE_6);
    }

    function testCreateFightRevertsWithUnsupportedToken() external {
        address unsupported = makeAddr("unsupportedToken");
        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.UnsupportedToken.selector, unsupported));
        vm.prank(playerA);
        escrow.createFight(_fightId("unsupported"), unsupported, STAKE_6);
    }

    function testCreateFightRevertsWithZeroStake() external {
        vm.expectRevert(FaightersEscrow.InvalidStakeAmount.selector);
        vm.prank(playerA);
        escrow.createFight(_fightId("zero-stake"), address(usdc), 0);
    }

    function testCreateFightRevertsWithoutAllowance() external {
        vm.expectRevert();
        vm.prank(playerA);
        escrow.createFight(_fightId("allowance-missing"), address(usdc), STAKE_6);
    }

    function testCreateFightRevertsWhenFightAlreadyExists() external {
        bytes32 fightId = _fightId("dup-create");
        _approveToken(address(usdc), playerA, STAKE_6 * 2);

        vm.startPrank(playerA);
        escrow.createFight(fightId, address(usdc), STAKE_6);
        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightAlreadyExists.selector, fightId));
        escrow.createFight(fightId, address(usdc), STAKE_6);
        vm.stopPrank();
    }

    function testCreateFightSupportsAllAllowedTokens() external {
        bytes32 wethFight = _fightId("weth");
        bytes32 usdcFight = _fightId("usdc");
        bytes32 usdtFight = _fightId("usdt");
        bytes32 sairiFight = _fightId("sairi");

        _approveToken(address(weth), playerA, STAKE_18);
        vm.prank(playerA);
        escrow.createFight(wethFight, address(weth), STAKE_18);

        _approveToken(address(usdc), playerA, STAKE_6);
        vm.prank(playerA);
        escrow.createFight(usdcFight, address(usdc), STAKE_6);

        _approveToken(address(usdt), playerA, STAKE_6);
        vm.prank(playerA);
        escrow.createFight(usdtFight, address(usdt), STAKE_6);

        _approveToken(address(sairi), playerA, STAKE_18);
        vm.prank(playerA);
        escrow.createFight(sairiFight, address(sairi), STAKE_18);
    }

    function testJoinFightEmitsAndStoresState() external {
        bytes32 fightId = _fightId("join");
        _createOnly(fightId, address(usdc), STAKE_6);
        _approveToken(address(usdc), playerB, STAKE_6);

        vm.expectEmit(true, true, false, false, address(escrow));
        emit FightJoined(fightId, playerB);

        vm.prank(playerB);
        escrow.joinFight(fightId);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.playerB, playerB);
        assertTrue(fight.playerBStaked);
        assertEq(usdc.balanceOf(address(escrow)), STAKE_6 * 2);
    }

    function testJoinFightForByResolverEmitsAndStoresState() external {
        bytes32 fightId = _fightId("join-for");
        _createOnly(fightId, address(usdc), STAKE_6);
        _approveToken(address(usdc), playerB, STAKE_6);

        vm.expectEmit(true, true, false, false, address(escrow));
        emit FightJoined(fightId, playerB);

        vm.prank(resolver);
        escrow.joinFightFor(fightId, playerB);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.playerB, playerB);
        assertTrue(fight.playerBStaked);
        assertEq(usdc.balanceOf(address(escrow)), STAKE_6 * 2);
        assertEq(escrow.reservedTokenBalance(address(usdc)), STAKE_6 * 2);
    }

    function testJoinFightForRevertsForNonResolver() external {
        bytes32 fightId = _fightId("join-for-auth");
        _createOnly(fightId, address(usdc), STAKE_6);
        _approveToken(address(usdc), playerB, STAKE_6);

        vm.expectRevert(FaightersEscrow.ResolverOnly.selector);
        vm.prank(attacker);
        escrow.joinFightFor(fightId, playerB);
    }

    function testJoinFightForRevertsOnZeroPlayerB() external {
        bytes32 fightId = _fightId("join-for-zero");
        _createOnly(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.ZeroAddress.selector);
        vm.prank(resolver);
        escrow.joinFightFor(fightId, address(0));
    }

    function testJoinFightRevertsWhenFightMissing() external {
        bytes32 fightId = _fightId("missing-join");
        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightNotFound.selector, fightId));
        vm.prank(playerB);
        escrow.joinFight(fightId);
    }

    function testJoinFightRevertsWhenSameAsPlayerA() external {
        bytes32 fightId = _fightId("join-self");
        _createOnly(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.CannotJoinOwnFight.selector);
        vm.prank(playerA);
        escrow.joinFight(fightId);
    }

    function testJoinFightRevertsWhenAlreadyJoined() external {
        bytes32 fightId = _fightId("already-joined");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.AlreadyJoined.selector, fightId));
        vm.prank(makeAddr("lateJoiner"));
        escrow.joinFight(fightId);
    }

    function testJoinFightRevertsWithoutAllowance() external {
        bytes32 fightId = _fightId("join-allowance");
        _createOnly(fightId, address(usdc), STAKE_6);

        vm.expectRevert();
        vm.prank(playerB);
        escrow.joinFight(fightId);
    }

    function testJoinFightRevertsAfterFightCancelled() external {
        bytes32 fightId = _fightId("join-after-cancel");
        _createOnly(fightId, address(usdc), STAKE_6);

        vm.prank(resolver);
        escrow.cancelFight(fightId);

        _approveToken(address(usdc), playerB, STAKE_6);
        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightResolvedAlready.selector, fightId));
        vm.prank(playerB);
        escrow.joinFight(fightId);
    }

    function testJoinFightRevertsWhenJoinDeadlinePassed() external {
        bytes32 fightId = _fightId("join-deadline-expired");
        uint256 joinDeadline = block.timestamp + 1;
        uint256 resolveDeadline = block.timestamp + 1 days;

        _approveToken(address(usdc), playerA, STAKE_6);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(fightId, address(usdc), STAKE_6, joinDeadline, resolveDeadline);

        vm.warp(joinDeadline + 1);
        _approveToken(address(usdc), playerB, STAKE_6);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.JoinDeadlinePassed.selector, fightId, joinDeadline));
        vm.prank(playerB);
        escrow.joinFight(fightId);
    }

    function testJoinFightAtExactJoinDeadlineSucceeds() external {
        bytes32 fightId = _fightId("join-at-deadline");
        uint256 joinDeadline = block.timestamp + 100;

        _approveToken(address(usdc), playerA, STAKE_6);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(fightId, address(usdc), STAKE_6, joinDeadline, block.timestamp + 1 days);

        vm.warp(joinDeadline);
        _approveToken(address(usdc), playerB, STAKE_6);
        vm.prank(playerB);
        escrow.joinFight(fightId);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.playerB, playerB);
        assertTrue(fight.playerBStaked);
    }

    function testResolveFightSairiPathPaysWinnerBurnsAndEmits() external {
        bytes32 fightId = _fightId("resolve-sairi");
        _createAndJoin(fightId, address(sairi), STAKE_18);

        assertEq(escrow.reservedTokenBalance(address(sairi)), STAKE_18 * 2);

        uint256 totalPot = STAKE_18 * 2;
        uint256 winnerPayout = (totalPot * escrow.WINNER_PCT()) / 100;
        uint256 houseCut = totalPot - winnerPayout;
        uint256 ownerFeeAmount = _ownerFee(houseCut);
        uint256 resolverFeeAmount = _resolverFee(houseCut);
        uint256 burnInputAmount = houseCut - ownerFeeAmount - resolverFeeAmount;
        uint256 winnerBefore = sairi.balanceOf(playerA);
        uint256 burnBefore = sairi.balanceOf(escrow.BURN_ADDRESS());
        uint256 ownerBefore = sairi.balanceOf(owner);
        uint256 resolverBefore = sairi.balanceOf(resolver);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit HouseFeesDistributed(fightId, address(sairi), ownerFeeAmount, resolverFeeAmount, burnInputAmount);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FightResolved(fightId, playerA, address(sairi), winnerPayout, houseCut, burnInputAmount);

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        assertEq(sairi.balanceOf(playerA), winnerBefore + winnerPayout);
        assertEq(sairi.balanceOf(escrow.BURN_ADDRESS()), burnBefore + burnInputAmount);
        assertEq(sairi.balanceOf(owner), ownerBefore + ownerFeeAmount);
        assertEq(sairi.balanceOf(resolver), resolverBefore + resolverFeeAmount);
        assertEq(sairi.balanceOf(address(escrow)), 0);
        assertEq(escrow.reservedTokenBalance(address(sairi)), 0);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
        assertEq(fight.winner, playerA);
    }

    function testResolveFightSairiPathAllowsPlayerBAsWinner() external {
        bytes32 fightId = _fightId("resolve-sairi-b");
        _createAndJoin(fightId, address(sairi), STAKE_18);

        uint256 winnerBefore = sairi.balanceOf(playerB);
        uint256 totalPot = STAKE_18 * 2;
        uint256 winnerPayout = (totalPot * escrow.WINNER_PCT()) / 100;

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerB);

        assertEq(sairi.balanceOf(playerB), winnerBefore + winnerPayout);
    }

    function testResolveFightRevertsWhenNotReady() external {
        bytes32 fightId = _fightId("resolve-not-ready");
        _createOnly(fightId, address(sairi), STAKE_18);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightNotReady.selector, fightId));
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);
    }

    function testResolveFightRevertsWhenWinnerInvalid() external {
        bytes32 fightId = _fightId("resolve-invalid-winner");
        _createAndJoin(fightId, address(sairi), STAKE_18);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.InvalidWinner.selector, attacker));
        vm.prank(resolver);
        escrow.resolveFight(fightId, attacker);
    }

    function testResolveFightRevertsWhenCallerNotResolverTwoArg() external {
        bytes32 fightId = _fightId("resolve-auth-2arg");
        _createAndJoin(fightId, address(sairi), STAKE_18);

        vm.expectRevert(FaightersEscrow.ResolverOnly.selector);
        vm.prank(attacker);
        escrow.resolveFight(fightId, playerA);
    }

    function testResolveFightRevertsWhenCallerNotResolverThreeArg() external {
        bytes32 fightId = _fightId("resolve-auth-3arg");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.ResolverOnly.selector);
        vm.prank(attacker);
        escrow.resolveFight(fightId, playerA, 1);
    }

    function testResolveFightRevertsWhenFightMissing() external {
        bytes32 fightId = _fightId("resolve-missing");
        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightNotFound.selector, fightId));
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);
    }

    function testResolveFightRevertsWhenAlreadyResolved() external {
        bytes32 fightId = _fightId("resolve-twice");
        _createAndJoin(fightId, address(sairi), STAKE_18);

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightResolvedAlready.selector, fightId));
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);
    }

    function testResolveFightRevertsWhenAlreadyCancelled() external {
        bytes32 fightId = _fightId("resolve-after-cancel");
        _createOnly(fightId, address(sairi), STAKE_18);

        vm.prank(resolver);
        escrow.cancelFight(fightId);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightResolvedAlready.selector, fightId));
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);
    }

    function testResolveFightRevertsWhenResolveDeadlinePassed() external {
        bytes32 fightId = _fightId("resolve-deadline-expired");
        uint256 joinDeadline = block.timestamp + 1 hours;
        uint256 resolveDeadline = block.timestamp + 2 hours;

        _approveToken(address(usdc), playerA, STAKE_6);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(fightId, address(usdc), STAKE_6, joinDeadline, resolveDeadline);

        _approveToken(address(usdc), playerB, STAKE_6);
        vm.prank(playerB);
        escrow.joinFight(fightId);

        vm.warp(resolveDeadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(FaightersEscrow.ResolveDeadlinePassed.selector, fightId, resolveDeadline)
        );
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA, 1);
    }

    function testResolveFightAtExactResolveDeadlineSucceeds() external {
        bytes32 fightId = _fightId("resolve-at-deadline");
        uint256 joinDeadline = block.timestamp + 100;
        uint256 resolveDeadline = block.timestamp + 200;

        _approveToken(address(sairi), playerA, STAKE_18);
        vm.prank(playerA);
        escrow.createFightWithDeadlines(fightId, address(sairi), STAKE_18, joinDeadline, resolveDeadline);

        vm.warp(joinDeadline);
        _approveToken(address(sairi), playerB, STAKE_18);
        vm.prank(playerB);
        escrow.joinFight(fightId);

        vm.warp(resolveDeadline);
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
    }

    function testResolveFightSwapPathPaysWinnerSwapsBurnsAndEmits() external {
        bytes32 fightId = _fightId("resolve-usdc-swap");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        assertEq(escrow.reservedTokenBalance(address(usdc)), STAKE_6 * 2);

        uint256 totalPot = STAKE_6 * 2;
        uint256 winnerPayout = (totalPot * escrow.WINNER_PCT()) / 100;
        uint256 houseCut = totalPot - winnerPayout;
        uint256 ownerFeeAmount = _ownerFee(houseCut);
        uint256 resolverFeeAmount = _resolverFee(houseCut);
        uint256 burnInputAmount = houseCut - ownerFeeAmount - resolverFeeAmount;
        uint256 expectedSairiOut = 50 ether;
        uint256 minSairiOut = (expectedSairiOut * 99) / 100;
        uint256 winnerBefore = usdc.balanceOf(playerB);
        uint256 ownerBefore = usdc.balanceOf(owner);
        uint256 resolverBefore = usdc.balanceOf(resolver);
        uint256 burnBefore = sairi.balanceOf(escrow.BURN_ADDRESS());
        uint256 ts = block.timestamp;

        router.setAmountOut(expectedSairiOut);
        sairi.mint(address(router), expectedSairiOut);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit HouseFeesDistributed(fightId, address(usdc), ownerFeeAmount, resolverFeeAmount, burnInputAmount);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit FightResolved(fightId, playerB, address(usdc), winnerPayout, houseCut, expectedSairiOut);

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerB, minSairiOut);

        assertEq(usdc.balanceOf(playerB), winnerBefore + winnerPayout);
        assertEq(usdc.balanceOf(owner), ownerBefore + ownerFeeAmount);
        assertEq(usdc.balanceOf(resolver), resolverBefore + resolverFeeAmount);
        assertEq(usdc.balanceOf(address(router)), burnInputAmount);
        assertEq(sairi.balanceOf(escrow.BURN_ADDRESS()), burnBefore + expectedSairiOut);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.reservedTokenBalance(address(usdc)), 0);

        assertEq(router.lastTokenIn(), address(usdc));
        assertEq(router.lastTokenOut(), address(sairi));
        assertEq(router.lastRecipient(), address(escrow));
        assertEq(router.lastFee(), escrow.UNISWAP_POOL_FEE());
        assertEq(router.lastDeadline(), ts);
        assertEq(router.lastAmountIn(), burnInputAmount);
        assertEq(router.lastAmountOutMinimum(), minSairiOut);
        assertEq(router.lastSqrtPriceLimitX96(), 0);
    }

    function testResolveFightSwapPathRevertsWhenMinSairiOutZero() external {
        bytes32 fightId = _fightId("resolve-minout-zero");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.MinSairiOutRequired.selector);
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA, 0);
    }

    function testResolveFightSwapPathSkipsSwapWhenNoBurnInput() external {
        bytes32 fightId = _fightId("resolve-usdc-no-burn");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.prank(owner);
        escrow.setHouseFeeBps(5_000, 5_000);

        uint256 totalPot = STAKE_6 * 2;
        uint256 winnerPayout = (totalPot * escrow.WINNER_PCT()) / 100;
        uint256 houseCut = totalPot - winnerPayout;
        uint256 ownerBefore = usdc.balanceOf(owner);
        uint256 resolverBefore = usdc.balanceOf(resolver);
        uint256 burnBefore = sairi.balanceOf(escrow.BURN_ADDRESS());
        uint256 routerBefore = usdc.balanceOf(address(router));

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        assertEq(usdc.balanceOf(owner), ownerBefore + (houseCut / 2));
        assertEq(usdc.balanceOf(resolver), resolverBefore + (houseCut / 2));
        assertEq(usdc.balanceOf(address(router)), routerBefore);
        assertEq(sairi.balanceOf(escrow.BURN_ADDRESS()), burnBefore);
        assertEq(escrow.reservedTokenBalance(address(usdc)), 0);
    }

    function testResolveFightTwoArgRevertsForNonSairiFight() external {
        bytes32 fightId = _fightId("resolve-2arg-usdc");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.MinSairiOutRequired.selector);
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertFalse(fight.resolved);
        assertEq(usdc.balanceOf(address(escrow)), STAKE_6 * 2);
    }

    function testResolveFightSwapPathRevertsOnSlippageAndRollsBack() external {
        bytes32 fightId = _fightId("resolve-slippage");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        uint256 expectedSairiOut = 5 ether;
        uint256 minSairiOut = 10 ether;
        router.setAmountOut(expectedSairiOut);
        sairi.mint(address(router), expectedSairiOut);

        uint256 winnerBefore = usdc.balanceOf(playerA);
        uint256 escrowBefore = usdc.balanceOf(address(escrow));
        uint256 routerBefore = usdc.balanceOf(address(router));

        vm.expectRevert(bytes("slippage"));
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA, minSairiOut);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertFalse(fight.resolved);
        assertEq(usdc.balanceOf(playerA), winnerBefore);
        assertEq(usdc.balanceOf(address(escrow)), escrowBefore);
        assertEq(usdc.balanceOf(address(router)), routerBefore);
        assertEq(escrow.reservedTokenBalance(address(usdc)), STAKE_6 * 2);
    }

    function testCancelFightByPlayerABeforeJoinRefundsAndEmits() external {
        bytes32 fightId = _fightId("cancel-playerA");
        _createOnly(fightId, address(usdc), STAKE_6);

        uint256 playerABefore = usdc.balanceOf(playerA);

        vm.expectEmit(true, true, false, false, address(escrow));
        emit FightCancelled(fightId, playerA);

        vm.prank(playerA);
        escrow.cancelFight(fightId);

        assertEq(usdc.balanceOf(playerA), playerABefore + STAKE_6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.reservedTokenBalance(address(usdc)), 0);
    }

    function testCancelFightByResolverBeforeJoinRefundsPlayerA() external {
        bytes32 fightId = _fightId("cancel-resolver-prejoin");
        _createOnly(fightId, address(usdc), STAKE_6);

        uint256 playerABefore = usdc.balanceOf(playerA);
        vm.prank(resolver);
        escrow.cancelFight(fightId);

        assertEq(usdc.balanceOf(playerA), playerABefore + STAKE_6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testCancelFightByResolverAfterJoinRefundsBoth() external {
        bytes32 fightId = _fightId("cancel-resolver-joined");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        uint256 playerABefore = usdc.balanceOf(playerA);
        uint256 playerBBefore = usdc.balanceOf(playerB);

        vm.prank(resolver);
        escrow.cancelFight(fightId);

        assertEq(usdc.balanceOf(playerA), playerABefore + STAKE_6);
        assertEq(usdc.balanceOf(playerB), playerBBefore + STAKE_6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.reservedTokenBalance(address(usdc)), 0);
    }

    function testCancelFightRevertsForUnauthorizedCaller() external {
        bytes32 fightId = _fightId("cancel-unauthorized");
        _createOnly(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.Unauthorized.selector);
        vm.prank(attacker);
        escrow.cancelFight(fightId);
    }

    function testCancelFightRevertsForPlayerAAfterJoin() external {
        bytes32 fightId = _fightId("cancel-playerA-after-join");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.expectRevert(FaightersEscrow.Unauthorized.selector);
        vm.prank(playerA);
        escrow.cancelFight(fightId);
    }

    function testCancelFightRevertsWhenFightMissing() external {
        bytes32 fightId = _fightId("cancel-missing");
        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightNotFound.selector, fightId));
        vm.prank(resolver);
        escrow.cancelFight(fightId);
    }

    function testCancelFightRevertsWhenAlreadyResolved() external {
        bytes32 fightId = _fightId("cancel-after-resolve");
        _createAndJoin(fightId, address(sairi), STAKE_18);

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightResolvedAlready.selector, fightId));
        vm.prank(resolver);
        escrow.cancelFight(fightId);
    }

    function testEmergencyWithdrawTransfersAllAndEmits() external {
        MockERC20 stuck = new MockERC20("Stuck", "STK");
        uint256 stuckAmount = 777 ether;
        stuck.mint(address(escrow), stuckAmount);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit EmergencyWithdraw(address(stuck), owner, stuckAmount);

        vm.prank(owner);
        escrow.emergencyWithdraw(address(stuck));

        assertEq(stuck.balanceOf(owner), stuckAmount);
        assertEq(stuck.balanceOf(address(escrow)), 0);
    }

    function testEmergencyWithdrawOnlyWithdrawsSurplusWithReservedLiabilities() external {
        bytes32 fightId = _fightId("withdraw-surplus");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        uint256 reserved = STAKE_6 * 2;
        uint256 surplus = 25e6;
        usdc.mint(address(escrow), surplus);

        assertEq(escrow.getWithdrawableSurplus(address(usdc)), surplus);
        assertEq(escrow.reservedTokenBalance(address(usdc)), reserved);

        vm.prank(owner);
        escrow.emergencyWithdraw(address(usdc));

        assertEq(usdc.balanceOf(owner), surplus);
        assertEq(usdc.balanceOf(address(escrow)), reserved);
        assertEq(escrow.getWithdrawableSurplus(address(usdc)), 0);
        assertEq(escrow.reservedTokenBalance(address(usdc)), reserved);
    }

    function testEmergencyWithdrawRevertsWhenNoSurplusAvailable() external {
        bytes32 fightId = _fightId("withdraw-no-surplus");
        _createAndJoin(fightId, address(usdc), STAKE_6);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.NoSurplusAvailable.selector, address(usdc)));
        vm.prank(owner);
        escrow.emergencyWithdraw(address(usdc));
    }

    function testEmergencyWithdrawRevertsForNonOwner() external {
        MockERC20 stuck = new MockERC20("Stuck", "STK");
        stuck.mint(address(escrow), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        escrow.emergencyWithdraw(address(stuck));
    }

    function testGetFightForUnknownIdReturnsDefaultStruct() external view {
        bytes32 fightId = _fightId("unknown");
        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);

        assertEq(fight.fightId, bytes32(0));
        assertEq(fight.tokenUsed, address(0));
        assertEq(fight.stakeAmount, 0);
        assertEq(fight.joinDeadline, 0);
        assertEq(fight.resolveDeadline, 0);
        assertEq(fight.playerA, address(0));
        assertEq(fight.playerB, address(0));
        assertFalse(fight.playerAStaked);
        assertFalse(fight.playerBStaked);
        assertFalse(fight.resolved);
        assertEq(fight.winner, address(0));
    }

    function testFuzzCreateFightStakeAmount(uint96 rawStake) external {
        uint256 stake = bound(uint256(rawStake), 1, 5_000_000e6);
        bytes32 fightId = keccak256(abi.encodePacked("fuzz-create", stake));

        usdc.mint(playerA, stake);
        _approveToken(address(usdc), playerA, stake);

        vm.prank(playerA);
        escrow.createFight(fightId, address(usdc), stake);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.stakeAmount, stake);
        assertEq(usdc.balanceOf(address(escrow)), stake);
        assertEq(escrow.reservedTokenBalance(address(usdc)), stake);
    }

    function testFuzzResolveSairiPayoutConservation(uint96 rawStake) external {
        uint256 stake = bound(uint256(rawStake), 1, 5_000 ether);
        bytes32 fightId = keccak256(abi.encodePacked("fuzz-resolve-sairi", stake));

        sairi.mint(playerA, stake);
        sairi.mint(playerB, stake);

        _createAndJoin(fightId, address(sairi), stake);

        uint256 totalPot = stake * 2;
        uint256 winnerBefore = sairi.balanceOf(playerA);
        uint256 burnBefore = sairi.balanceOf(escrow.BURN_ADDRESS());
        uint256 ownerBefore = sairi.balanceOf(owner);
        uint256 resolverBefore = sairi.balanceOf(resolver);

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        uint256 winnerDelta = sairi.balanceOf(playerA) - winnerBefore;
        uint256 burnDelta = sairi.balanceOf(escrow.BURN_ADDRESS()) - burnBefore;
        uint256 ownerDelta = sairi.balanceOf(owner) - ownerBefore;
        uint256 resolverDelta = sairi.balanceOf(resolver) - resolverBefore;

        assertEq(winnerDelta + burnDelta + ownerDelta + resolverDelta, totalPot);
        assertEq(sairi.balanceOf(address(escrow)), 0);
        assertEq(escrow.reservedTokenBalance(address(sairi)), 0);
    }

    function _ownerFee(uint256 houseCut) internal view returns (uint256) {
        return (houseCut * escrow.ownerFeeBps()) / BPS_DENOMINATOR;
    }

    function _resolverFee(uint256 houseCut) internal view returns (uint256) {
        return (houseCut * escrow.resolverFeeBps()) / BPS_DENOMINATOR;
    }

    function _createOnly(bytes32 fightId, address token, uint256 stake) internal {
        _approveToken(token, playerA, stake);
        vm.prank(playerA);
        escrow.createFight(fightId, token, stake);
    }

    function _createAndJoin(bytes32 fightId, address token, uint256 stake) internal {
        _createOnly(fightId, token, stake);
        _approveToken(token, playerB, stake);
        vm.prank(playerB);
        escrow.joinFight(fightId);
    }

    function _approveToken(address token, address account, uint256 amount) internal {
        vm.prank(account);
        IERC20(token).approve(address(escrow), amount);
    }

    function _mintBaseBalances() internal {
        weth.mint(playerA, START_18);
        weth.mint(playerB, START_18);
        usdc.mint(playerA, START_6);
        usdc.mint(playerB, START_6);
        usdt.mint(playerA, START_6);
        usdt.mint(playerB, START_6);
        sairi.mint(playerA, START_18);
        sairi.mint(playerB, START_18);
    }

    function _fightId(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }
}
