// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

contract FaightersEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Supported WETH token on Base.
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    /// @notice Supported USDC token on Base.
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice Supported USDT token on Base.
    address public constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    /// @notice Supported SAIRI token on Base.
    address public constant SAIRI = 0xde61878b0b21ce395266c44D4d548D1C72A3eB07;
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
    /// @notice Basis points denominator for house-cut split configuration.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Default owner fee share from house cut, in bps.
    uint256 public constant DEFAULT_OWNER_FEE_BPS = 500; // 5% of house cut
    /// @notice Default resolver fee share from house cut, in bps.
    uint256 public constant DEFAULT_RESOLVER_FEE_BPS = 500; // 5% of house cut

    /// @notice Resolver wallet allowed to resolve and house-cancel fights.
    address public resolver;
    /// @notice Owner fee share from house cut, in bps.
    uint256 public ownerFeeBps;
    /// @notice Resolver fee share from house cut, in bps.
    uint256 public resolverFeeBps;
    /// @notice Total amount currently reserved for unresolved fights, by token.
    mapping(address => uint256) public reservedTokenBalance;

    struct Fight {
        bytes32 fightId;
        address tokenUsed;
        uint256 stakeAmount;
        uint256 joinDeadline;
        uint256 resolveDeadline;
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
    error InvalidHouseFeeSplit();
    error NoSurplusAvailable(address token);
    error InvalidDeadlineWindow();
    error JoinDeadlinePassed(bytes32 fightId, uint256 joinDeadline);
    error ResolveDeadlinePassed(bytes32 fightId, uint256 resolveDeadline);

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
        ownerFeeBps = DEFAULT_OWNER_FEE_BPS;
        resolverFeeBps = DEFAULT_RESOLVER_FEE_BPS;
        if (ownerFeeBps + resolverFeeBps > BPS_DENOMINATOR) {
            revert InvalidHouseFeeSplit();
        }
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

    /// @notice Updates owner/resolver fee split from the house cut.
    /// @dev Fee values are in basis points of the house cut (not total pot), and must sum to <= 10_000.
    /// @param newOwnerFeeBps Owner fee share from house cut in basis points.
    /// @param newResolverFeeBps Resolver fee share from house cut in basis points.
    function setHouseFeeBps(uint256 newOwnerFeeBps, uint256 newResolverFeeBps) external onlyOwner {
        if (newOwnerFeeBps + newResolverFeeBps > BPS_DENOMINATOR) {
            revert InvalidHouseFeeSplit();
        }
        uint256 oldOwnerFeeBps = ownerFeeBps;
        uint256 oldResolverFeeBps = resolverFeeBps;
        ownerFeeBps = newOwnerFeeBps;
        resolverFeeBps = newResolverFeeBps;
        emit HouseFeeConfigUpdated(oldOwnerFeeBps, oldResolverFeeBps, newOwnerFeeBps, newResolverFeeBps);
    }

    /// @notice Pauses fight lifecycle operations.
    /// @dev Owner-only emergency control for create/join/resolve/cancel flows.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses fight lifecycle operations.
    /// @dev Owner-only operation to resume normal flow.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Creates a fight and stakes `stakeAmount` from player A.
    /// @param fightId Unique identifier matching off-chain session id bytes32.
    /// @param token ERC-20 token address used by both players.
    /// @param stakeAmount Stake per player, denominated in token units.
    function createFight(bytes32 fightId, address token, uint256 stakeAmount) external nonReentrant whenNotPaused {
        _createFight(fightId, token, stakeAmount, msg.sender, 0, 0);
    }

    /// @notice Creates a fight with optional join and resolve deadlines.
    /// @dev Use `0` for either deadline to disable that constraint.
    /// @param fightId Unique identifier matching off-chain session id bytes32.
    /// @param token ERC-20 token address used by both players.
    /// @param stakeAmount Stake per player, denominated in token units.
    /// @param joinDeadline Latest timestamp allowed for player B to join. `0` disables.
    /// @param resolveDeadline Latest timestamp allowed for resolver to resolve. `0` disables.
    function createFightWithDeadlines(
        bytes32 fightId,
        address token,
        uint256 stakeAmount,
        uint256 joinDeadline,
        uint256 resolveDeadline
    ) external nonReentrant whenNotPaused {
        _createFight(fightId, token, stakeAmount, msg.sender, joinDeadline, resolveDeadline);
    }

    /// @notice Creates a fight and stakes from `playerA`, callable only by resolver backend.
    /// @dev `playerA` must have approved this contract for at least `stakeAmount`.
    /// @param fightId Unique identifier matching off-chain session id bytes32.
    /// @param token ERC-20 token address used by both players.
    /// @param stakeAmount Stake per player, denominated in token units.
    /// @param playerA Player A address whose funds are pulled.
    function createFightFor(bytes32 fightId, address token, uint256 stakeAmount, address playerA)
        external
        nonReentrant
        onlyResolver
        whenNotPaused
    {
        if (playerA == address(0)) {
            revert ZeroAddress();
        }
        _createFight(fightId, token, stakeAmount, playerA, 0, 0);
    }

    /// @notice Creates a fight with optional deadlines and stakes from `playerA`, callable only by resolver backend.
    /// @dev `playerA` must have approved this contract for at least `stakeAmount`.
    /// @param fightId Unique identifier matching off-chain session id bytes32.
    /// @param token ERC-20 token address used by both players.
    /// @param stakeAmount Stake per player, denominated in token units.
    /// @param playerA Player A address whose funds are pulled.
    /// @param joinDeadline Latest timestamp allowed for player B to join. `0` disables.
    /// @param resolveDeadline Latest timestamp allowed for resolver to resolve. `0` disables.
    function createFightForWithDeadlines(
        bytes32 fightId,
        address token,
        uint256 stakeAmount,
        address playerA,
        uint256 joinDeadline,
        uint256 resolveDeadline
    ) external nonReentrant onlyResolver whenNotPaused {
        if (playerA == address(0)) {
            revert ZeroAddress();
        }
        _createFight(fightId, token, stakeAmount, playerA, joinDeadline, resolveDeadline);
    }

    /// @notice Joins an existing fight and stakes from caller.
    /// @param fightId Fight identifier.
    function joinFight(bytes32 fightId) external nonReentrant whenNotPaused {
        _joinFight(fightId, msg.sender);
    }

    /// @notice Joins an existing fight and stakes from `playerB`, callable only by resolver backend.
    /// @dev `playerB` must have approved this contract for the fight stake amount.
    /// @param fightId Fight identifier.
    /// @param playerB Player B address whose funds are pulled.
    function joinFightFor(bytes32 fightId, address playerB) external nonReentrant onlyResolver whenNotPaused {
        if (playerB == address(0)) {
            revert ZeroAddress();
        }
        _joinFight(fightId, playerB);
    }

    function _createFight(
        bytes32 fightId,
        address token,
        uint256 stakeAmount,
        address playerA,
        uint256 joinDeadline,
        uint256 resolveDeadline
    ) internal {
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
        _validateDeadlines(joinDeadline, resolveDeadline);

        IERC20(token).safeTransferFrom(playerA, address(this), stakeAmount);
        reservedTokenBalance[token] += stakeAmount;

        fights[fightId] = Fight({
            fightId: fightId,
            tokenUsed: token,
            stakeAmount: stakeAmount,
            joinDeadline: joinDeadline,
            resolveDeadline: resolveDeadline,
            playerA: playerA,
            playerB: address(0),
            playerAStaked: true,
            playerBStaked: false,
            resolved: false,
            winner: address(0)
        });

        emit FightCreated(fightId, playerA, token, stakeAmount);
    }

    function _joinFight(bytes32 fightId, address playerB) internal {
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
        if (playerB == fight.playerA) {
            revert CannotJoinOwnFight();
        }
        if (fight.joinDeadline != 0 && block.timestamp > fight.joinDeadline) {
            revert JoinDeadlinePassed(fightId, fight.joinDeadline);
        }

        IERC20(fight.tokenUsed).safeTransferFrom(playerB, address(this), fight.stakeAmount);
        reservedTokenBalance[fight.tokenUsed] += fight.stakeAmount;

        fight.playerB = playerB;
        fight.playerBStaked = true;

        emit FightJoined(fightId, playerB);
    }

    /// @notice Resolves a fight in SAIRI mode (no swap required).
    /// @dev For non-SAIRI fights, use `resolveFight(bytes32,address,uint256)` with slippage protection.
    /// @param fightId Fight identifier.
    /// @param winnerAddress Winner address, must be one of the two fighters.
    function resolveFight(bytes32 fightId, address winnerAddress) external nonReentrant onlyResolver whenNotPaused {
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
        whenNotPaused
    {
        _resolveFight(fightId, winnerAddress, minSairiOut);
    }

    /// @notice Cancels a fight and refunds staked funds.
    /// @dev Callable by resolver anytime before resolution, or by player A only before player B joins.
    /// @param fightId Fight identifier.
    function cancelFight(bytes32 fightId) external nonReentrant whenNotPaused {
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

        uint256 refundAmount = 0;
        if (fight.playerAStaked) {
            refundAmount += fight.stakeAmount;
        }
        if (fight.playerBStaked) {
            refundAmount += fight.stakeAmount;
        }

        reservedTokenBalance[fight.tokenUsed] -= refundAmount;
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
    /// @dev Withdraws only non-reserved surplus so unresolved fight liabilities remain fully backed.
    /// @param token Token address to withdraw surplus for.
    function emergencyWithdraw(address token) external onlyOwner nonReentrant {
        uint256 amount = getWithdrawableSurplus(token);
        if (amount < 1) {
            revert NoSurplusAvailable(token);
        }
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdraw(token, owner(), amount);
    }

    /// @notice Returns withdrawable surplus for a token after reserving unresolved-fight liabilities.
    /// @param token Token address to query.
    /// @return amount Withdrawable surplus amount.
    function getWithdrawableSurplus(address token) public view returns (uint256 amount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = reservedTokenBalance[token];
        if (balance > reserved) {
            return balance - reserved;
        }
        return 0;
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
        if (fight.resolveDeadline != 0 && block.timestamp > fight.resolveDeadline) {
            revert ResolveDeadlinePassed(fightId, fight.resolveDeadline);
        }

        uint256 totalPot = fight.stakeAmount * 2;
        uint256 winnerPayout = (totalPot * WINNER_PCT) / 100;
        uint256 houseCut = totalPot - winnerPayout;
        uint256 ownerFeeAmount = (houseCut * ownerFeeBps) / BPS_DENOMINATOR;
        uint256 resolverFeeAmount = (houseCut * resolverFeeBps) / BPS_DENOMINATOR;
        uint256 burnInputAmount = houseCut - ownerFeeAmount - resolverFeeAmount;

        reservedTokenBalance[fight.tokenUsed] -= totalPot;
        fight.resolved = true;
        fight.winner = winnerAddress;

        IERC20 token = IERC20(fight.tokenUsed);
        token.safeTransfer(winnerAddress, winnerPayout);
        if (ownerFeeAmount != 0) {
            token.safeTransfer(owner(), ownerFeeAmount);
        }
        if (resolverFeeAmount != 0) {
            token.safeTransfer(resolver, resolverFeeAmount);
        }

        emit HouseFeesDistributed(fightId, fight.tokenUsed, ownerFeeAmount, resolverFeeAmount, burnInputAmount);

        uint256 sairiBurned;
        if (fight.tokenUsed == SAIRI) {
            sairiBurned = burnInputAmount;
            if (burnInputAmount != 0) {
                token.safeTransfer(BURN_ADDRESS, burnInputAmount);
            }
        } else {
            if (burnInputAmount == 0) {
                sairiBurned = 0;
            } else {
                if (minSairiOut == 0) {
                    revert MinSairiOutRequired();
                }

                token.forceApprove(SWAP_ROUTER, burnInputAmount);

                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                    tokenIn: fight.tokenUsed,
                    tokenOut: SAIRI,
                    fee: UNISWAP_POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: burnInputAmount,
                    amountOutMinimum: minSairiOut,
                    sqrtPriceLimitX96: 0
                });

                sairiBurned = ISwapRouter(SWAP_ROUTER).exactInputSingle(params);
                IERC20(SAIRI).safeTransfer(BURN_ADDRESS, sairiBurned);
            }
        }

        emit FightResolved(fightId, winnerAddress, fight.tokenUsed, winnerPayout, houseCut, sairiBurned);
    }

    function _isSupportedToken(address token) internal pure returns (bool) {
        return token == WETH || token == USDC || token == USDT || token == SAIRI;
    }

    function _validateDeadlines(uint256 joinDeadline, uint256 resolveDeadline) internal view {
        if (joinDeadline != 0 && joinDeadline <= block.timestamp) {
            revert InvalidDeadlineWindow();
        }
        if (resolveDeadline != 0 && resolveDeadline <= block.timestamp) {
            revert InvalidDeadlineWindow();
        }
        if (joinDeadline != 0 && resolveDeadline != 0 && resolveDeadline <= joinDeadline) {
            revert InvalidDeadlineWindow();
        }
    }
}
