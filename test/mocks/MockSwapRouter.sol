// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";

contract MockSwapRouter is ISwapRouter {
    uint256 public amountOut;
    address public lastTokenIn;
    address public lastTokenOut;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;

    function setAmountOut(uint256 newAmountOut) external {
        amountOut = newAmountOut;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable override returns (uint256) {
        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;

        require(IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");
        require(amountOut >= params.amountOutMinimum, "slippage");
        require(IERC20(params.tokenOut).transfer(params.recipient, amountOut), "transfer failed");

        return amountOut;
    }
}
