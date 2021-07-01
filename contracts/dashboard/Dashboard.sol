// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 BunnyFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../library/SafeDecimal.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/ILockedStrategy.sol";
import "../interfaces/IBunnyMinter.sol";
import "../interfaces/IBunnyChef.sol";
import "../interfaces/IPriceCalculator.sol";


contract Dashboard is OwnableUpgradeable {
    using SafeMath for uint;
    using SafeDecimal for uint;

    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xE3B11c3Bd6d90CfeBBb4FB9d59486B0381D38021);

    address public constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address public constant ETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address public constant BUNNY = 0x4C16f69302CcB511c5Fac682c7626B9eF0Dc126a;

    IBunnyChef private constant bunnyChef = IBunnyChef(0x3048d5B8EC1B034Ae947597a6A30a42F2e1fd82F);

    /* ========== STATE VARIABLES ========== */

    mapping(address => PoolConstant.PoolTypes) public poolTypes;
    mapping(address => bool) public perfExemptions;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
    }

    /* ========== Restricted Operation ========== */

    function setPoolType(address pool, PoolConstant.PoolTypes poolType) public onlyOwner {
        poolTypes[pool] = poolType;
    }

    function setPerfExemption(address pool, bool exemption) public onlyOwner {
        perfExemptions[pool] = exemption;
    }

    /* ========== View Functions ========== */

    function poolTypeOf(address pool) public view returns (PoolConstant.PoolTypes) {
        return poolTypes[pool];
    }

    /* ========== Profit Calculation ========== */

    function calculateProfit(address pool, address account) public view returns (uint profit, uint profitInETH) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];
        profit = 0;
        profitInETH = 0;

        if (poolType == PoolConstant.PoolTypes.BunnyETH) {
            // profit as bunny
            profit = bunnyChef.pendingBunny(pool, account);
            (profitInETH,) = priceCalculator.valueOfAsset(BUNNY, profit);
        }
        else if (poolType == PoolConstant.PoolTypes.FlipToFlip || poolType == PoolConstant.PoolTypes.BunnyToBunny) {
            // profit as underlying
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account);
            (profitInETH,) = priceCalculator.valueOfAsset(strategy.stakingToken(), profit);
        }
    }

    function profitOfPool(address pool, address account) public view returns (uint profit, uint bunny) {
        (uint profitCalculated, uint profitInETH) = calculateProfit(pool, account);
        profit = profitCalculated;
        bunny = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (strategy.minter() != address(0)) {
                profit = profit.mul(70).div(100);
                bunny = IBunnyMinter(strategy.minter()).amountBunnyToMint(profitInETH.mul(30).div(100));
            }

            if (strategy.bunnyChef() != address(0)) {
                bunny = bunny.add(bunnyChef.pendingBunny(pool, account));
            }
        }
    }

    /* ========== TVL Calculation ========== */

    function tvlOfPool(address pool) public view returns (uint tvl) {
        IStrategy strategy = IStrategy(pool);
        (, tvl) = priceCalculator.valueOfAsset(strategy.stakingToken(), strategy.balance());
    }

    /* ========== Pool Information ========== */

    function infoOfPool(address pool, address account) public view returns (PoolConstant.PoolInfo memory) {
        PoolConstant.PoolInfo memory poolInfo;

        IStrategy strategy = IStrategy(pool);
        (uint pBASE, uint pBUNNY) = profitOfPool(pool, account);

        poolInfo.pool = pool;
        poolInfo.balance = strategy.balanceOf(account);
        poolInfo.principal = strategy.principalOf(account);
        poolInfo.available = withdrawableOf(pool, account);
        poolInfo.tvl = tvlOfPool(pool);
        poolInfo.pBASE = pBASE;
        poolInfo.pBUNNY = pBUNNY;

        if (strategy.minter() != address(0)) {
            IBunnyMinter minter = IBunnyMinter(strategy.minter());
            poolInfo.depositedAt = strategy.depositedAt(account);
            poolInfo.feeDuration = minter.WITHDRAWAL_FEE_FREE_PERIOD();
            poolInfo.feePercentage = minter.WITHDRAWAL_FEE();
        }

        poolInfo.portfolio = portfolioOfPoolInUSD(pool, account);
        return poolInfo;
    }

    function poolsOf(address account, address[] memory pools) public view returns (PoolConstant.PoolInfo[] memory) {
        PoolConstant.PoolInfo[] memory results = new PoolConstant.PoolInfo[](pools.length);
        for (uint i = 0; i < pools.length; i++) {
            results[i] = infoOfPool(pools[i], account);
        }
        return results;
    }

    /* ========== Withdrawable Calculation ========== */

    function withdrawableOf(address pool, address account) public view returns (uint) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];

        if (poolType == PoolConstant.PoolTypes.BunnyToBunny
            || poolType == PoolConstant.PoolTypes.BunnyETH) {
            return ILockedStrategy(pool).withdrawablePrincipalOf(account);
        }

        return IStrategy(pool).withdrawableBalanceOf(account);
    }

    /* ========== Portfolio Calculation ========== */

    function stakingTokenValueInUSD(address pool, address account) internal view returns (uint tokenInUSD) {
        if (IStrategy(pool).stakingToken() == address(0)) return 0;
        (, tokenInUSD) = priceCalculator.valueOfAsset(IStrategy(pool).stakingToken(), IStrategy(pool).principalOf(account));
    }

    function portfolioOfPoolInUSD(address pool, address account) internal view returns (uint) {
        uint tokenInUSD = stakingTokenValueInUSD(pool, account);
        (, uint profitInETH) = calculateProfit(pool, account);
        uint profitInBUNNY = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (strategy.minter() != address(0)) {
                profitInETH = profitInETH.mul(70).div(100);
                profitInBUNNY = IBunnyMinter(strategy.minter()).amountBunnyToMint(profitInETH.mul(30).div(100));
            }

            if ((poolTypes[pool] == PoolConstant.PoolTypes.BunnyETH || poolTypes[pool] == PoolConstant.PoolTypes.FlipToFlip)
                && strategy.bunnyChef() != address(0)) {
                profitInBUNNY = profitInBUNNY.add(bunnyChef.pendingBunny(pool, account));
            }
        }

        (, uint profitETHInUSD) = priceCalculator.valueOfAsset(ETH, profitInETH);
        (, uint profitBUNNYInUSD) = priceCalculator.valueOfAsset(BUNNY, profitInBUNNY);
        return tokenInUSD.add(profitETHInUSD).add(profitBUNNYInUSD);
    }

    function portfolioOf(address account, address[] memory pools) public view returns (uint deposits) {
        deposits = 0;
        for (uint i = 0; i < pools.length; i++) {
            deposits = deposits.add(portfolioOfPoolInUSD(pools[i], account));
        }
    }
}
