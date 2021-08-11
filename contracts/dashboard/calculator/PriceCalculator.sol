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

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../../interfaces/IPancakePair.sol";
import "../../interfaces/IPancakeFactory.sol";
import "../../interfaces/AggregatorV3Interface.sol";
import "../../interfaces/IPriceCalculator.sol";
import "../../library/HomoraMath.sol";
import "../../interfaces/IZap.sol";

contract PriceCalculator is IPriceCalculator, OwnableUpgradeable {
    using SafeMath for uint;
    using HomoraMath for uint;

    address public constant BUNNY = 0x4C16f69302CcB511c5Fac682c7626B9eF0Dc126a;
    address private constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address private constant QUICK = 0x831753DD7087CaC61aB5644b308642cc1c33Dc13;
    address private constant AAVE = 0xD6DF932A45C0f255f85145f286eA0b292B21C90B;
    address private constant ETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address private constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address private constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address private constant BTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
    address private constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
    address private constant SUSHI = 0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a;
    address private constant LINK = 0x53E0bca35eC356BD5ddDFebbD1Fc0fD03FaBad39;
    address private constant IBBTC = 0x4EaC4c4e9050464067D673102F8E24b2FccEB350;
    address private constant FRAX = 0x104592a158490a9228070E0A8e5343B499e125D0;

    IPancakeFactory private constant factory = IPancakeFactory(0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32);
    IPancakeFactory private constant sushiFactory = IPancakeFactory(0xc35DADB65012eC5796536bD9864eD8773aBc74C4);
    IZap private constant zapPolygon = IZap(0x663462430834E220851a3E981D0E1199501b84F6);

    /* ========== STATE VARIABLES ========== */

    address public keeper;

    mapping(address => address) private pairTokens;
    mapping(address => address) private tokenFeeds;
    mapping(address => ReferenceData) public references;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();

        setPairToken(BTC, ETH);
        setPairToken(AAVE, ETH);
        setPairToken(USDC, ETH);
        setPairToken(USDT, ETH);
        setPairToken(DAI, ETH);
        setPairToken(BUNNY, ETH);
        setPairToken(IBBTC, BTC);
        setPairToken(FRAX, USDC);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyKeeper {
        require(msg.sender == keeper || msg.sender == owner(), 'PriceCalculator: caller is not the owner or keeper');
        _;
    }

    /* ========== Restricted Operation ========== */

    function setKeeper(address _keeper) external onlyKeeper {
        require(_keeper != address(0), 'PriceCalculatorBSC: invalid keeper address');
        keeper = _keeper;
    }

    function setPairToken(address asset, address pairToken) public onlyOwner {
        pairTokens[asset] = pairToken;
    }

    function setTokenFeed(address asset, address feed) public onlyOwner {
        tokenFeeds[asset] = feed;
    }

    function setPrices(address[] memory assets, uint[] memory prices) external onlyKeeper {
        for (uint i = 0; i < assets.length; i++) {
            references[assets[i]] = ReferenceData({lastData : prices[i], lastUpdated : block.timestamp});
        }
    }

    /* ========== Value Calculation ========== */

    function priceOfMATIC() view public override returns (uint) {
        (, int price, , ,) = AggregatorV3Interface(tokenFeeds[WMATIC]).latestRoundData();
        return uint(price).mul(1e10);
    }

    function priceOfBunny() view public override returns (uint) {
        (, uint bunnyPriceInUSD) = valueOfAsset(BUNNY, 1e18);
        return bunnyPriceInUSD;
    }

    function priceOfETH() view public override returns (uint) {
        (, int price, , ,) = AggregatorV3Interface(tokenFeeds[ETH]).latestRoundData();
        return uint(price).mul(1e10);
    }

    function valueOfAsset(address asset, uint amount) public view override returns (uint valueInETH, uint valueInUSD) {
        if (amount == 0) {
            return (0, 0);
        } else if (asset == address(0) || asset == WMATIC) {
            return _oracleValueOf(WMATIC, amount);
        } else if (asset == AAVE) {
            (, int price, , ,) = AggregatorV3Interface(tokenFeeds[AAVE]).latestRoundData();
            return _oracleValueOf(ETH, uint(price));
        } else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("UNI-V2") ||
            keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("SLP")) {
            return _getPairPrice(asset, amount);
        } else {
            return _oracleValueOf(asset, amount);
        }
    }

    function unsafeValueOfAsset(address asset, uint amount) public view returns (uint valueInETH, uint valueInUSD) {
        valueInUSD = 0;
        valueInETH = 0;

        if (asset == ETH) {
            valueInETH = amount;
            valueInUSD = amount.mul(priceOfETH()).div(1e18);
        }
        else if (asset == address(0) || asset == WMATIC) {
            valueInUSD = amount.mul(priceOfMATIC()).div(1e18);
            valueInETH = valueInUSD.mul(1e18).div(priceOfETH());
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("UNI-V2") ||
            keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("SLP")) {
            if (IPancakePair(asset).totalSupply() == 0) return (0, 0);

            (uint reserve0, uint reserve1,) = IPancakePair(asset).getReserves();
            if (IPancakePair(asset).token0() == ETH) {
                valueInETH = amount.mul(reserve0).mul(2).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInETH.mul(priceOfETH()).div(1e18);
            } else if (IPancakePair(asset).token1() == ETH) {
                valueInETH = amount.mul(reserve1).mul(2).div(IPancakePair(asset).totalSupply());
                valueInUSD = valueInETH.mul(priceOfETH()).div(1e18);
            } else {
                (uint priceInETH,) = valueOfAsset(IPancakePair(asset).token0(), 1e18);
                if (priceInETH == 0) {
                    (priceInETH,) = valueOfAsset(IPancakePair(asset).token1(), 1e18);
                    reserve1 = reserve1.mul(10 ** uint(uint8(18) - IBEP20(IPancakePair(asset).token1()).decimals()));
                    valueInETH = amount.mul(reserve1).mul(2).mul(priceInETH).div(1e18).div(IPancakePair(asset).totalSupply());
                } else {
                    reserve0 = reserve0.mul(10 ** uint(uint8(18) - IBEP20(IPancakePair(asset).token0()).decimals()));
                    valueInETH = amount.mul(reserve0).mul(2).mul(priceInETH).div(1e18).div(IPancakePair(asset).totalSupply());
                }
                valueInUSD = valueInETH.mul(priceOfETH()).div(1e18);
            }

        }
        else {
            address pairToken = pairTokens[asset] == address(0) ? WMATIC : pairTokens[asset];

            address pair = zapPolygon.covers(asset) ? factory.getPair(asset, pairToken) : sushiFactory.getPair(asset, pairToken);
            address token0 = IPancakePair(pair).token0();
            address token1 = IPancakePair(pair).token1();

            if (IBEP20(asset).balanceOf(pair) == 0) return (0, 0);

            (uint reserve0, uint reserve1,) = IPancakePair(pair).getReserves();

            if (IBEP20(token0).decimals() < uint8(18)){
                reserve0 = reserve0.mul(10 ** uint(uint8(18) - IBEP20(token0).decimals()));
            }

            if (IBEP20(token1).decimals() < uint8(18)) {
                reserve1 = reserve1.mul(10 ** uint(uint8(18) - IBEP20(token1).decimals()));
            }

            if (token0 == pairToken) {
                valueInETH = reserve0.mul(amount).div(reserve1);
            } else if (token1 == pairToken) {
                valueInETH = reserve1.mul(amount).div(reserve0);
            } else {
                return (0, 0);
            }

            if (pairToken != ETH) {
                (uint pairValueInETH,) = valueOfAsset(pairToken, 1e18);
                valueInETH = valueInETH.mul(pairValueInETH).div(1e18);
            }

            valueInUSD = valueInETH.mul(priceOfETH()).div(1e18);

        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _oracleValueOf(address asset, uint amount) private view returns (uint valueInETH, uint valueInUSD) {
        valueInUSD = 0;
        if (tokenFeeds[asset] != address(0)) {
            (, int price, , ,) = AggregatorV3Interface(tokenFeeds[asset]).latestRoundData();
            valueInUSD = uint(price).mul(1e10).mul(amount).div(1e18);
        } else if (references[asset].lastUpdated > block.timestamp.sub(1 days)) {
            valueInUSD = references[asset].lastData.mul(amount).div(1e18);
        }
        valueInETH = valueInUSD.mul(1e18).div(priceOfETH());
    }

    function _getPairPrice(address pair, uint amount) private view returns (uint valueInETH, uint valueInUSD) {
        address token0 = IPancakePair(pair).token0();
        address token1 = IPancakePair(pair).token1();
        uint totalSupply = IPancakePair(pair).totalSupply();
        (uint r0, uint r1,) = IPancakePair(pair).getReserves();

        if (IBEP20(token0).decimals() < uint8(18)) {
            r0 = r0.mul(10 ** uint(uint8(18) - IBEP20(token0).decimals()));
        }

        if (IBEP20(token1).decimals() < uint8(18)) {
            r1 = r1.mul(10 ** uint(uint8(18) - IBEP20(token1).decimals()));
        }

        uint sqrtK = HomoraMath.sqrt(r0.mul(r1)).fdiv(totalSupply);
        (uint px0,) = valueOfAsset(token0, 1e18);
        (uint px1,) = valueOfAsset(token1, 1e18);
        uint fairPriceInETH = sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2 ** 56).mul(HomoraMath.sqrt(px1)).div(2 ** 56);

        valueInETH = fairPriceInETH.mul(amount).div(1e18);
        valueInUSD = valueInETH.mul(priceOfETH()).div(1e18);
    }
}
