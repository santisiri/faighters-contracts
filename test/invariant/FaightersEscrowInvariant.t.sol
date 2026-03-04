// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FaightersEscrow} from "../../src/FaightersEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

contract FaightersEscrowHandler is Test {
    uint256 internal constant MAX_TRACKED_FIGHTS = 24;

    FaightersEscrow internal escrow;
    MockSwapRouter internal router;
    MockERC20 internal sairi;

    address internal owner;
    address internal resolver;
    address[] internal actors;

    bytes32[] internal trackedFightIds;
    uint256 internal nonce;

    constructor(FaightersEscrow escrow_, address owner_, address resolver_, address[] memory actors_) {
        escrow = escrow_;
        owner = owner_;
        resolver = resolver_;
        actors = actors_;

        router = MockSwapRouter(escrow.SWAP_ROUTER());
        sairi = MockERC20(escrow.SAIRI());
    }

    function createFight(uint256 actorSeed, uint8 tokenIndex, uint96 rawStake, uint8 mode) external {
        if (trackedFightIds.length >= MAX_TRACKED_FIGHTS) {
            return;
        }

        address playerA = _actorAt(actorSeed);
        address token = _tokenAt(tokenIndex);
        uint256 stake = bound(uint256(rawStake), 1, 5_000 ether);
        bytes32 fightId = keccak256(abi.encodePacked("inv-create", nonce++));

        MockERC20(token).mint(playerA, stake);
        vm.prank(playerA);
        IERC20(token).approve(address(escrow), type(uint256).max);

        if (mode % 2 == 0) {
            vm.prank(playerA);
            try escrow.createFight(fightId, token, stake) {
                trackedFightIds.push(fightId);
            } catch {}
            return;
        }

        uint256 joinDeadline = block.timestamp + 1 + (uint256(mode) % 1 days);
        uint256 resolveDeadline = joinDeadline + 1 + ((uint256(mode) * 3) % 2 days);
        vm.prank(playerA);
        try escrow.createFightWithDeadlines(fightId, token, stake, joinDeadline, resolveDeadline) {
            trackedFightIds.push(fightId);
        } catch {}
    }

    function createFightFor(uint256 actorSeed, uint8 tokenIndex, uint96 rawStake, uint8 mode) external {
        if (trackedFightIds.length >= MAX_TRACKED_FIGHTS) {
            return;
        }

        address playerA = _actorAt(actorSeed);
        address token = _tokenAt(tokenIndex);
        uint256 stake = bound(uint256(rawStake), 1, 5_000 ether);
        bytes32 fightId = keccak256(abi.encodePacked("inv-create-for", nonce++));

        MockERC20(token).mint(playerA, stake);
        vm.prank(playerA);
        IERC20(token).approve(address(escrow), type(uint256).max);

        if (mode % 2 == 0) {
            vm.prank(resolver);
            try escrow.createFightFor(fightId, token, stake, playerA) {
                trackedFightIds.push(fightId);
            } catch {}
            return;
        }

        uint256 joinDeadline = block.timestamp + 1 + (uint256(mode) % 1 days);
        uint256 resolveDeadline = joinDeadline + 1 + ((uint256(mode) * 5) % 2 days);
        vm.prank(resolver);
        try escrow.createFightForWithDeadlines(fightId, token, stake, playerA, joinDeadline, resolveDeadline) {
            trackedFightIds.push(fightId);
        } catch {}
    }

    function joinFight(uint256 fightSeed, uint256 actorSeed, uint8 mode) external {
        if (trackedFightIds.length == 0) {
            return;
        }

        bytes32 fightId = trackedFightIds[fightSeed % trackedFightIds.length];
        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        if (fight.playerA == address(0)) {
            return;
        }

        address playerB = _actorAt(actorSeed);
        if (playerB == fight.playerA) {
            playerB = _actorAt(actorSeed + 1);
        }

        MockERC20(fight.tokenUsed).mint(playerB, fight.stakeAmount);
        vm.prank(playerB);
        IERC20(fight.tokenUsed).approve(address(escrow), type(uint256).max);

        if (mode % 2 == 0) {
            vm.prank(playerB);
            try escrow.joinFight(fightId) {} catch {}
            return;
        }

        vm.prank(resolver);
        try escrow.joinFightFor(fightId, playerB) {} catch {}
    }

    function resolveFight(uint256 fightSeed, uint256 winnerSeed, uint8 mode) external {
        if (trackedFightIds.length == 0) {
            return;
        }

        bytes32 fightId = trackedFightIds[fightSeed % trackedFightIds.length];
        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        if (fight.playerA == address(0)) {
            return;
        }

        address winner;
        if (mode % 3 == 0) {
            winner = _actorAt(winnerSeed);
        } else if (mode % 2 == 0) {
            winner = fight.playerA;
        } else {
            winner = fight.playerB;
        }

        if (fight.tokenUsed == escrow.SAIRI()) {
            if (mode % 2 == 0) {
                vm.prank(resolver);
                try escrow.resolveFight(fightId, winner) {} catch {}
            } else {
                vm.prank(resolver);
                try escrow.resolveFight(fightId, winner, 1) {} catch {}
            }
            return;
        }

        uint256 totalPot = fight.stakeAmount * 2;
        uint256 winnerPayout = (totalPot * escrow.WINNER_PCT()) / 100;
        uint256 houseCut = totalPot - winnerPayout;
        uint256 expectedSairiOut = houseCut + 1;
        uint256 minOut;

        if (mode % 5 == 0) {
            minOut = 0;
        } else if (mode % 5 == 1) {
            minOut = expectedSairiOut + 1;
        } else {
            minOut = expectedSairiOut / 2;
        }

        router.setAmountOut(expectedSairiOut);
        sairi.mint(address(router), expectedSairiOut);

        vm.prank(resolver);
        try escrow.resolveFight(fightId, winner, minOut) {} catch {}
    }

    function cancelFight(uint256 fightSeed, uint256 callerSeed) external {
        if (trackedFightIds.length == 0) {
            return;
        }

        bytes32 fightId = trackedFightIds[fightSeed % trackedFightIds.length];
        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        if (fight.playerA == address(0)) {
            return;
        }

        address caller;
        uint256 mode = callerSeed % 3;
        if (mode == 0) {
            caller = resolver;
        } else if (mode == 1) {
            caller = fight.playerA;
        } else {
            caller = _actorAt(callerSeed);
        }

        vm.prank(caller);
        try escrow.cancelFight(fightId) {} catch {}
    }

    function pauseOrUnpause(uint256 callerSeed) external {
        address caller;
        if (callerSeed % 2 == 0) {
            caller = owner;
        } else {
            caller = _actorAt(callerSeed);
        }

        if (escrow.paused()) {
            vm.prank(caller);
            try escrow.unpause() {} catch {}
        } else {
            vm.prank(caller);
            try escrow.pause() {} catch {}
        }
    }

    function warp(uint256 delta) external {
        uint256 secondsForward = bound(delta, 1, 7 days);
        vm.warp(block.timestamp + secondsForward);
    }

    function trackedFightCount() external view returns (uint256) {
        return trackedFightIds.length;
    }

    function trackedFightIdAt(uint256 idx) external view returns (bytes32) {
        return trackedFightIds[idx];
    }

    function _actorAt(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _tokenAt(uint8 tokenIndex) internal view returns (address) {
        uint8 idx = tokenIndex % 4;
        if (idx == 0) {
            return escrow.WETH();
        }
        if (idx == 1) {
            return escrow.USDC();
        }
        if (idx == 2) {
            return escrow.USDT();
        }
        return escrow.SAIRI();
    }
}

contract FaightersEscrowInvariantTest is StdInvariant, Test {
    FaightersEscrow internal escrow;
    FaightersEscrowHandler internal handler;

    address internal owner;
    address internal resolver;

    address[] internal actors;
    address[] internal supportedTokens;

    function setUp() external {
        owner = makeAddr("invariant-owner");
        resolver = makeAddr("invariant-resolver");

        actors.push(makeAddr("invariant-actor-1"));
        actors.push(makeAddr("invariant-actor-2"));
        actors.push(makeAddr("invariant-actor-3"));
        actors.push(makeAddr("invariant-actor-4"));
        actors.push(makeAddr("invariant-actor-5"));

        escrow = new FaightersEscrow(resolver, owner);

        MockERC20 tokenImplementation = new MockERC20("Mock", "MOCK");
        vm.etch(escrow.WETH(), address(tokenImplementation).code);
        vm.etch(escrow.USDC(), address(tokenImplementation).code);
        vm.etch(escrow.USDT(), address(tokenImplementation).code);
        vm.etch(escrow.SAIRI(), address(tokenImplementation).code);

        MockSwapRouter routerImplementation = new MockSwapRouter();
        vm.etch(escrow.SWAP_ROUTER(), address(routerImplementation).code);

        supportedTokens.push(escrow.WETH());
        supportedTokens.push(escrow.USDC());
        supportedTokens.push(escrow.USDT());
        supportedTokens.push(escrow.SAIRI());

        handler = new FaightersEscrowHandler(escrow, owner, resolver, actors);
        targetContract(address(handler));
    }

    function invariant_reservedBalancesAlwaysBacked() external view {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 reserved = escrow.reservedTokenBalance(token);
            uint256 contractBalance = IERC20(token).balanceOf(address(escrow));
            assertGe(contractBalance, reserved, "reserved exceeds token balance");
        }
    }

    function invariant_reservedMatchesOutstandingFightLiability() external view {
        uint256[] memory liabilities = new uint256[](supportedTokens.length);
        uint256 count = handler.trackedFightCount();

        for (uint256 i = 0; i < count; i++) {
            bytes32 fightId = handler.trackedFightIdAt(i);
            FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
            if (fight.playerA == address(0) || fight.resolved) {
                continue;
            }

            uint256 idx = _tokenIndex(fight.tokenUsed);
            if (fight.playerAStaked) {
                liabilities[idx] += fight.stakeAmount;
            }
            if (fight.playerBStaked) {
                liabilities[idx] += fight.stakeAmount;
            }
        }

        for (uint256 j = 0; j < supportedTokens.length; j++) {
            assertEq(liabilities[j], escrow.reservedTokenBalance(supportedTokens[j]), "liability mismatch");
        }
    }

    function invariant_resolvedWinnerConsistency() external view {
        uint256 count = handler.trackedFightCount();
        for (uint256 i = 0; i < count; i++) {
            bytes32 fightId = handler.trackedFightIdAt(i);
            FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
            if (fight.playerA == address(0)) {
                continue;
            }

            if (!fight.resolved) {
                assertEq(fight.winner, address(0), "unresolved fight has winner");
                continue;
            }

            if (fight.winner == address(0)) {
                continue;
            }
            assertTrue(fight.winner == fight.playerA || fight.winner == fight.playerB, "invalid resolved winner");
        }
    }

    function _tokenIndex(address token) internal view returns (uint256) {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                return i;
            }
        }
        revert("unsupported token");
    }
}
