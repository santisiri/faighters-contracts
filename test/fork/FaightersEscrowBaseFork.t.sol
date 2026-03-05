// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FaightersEscrow} from "../../src/FaightersEscrow.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract FaightersEscrowBaseForkTest is Test {
    address internal constant BASE_UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    string internal constant BASE_PUBLIC_RPC = "https://mainnet.base.org";

    uint256 internal constant STAKE_USDC = 100e6;
    uint256 internal constant STAKE_SAIRI = 100 ether;
    uint256 internal constant START_USDC = 10_000e6;
    uint256 internal constant START_SAIRI = 1_000 ether;

    FaightersEscrow internal escrow;
    IERC20 internal usdc;
    IERC20 internal sairi;

    address internal owner;
    address internal resolver;
    address internal playerA;
    address internal playerB;

    function setUp() external {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", BASE_PUBLIC_RPC);
        vm.createSelectFork(rpcUrl);

        owner = makeAddr("forkOwner");
        resolver = makeAddr("forkResolver");
        playerA = makeAddr("forkPlayerA");
        playerB = makeAddr("forkPlayerB");

        escrow = new FaightersEscrow(resolver, owner);
        usdc = IERC20(escrow.USDC());
        sairi = IERC20(escrow.SAIRI());

        deal(address(usdc), playerA, START_USDC);
        deal(address(usdc), playerB, START_USDC);
        deal(address(sairi), playerA, START_SAIRI);
        deal(address(sairi), playerB, START_SAIRI);

        vm.prank(playerA);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(playerB);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(playerA);
        sairi.approve(address(escrow), type(uint256).max);
        vm.prank(playerB);
        sairi.approve(address(escrow), type(uint256).max);
    }

    function testFork_RealRouterAndTokenContractsExist() external view {
        assertGt(address(escrow.SWAP_ROUTER()).code.length, 0);
        assertGt(address(usdc).code.length, 0);
        assertGt(address(sairi).code.length, 0);
    }

    function testFork_SwapRouteFeeAssumption_CheckPools() external view {
        address configuredPool = IUniswapV3Factory(BASE_UNISWAP_V3_FACTORY)
            .getPool(escrow.USDC(), escrow.SAIRI(), escrow.UNISWAP_POOL_FEE());
        address onePercentPool =
            IUniswapV3Factory(BASE_UNISWAP_V3_FACTORY).getPool(escrow.USDC(), escrow.SAIRI(), 10000);

        // Validates current Base reality against contract assumptions.
        assertEq(configuredPool, address(0), "USDC/SAIRI 0.3% pool unexpectedly exists");
        assertTrue(onePercentPool != address(0), "USDC/SAIRI 1% pool missing");
    }

    function testFork_ResolveFightUsdcSwap_RevertsAndRollsBack_WhenConfiguredPoolMissing() external {
        bytes32 fightId = keccak256("fork-usdc-swap-revert");
        _createAndJoin(fightId, address(usdc), STAKE_USDC);

        uint256 winnerBefore = usdc.balanceOf(playerA);
        uint256 escrowBefore = usdc.balanceOf(address(escrow));
        uint256 reservedBefore = escrow.reservedTokenBalance(address(usdc));

        vm.expectRevert();
        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA, 1);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertFalse(fight.resolved);
        assertEq(fight.winner, address(0));
        assertEq(usdc.balanceOf(playerA), winnerBefore);
        assertEq(usdc.balanceOf(address(escrow)), escrowBefore);
        assertEq(escrow.reservedTokenBalance(address(usdc)), reservedBefore);
    }

    function testFork_ResolveFightSairiPath_WorksOnBaseFork() external {
        bytes32 fightId = keccak256("fork-sairi-resolve");
        _createAndJoin(fightId, address(sairi), STAKE_SAIRI);

        uint256 totalPot = STAKE_SAIRI * 2;
        uint256 winnerPayout = (totalPot * escrow.WINNER_PCT()) / 100;
        uint256 houseCut = totalPot - winnerPayout;
        uint256 ownerFeeAmount = (houseCut * escrow.ownerFeeBps()) / escrow.BPS_DENOMINATOR();
        uint256 resolverFeeAmount = (houseCut * escrow.resolverFeeBps()) / escrow.BPS_DENOMINATOR();
        uint256 burnInputAmount = houseCut - ownerFeeAmount - resolverFeeAmount;

        uint256 winnerBefore = sairi.balanceOf(playerA);
        uint256 ownerBefore = sairi.balanceOf(owner);
        uint256 resolverBefore = sairi.balanceOf(resolver);
        uint256 burnBefore = sairi.balanceOf(escrow.BURN_ADDRESS());

        vm.prank(resolver);
        escrow.resolveFight(fightId, playerA);

        FaightersEscrow.Fight memory fight = escrow.getFight(fightId);
        assertTrue(fight.resolved);
        assertEq(fight.winner, playerA);
        assertEq(sairi.balanceOf(playerA), winnerBefore + winnerPayout);
        assertEq(sairi.balanceOf(owner), ownerBefore + ownerFeeAmount);
        assertEq(sairi.balanceOf(resolver), resolverBefore + resolverFeeAmount);
        assertEq(sairi.balanceOf(escrow.BURN_ADDRESS()), burnBefore + burnInputAmount);
        assertEq(escrow.reservedTokenBalance(address(sairi)), 0);
    }

    function _createAndJoin(bytes32 fightId, address token, uint256 stake) internal {
        vm.prank(playerA);
        escrow.createFight(fightId, token, stake);

        vm.prank(playerB);
        escrow.joinFight(fightId);
    }
}
