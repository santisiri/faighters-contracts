// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FaightersEscrow} from "../src/FaightersEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract FaightersEscrowTest is Test {
    FaightersEscrow internal escrow;

    MockERC20 internal usdc;
    MockERC20 internal sairi;
    MockSwapRouter internal router;

    address internal owner;
    address internal resolver;
    address internal playerA;
    address internal playerB;
    address internal attacker;

    uint256 internal constant STAKE_USDC = 100e6;
    uint256 internal constant STAKE_SAIRI = 100 ether;
    uint256 internal constant START_USDC = 1_000e6;
    uint256 internal constant START_SAIRI = 1_000 ether;

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

        usdc = MockERC20(escrow.USDC());
        sairi = MockERC20(escrow.SAIRI());

        MockSwapRouter routerImplementation = new MockSwapRouter();
        vm.etch(escrow.SWAP_ROUTER(), address(routerImplementation).code);
        router = MockSwapRouter(escrow.SWAP_ROUTER());

        usdc.mint(playerA, START_USDC);
        usdc.mint(playerB, START_USDC);
        sairi.mint(playerA, START_SAIRI);
        sairi.mint(playerB, START_SAIRI);
    }

    function testCreateFight() external {
        bytes32 fightId = _fightId("create");

        _approveToken(address(usdc), playerA, STAKE_USDC);
        vm.prank(playerA);
        escrow.createFight(fightId, address(usdc), STAKE_USDC);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.fightId, fightId);
        assertEq(fight.tokenUsed, address(usdc));
        assertEq(fight.stakeAmount, STAKE_USDC);
        assertEq(fight.playerA, playerA);
        assertEq(fight.playerB, address(0));
        assertTrue(fight.playerAStaked);
        assertFalse(fight.playerBStaked);
        assertFalse(fight.resolved);
        assertEq(fight.winner, address(0));
        assertEq(usdc.balanceOf(address(escrow)), STAKE_USDC);
    }

    function testJoinFight() external {
        bytes32 fightId = _fightId("join");
        _createAndJoin(fightId, address(usdc), STAKE_USDC);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertEq(fight.playerB, playerB);
        assertTrue(fight.playerBStaked);
        assertEq(usdc.balanceOf(address(escrow)), STAKE_USDC * 2);
    }

    function testResolveFightSairiBurnPath() external {
        bytes32 fightId = _fightId("resolve-sairi");
        _createAndJoin(fightId, address(sairi), STAKE_SAIRI);

        uint256 totalPot = STAKE_SAIRI * 2;
        uint256 winnerPayout = (totalPot * 70) / 100;
        uint256 houseCut = totalPot - winnerPayout;

        uint256 winnerBefore = sairi.balanceOf(playerA);
        uint256 burnedBefore = sairi.balanceOf(escrow.BURN_ADDRESS());

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        assertEq(sairi.balanceOf(playerA), winnerBefore + winnerPayout);
        assertEq(sairi.balanceOf(escrow.BURN_ADDRESS()), burnedBefore + houseCut);
        assertEq(sairi.balanceOf(address(escrow)), 0);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
        assertEq(fight.winner, playerA);
    }

    function testResolveFightUsdcSwapAndBurnPath() external {
        bytes32 fightId = _fightId("resolve-usdc");
        _createAndJoin(fightId, address(usdc), STAKE_USDC);

        uint256 totalPot = STAKE_USDC * 2;
        uint256 winnerPayout = (totalPot * 70) / 100;
        uint256 houseCut = totalPot - winnerPayout;

        uint256 expectedSairiOut = 50 ether;
        router.setAmountOut(expectedSairiOut);
        sairi.mint(address(router), expectedSairiOut);

        uint256 winnerBefore = usdc.balanceOf(playerB);
        uint256 burnedBefore = sairi.balanceOf(escrow.BURN_ADDRESS());

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerB, (expectedSairiOut * 99) / 100);

        assertEq(usdc.balanceOf(playerB), winnerBefore + winnerPayout);
        assertEq(usdc.balanceOf(address(router)), houseCut);
        assertEq(sairi.balanceOf(escrow.BURN_ADDRESS()), burnedBefore + expectedSairiOut);
        assertEq(router.lastTokenIn(), address(usdc));
        assertEq(router.lastTokenOut(), address(sairi));
        assertEq(router.lastRecipient(), address(escrow));
        assertEq(router.lastAmountIn(), houseCut);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
        assertEq(fight.winner, playerB);
    }

    function testCancelBeforeJoinByPlayerA() external {
        bytes32 fightId = _fightId("cancel-before-join");

        uint256 playerABefore = usdc.balanceOf(playerA);
        _approveToken(address(usdc), playerA, STAKE_USDC);

        vm.prank(playerA);
        escrow.createFight(fightId, address(usdc), STAKE_USDC);

        vm.prank(playerA);
        escrow.cancelFight(fightId);

        assertEq(usdc.balanceOf(playerA), playerABefore);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
        assertEq(fight.winner, address(0));
    }

    function testCancelAfterJoinByResolver() external {
        bytes32 fightId = _fightId("cancel-after-join");

        uint256 playerABefore = usdc.balanceOf(playerA);
        uint256 playerBBefore = usdc.balanceOf(playerB);
        _createAndJoin(fightId, address(usdc), STAKE_USDC);

        vm.prank(resolver);
        escrow.cancelFight(fightId);

        assertEq(usdc.balanceOf(playerA), playerABefore);
        assertEq(usdc.balanceOf(playerB), playerBBefore);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
        assertEq(fight.winner, address(0));
    }

    function testDoubleStakePrevention() external {
        bytes32 fightId = _fightId("double-stake");

        _approveToken(address(usdc), playerA, STAKE_USDC * 2);

        vm.prank(playerA);
        escrow.createFight(fightId, address(usdc), STAKE_USDC);

        vm.expectRevert(abi.encodeWithSelector(FaightersEscrow.FightAlreadyExists.selector, fightId));
        vm.prank(playerA);
        escrow.createFight(fightId, address(usdc), STAKE_USDC);
    }

    function testUnauthorizedResolveAttempt() external {
        bytes32 fightId = _fightId("unauthorized-resolve");
        _createAndJoin(fightId, address(sairi), STAKE_SAIRI);

        vm.expectRevert(FaightersEscrow.ResolverOnly.selector);
        vm.prank(attacker);
        escrow.resolveFight(fightId, playerA);
    }

    function _createAndJoin(bytes32 fightId, address token, uint256 stake) internal {
        _approveToken(token, playerA, stake);
        vm.prank(playerA);
        escrow.createFight(fightId, token, stake);

        _approveToken(token, playerB, stake);
        vm.prank(playerB);
        escrow.joinFight(fightId);
    }

    function _approveToken(address token, address account, uint256 amount) internal {
        vm.prank(account);
        IERC20(token).approve(address(escrow), amount);
    }

    function _fightId(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }
}
