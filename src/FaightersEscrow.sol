// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

contract FaightersEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Supported WETH token on Base.
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    /// @notice Supported USDC token on Base.
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice Supported USDT token on Base.
    address public constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    /// @notice Supported SAIRI token on Base.
    address public constant SAIRI = 0xde61878b0b21ce395266c44d4d548d1c72a3eb07;
    /// @notice Uniswap V3 SwapRouter on Base.
    address public constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    /// @notice Burn sink address.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Default Uniswap V3 pool fee tier (0.3%).
    uint24 public constant UNISWAP_POOL_FEE = 3000;

    /// @notice Percent of the pot paid to the winner.
    uint256 public constant WINNER_PCT = 70;
    /// @notice Percent of the pot used as house cut for burn.
    uint256 public constant HOUSE_PCT = 30;

    /// @notice Resolver wallet allowed to resolve and house-cancel fights.
    address public resolver;

    struct Fight {
        bytes32 fightId;
        address tokenUsed;
        uint256 stakeAmount;
        address playerA;
        address playerB;
        bool playerAStaked;
        bool playerBStaked;
        bool resolved;
        address winner;
    }

    mapping(bytes32 => Fight) public fights;

    error UnsupportedToken(address token);
    error InvalidStakeAmount();
    error InvalidFightId();
    error FightAlreadyExists(bytes32 fightId);
    error FightNotFound(bytes32 fightId);
    error AlreadyJoined(bytes32 fightId);
    error CannotJoinOwnFight();
    error FightNotReady(bytes32 fightId);
    error FightResolvedAlready(bytes32 fightId);
    error InvalidWinner(address winner);
    error ResolverOnly();
    error Unauthorized();
    error ZeroAddress();
    error MinSairiOutRequired();
    error InvalidPercentConfig();

    event ResolverUpdated(address indexed previousResolver, address indexed newResolver);
    event FightCreated(bytes32 indexed fightId, address indexed playerA, address indexed token, uint256 stakeAmount);
    event FightJoined(bytes32 indexed fightId, address indexed playerB);
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

    modifier onlyResolver() {
        if (msg.sender != resolver) {
            revert ResolverOnly();
        }
        _;
    }

    /// @notice Deploys the escrow contract.
    /// @param resolver_ Trusted backend wallet that resolves fights.
    /// @param owner_ Owner address for admin controls.
    constructor(address resolver_, address owner_) Ownable(owner_) {
        if (resolver_ == address(0)) {
            revert ZeroAddress();
        }
        if (WINNER_PCT + HOUSE_PCT != 100) {
            revert InvalidPercentConfig();
        }
        resolver = resolver_;
    }

    /// @notice Updates the resolver wallet.
    /// @param newResolver New trusted resolver.
    function setResolver(address newResolver) external onlyOwner {
        if (newResolver == address(0)) {
            revert ZeroAddress();
        }
        address oldResolver = resolver;
        resolver = newResolver;
        emit ResolverUpdated(oldResolver, newResolver);
    }

    /// @notice Creates a fight and stakes `stakeAmount` from player A.
    /// @param fightId Unique identifier matching off-chain session id bytes32.
    /// @param token ERC-20 token address used by both players.
    /// @param stakeAmount Stake per player, denominated in token units.
    function createFight(bytes32 fightId, address token, uint256 stakeAmount) external nonReentrant {
        if (fightId == bytes32(0)) {
            revert InvalidFightId();
        }
        if (!_isSupportedToken(token)) {
            revert UnsupportedToken(token);
        }
        if (stakeAmount == 0) {
            revert InvalidStakeAmount();
        }

        Fight storage fight = fights[fightId];
        if (fight.playerA != address(0)) {
            revert FightAlreadyExists(fightId);
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), stakeAmount);

        fights[fightId] = Fight({
            fightId: fightId,
            tokenUsed: token,
            stakeAmount: stakeAmount,
            playerA: msg.sender,
            playerB: address(0),
            playerAStaked: true,
            playerBStaked: false,
            resolved: false,
            winner: address(0)
        });

        emit FightCreated(fightId, msg.sender, token, stakeAmount);
    }

    /// @notice Joins an existing fight and stakes the same token and amount as player A.
    /// @param fightId Fight identifier.
    function joinFight(bytes32 fightId) external nonReentrant {
        Fight storage fight = fights[fightId];
        if (fight.playerA == address(0)) {
            revert FightNotFound(fightId);
        }
        if (fight.resolved) {
            revert FightResolvedAlready(fightId);
        }
        if (fight.playerBStaked) {
            revert AlreadyJoined(fightId);
        }
        if (msg.sender == fight.playerA) {
            revert CannotJoinOwnFight();
        }

        IERC20(fight.tokenUsed).safeTransferFrom(msg.sender, address(this), fight.stakeAmount);
        fight.playerB = msg.sender;
        fight.playerBStaked = true;

        emit FightJoined(fightId, msg.sender);
    }

    /// @notice Resolves a fight in SAIRI mode (no swap required).
    /// @dev For non-SAIRI fights, use `resolveFight(bytes32,address,uint256)` with slippage protection.
    /// @param fightId Fight identifier.
    /// @param winnerAddress Winner address, must be one of the two fighters.
    function resolveFight(bytes32 fightId, address winnerAddress) external nonReentrant onlyResolver {
        _resolveFight(fightId, winnerAddress, 0);
    }

    /// @notice Resolves a fight and distributes winner payout while burning house cut in SAIRI.
    /// @dev For WETH/USDC/USDT fights, `minSairiOut` is supplied by resolver based on off-chain quote/TWAP.
    /// @param fightId Fight identifier.
    /// @param winnerAddress Winner address, must be one of the two fighters.
    /// @param minSairiOut Minimum SAIRI amount accepted from the house-cut swap.
    function resolveFight(bytes32 fightId, address winnerAddress, uint256 minSairiOut)
        external
        nonReentrant
        onlyResolver
    {
        _resolveFight(fightId, winnerAddress, minSairiOut);
    }

    /// @notice Cancels a fight and refunds staked funds.
    /// @dev Callable by resolver anytime before resolution, or by player A only before player B joins.
    /// @param fightId Fight identifier.
    function cancelFight(bytes32 fightId) external nonReentrant {
        Fight storage fight = fights[fightId];
        if (fight.playerA == address(0)) {
            revert FightNotFound(fightId);
        }
        if (fight.resolved) {
            revert FightResolvedAlready(fightId);
        }

        bool resolverCancel = msg.sender == resolver;
        bool playerABeforeJoinCancel = msg.sender == fight.playerA && !fight.playerBStaked;
        if (!resolverCancel && !playerABeforeJoinCancel) {
            revert Unauthorized();
        }

        fight.resolved = true;
        fight.winner = address(0);

        IERC20 token = IERC20(fight.tokenUsed);
        if (fight.playerAStaked) {
            token.safeTransfer(fight.playerA, fight.stakeAmount);
        }
        if (fight.playerBStaked) {
            token.safeTransfer(fight.playerB, fight.stakeAmount);
        }

        emit FightCancelled(fightId, msg.sender);
    }

    /// @notice Returns full fight data by id.
    /// @param fightId Fight identifier.
    /// @return fight Full Fight struct.
    function getFight(bytes32 fightId) external view returns (Fight memory fight) {
        return fights[fightId];
    }

    /// @notice Allows owner to recover ERC-20 tokens held by this contract.
    /// @param token Token address to withdraw.
    function emergencyWithdraw(address token) external onlyOwner nonReentrant {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdraw(token, owner(), amount);
    }

    function _resolveFight(bytes32 fightId, address winnerAddress, uint256 minSairiOut) internal {
        Fight storage fight = fights[fightId];
        if (fight.playerA == address(0)) {
            revert FightNotFound(fightId);
        }
        if (fight.resolved) {
            revert FightResolvedAlready(fightId);
        }
        if (!fight.playerAStaked || !fight.playerBStaked) {
            revert FightNotReady(fightId);
        }
        if (winnerAddress != fight.playerA && winnerAddress != fight.playerB) {
            revert InvalidWinner(winnerAddress);
        }

        uint256 totalPot = fight.stakeAmount * 2;
        uint256 winnerPayout = (totalPot * WINNER_PCT) / 100;
        uint256 houseCut = totalPot - winnerPayout;

        fight.resolved = true;
        fight.winner = winnerAddress;

        IERC20 token = IERC20(fight.tokenUsed);
        token.safeTransfer(winnerAddress, winnerPayout);

        uint256 sairiBurned;
        if (fight.tokenUsed == SAIRI) {
            sairiBurned = houseCut;
            token.safeTransfer(BURN_ADDRESS, houseCut);
        } else {
            if (minSairiOut == 0) {
                revert MinSairiOutRequired();
            }

            token.forceApprove(SWAP_ROUTER, houseCut);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: fight.tokenUsed,
                tokenOut: SAIRI,
                fee: UNISWAP_POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: houseCut,
                amountOutMinimum: minSairiOut,
                sqrtPriceLimitX96: 0
            });

            sairiBurned = ISwapRouter(SWAP_ROUTER).exactInputSingle(params);
            IERC20(SAIRI).safeTransfer(BURN_ADDRESS, sairiBurned);
        }

        emit FightResolved(fightId, winnerAddress, fight.tokenUsed, winnerPayout, houseCut, sairiBurned);
    }

    function _isSupportedToken(address token) internal pure returns (bool) {
        return token == WETH || token == USDC || token == USDT || token == SAIRI;
    }
}
