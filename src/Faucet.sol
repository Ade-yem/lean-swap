// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestnetToken} from "./TestnetToken.sol";

contract Faucet {
    TestnetToken public tUSDC;
    TestnetToken public tDAI;
    TestnetToken public tLEAN;
    TestnetToken public tETH;
    TestnetToken public tCOW;

    mapping(address => uint256) public lastClaimTime;
    uint256 public constant CLAIM_INTERVAL = 24 hours;

    // Disbursement amounts
    uint256 public constant tUSDC_AMOUNT = 100 * 10 ** 6; // USDC has 6 decimals usually, let's assume 18 for simplicity unless specified
    uint256 public constant tDAI_AMOUNT = 100 * 10 ** 18;
    uint256 public constant tLEAN_AMOUNT = 100 * 10 ** 18;
    uint256 public constant tETH_AMOUNT = 3 * 10 ** 18;
    uint256 public constant tCOW_AMOUNT = 100 * 10 ** 18;

    uint256 public constant INITIAL_MINT_AMOUNT = 100_000;

    constructor(address _tUSDC, address _tDAI, address _tLEAN, address _tETH, address _tCOW) {
        tUSDC = TestnetToken(_tUSDC);
        tDAI = TestnetToken(_tDAI);
        tLEAN = TestnetToken(_tLEAN);
        tETH = TestnetToken(_tETH);
        tCOW = TestnetToken(_tCOW);
    }

    // Called once the faucet is granted minter rights on the tokens
    function initializeMints() external {
        _mintIfNeeded(tUSDC, INITIAL_MINT_AMOUNT * 10 ** 6); // Check proper decimals
        _mintIfNeeded(tDAI, INITIAL_MINT_AMOUNT * 10 ** 18);
        _mintIfNeeded(tLEAN, INITIAL_MINT_AMOUNT * 10 ** 18);
        _mintIfNeeded(tETH, INITIAL_MINT_AMOUNT * 10 ** 18);
        _mintIfNeeded(tCOW, INITIAL_MINT_AMOUNT * 10 ** 18);
    }

    function requestTokens(address to) external {
        require(block.timestamp >= lastClaimTime[to] + CLAIM_INTERVAL, "Faucet: Please wait 24 hours between claims");

        lastClaimTime[to] = block.timestamp;

        _disperse(tUSDC, to, tUSDC_AMOUNT);
        _disperse(tDAI, to, tDAI_AMOUNT);
        _disperse(tLEAN, to, tLEAN_AMOUNT);
        _disperse(tETH, to, tETH_AMOUNT);
        _disperse(tCOW, to, tCOW_AMOUNT);
    }

    function _disperse(TestnetToken token, address to, uint256 amount) internal {
        if (token.balanceOf(address(this)) < amount) {
            // Mint a large batch to the faucet if running low
            uint256 mintAmount = INITIAL_MINT_AMOUNT * (10 ** token.decimals());
            token.mint(address(this), mintAmount);
        }
        token.transfer(to, amount);
    }

    function _mintIfNeeded(TestnetToken token, uint256 amount) internal {
        if (token.balanceOf(address(this)) < amount) {
            token.mint(address(this), amount);
        }
    }
}
