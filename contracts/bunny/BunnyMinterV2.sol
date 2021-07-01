// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

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

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";

import "../interfaces/IBunnyMinterV2.sol";
import "../interfaces/IStakingRewards.sol";
import "../interfaces/IPriceCalculator.sol";

import "../zap/ZapPolygon.sol";
import "../library/SafeToken.sol";

contract BunnyMinterV2 is IBunnyMinterV2, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant BUNNY = 0x4C16f69302CcB511c5Fac682c7626B9eF0Dc126a;
    address public constant BUNNY_ETH = 0x62052b489Cb5bC72a9DC8EEAE4B24FD50639921a;
    address private constant TIMELOCK = 0xf36eC1522625b2eBD0b4071945F3e97134653F8f;
    address public constant DEPLOYER = 0xbC776ac3af4D993774A54af497055170C81c113F;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant BUNNY_LAUNCHER = 0x1C02773f409f260F5774c32bc77A05B8c19d3914;
    address public constant BUNNY_POOL = 0x10C8CFCa4953Bc554e71ddE3Fa19c335e163D7Ac;
    address public constant BUNNY_MAXIMIZER = 0x4Ad69DC9eA7Cc01CE13A37F20817baC4bF0De1ba;

    uint public constant FEE_MAX = 10000;
    IZap private constant zapPolygon = IZap(0x663462430834E220851a3E981D0E1199501b84F6);
    IPriceCalculator private constant priceCalculator = IPriceCalculator(0xE3B11c3Bd6d90CfeBBb4FB9d59486B0381D38021);
    IPancakeRouter02 private constant router = IPancakeRouter02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);

    /* ========== STATE VARIABLES ========== */

    address public bunnyChef;
    mapping(address => bool) private _minters;

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public override bunnyPerProfitBNB;

    uint private _floatingRateEmission;
    uint private _freThreshold;


    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "BunnyMinterV2: caller is not the minter");
        _;
    }

    modifier onlyBunnyChef {
        require(msg.sender == bunnyChef, "BunnyMinterV2: caller not the bunny chef");
        _;
    }

    /* ========== EVENTS ========== */

    event PerformanceFee(address indexed asset, uint amount, uint value);

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        IBEP20(BUNNY).approve(BUNNY_POOL, uint(- 1));
        IBEP20(BUNNY).approve(BUNNY_MAXIMIZER, uint(- 1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferBunnyOwner(address _owner) external onlyOwner {
        Ownable(BUNNY).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setBunnyChef(address _bunnyChef) external onlyOwner {
        require(bunnyChef == address(0), "BunnyMinterV2: setBunnyChef only once");
        bunnyChef = _bunnyChef;
    }

    function setFloatingRateEmission(uint floatingRateEmission) external onlyOwner {
        require(floatingRateEmission > 1e18 && floatingRateEmission < 10e18, "BunnyMinterV2: floatingRateEmission wrong range");
        _floatingRateEmission = floatingRateEmission;
    }

    function setFREThreshold(uint threshold) external onlyOwner {
        _freThreshold = threshold;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(BUNNY).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountBunnyToMint(uint ethProfit) public view override returns (uint) {
        if (priceCalculator.priceOfBunny() == 0) {
            return 0;
        }
        return ethProfit.mul(priceCalculator.priceOfETH()).div(priceCalculator.priceOfBunny()).mul(floatingRateEmission()).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) public view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function floatingRateEmission() public view returns(uint) {
        return _floatingRateEmission == 0 ? 200e16 : _floatingRateEmission;
    }

    function freThreshold() public view returns(uint) {
        return _freThreshold == 0 ? 500e18 : _freThreshold;
    }

    function shouldMarketBuy() public view returns(bool) {
        return priceCalculator.priceOfBunny().mul(freThreshold()).div(priceCalculator.priceOfETH()) < 1e18 - 1000;
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) public payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == BUNNY) {
            IBEP20(BUNNY).safeTransfer(TIMELOCK, feeSum);
            return;
        }

        bool marketBuy = shouldMarketBuy();
        if (marketBuy == false) {
            uint bunnyETHAmount = asset == BUNNY_ETH ? feeSum : _zapAssets(asset, feeSum, BUNNY_ETH);
            if (bunnyETHAmount == 0) return;

            IBEP20(BUNNY_ETH).safeTransfer(BUNNY_POOL, bunnyETHAmount);
            IStakingRewards(BUNNY_POOL).notifyRewardAmount(bunnyETHAmount);
        } else {
            if (_withdrawalFee > 0) {
                uint bunnyETHAmount = asset == BUNNY_ETH ? _withdrawalFee : _zapAssets(asset, _withdrawalFee, BUNNY_ETH);
                if (bunnyETHAmount == 0) return;

                IBEP20(BUNNY_ETH).safeTransfer(BUNNY_POOL, bunnyETHAmount);
                IStakingRewards(BUNNY_POOL).notifyRewardAmount(bunnyETHAmount);
            }

            if (_performanceFee == 0) return;
            uint bunnyAmount = _zapAssets(asset, _performanceFee, BUNNY);
            IBEP20(BUNNY).safeTransfer(to, bunnyAmount);

            _performanceFee = _performanceFee.mul(floatingRateEmission().sub(1e18)).div(floatingRateEmission());
        }

        (uint contributionInETH, uint contributionInUSD) = priceCalculator.valueOfAsset(asset, _performanceFee);
        uint mintBunny = amountBunnyToMint(contributionInETH);
        if (mintBunny == 0) return;
        _mint(mintBunny, to);

        if (marketBuy) {
            uint usd = contributionInUSD.mul(floatingRateEmission()).div(floatingRateEmission().sub(1e18));
            emit PerformanceFee(asset, _performanceFee, usd);
        } else {
            emit PerformanceFee(asset, _performanceFee, contributionInUSD);
        }
    }

    /* ========== PancakeSwap V2 FUNCTIONS ========== */

    function mintForV2(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint timestamp) external payable override onlyMinter {
        mintFor(asset, _withdrawalFee, _performanceFee, to, timestamp);
    }

    /* ========== BunnyChef FUNCTIONS ========== */

    function mint(uint amount) external override onlyBunnyChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeBunnyTransfer(address _to, uint _amount) external override onlyBunnyChef {
        if (_amount == 0) return;

        uint bal = IBEP20(BUNNY).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(BUNNY).safeTransfer(_to, _amount);
        } else {
            IBEP20(BUNNY).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Bunny is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== LAUNCHER FUNCTIONS ========== */

    function mintForBunnyLauncher(uint amount, address to) override external {
        require(msg.sender == BUNNY_LAUNCHER, "BunnyMinter: not launcher contract.");
        if (amount == 0) return;
        _mint(amount, to);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _zapAssets(address asset, uint amount, address toAsset) private returns (uint toAssetAmount) {
        uint _initToAssetAmount = IBEP20(toAsset).balanceOf(address(this));

        if (asset == address(0)) {
            zapPolygon.zapIn{value : amount}(toAsset);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("UNI-V2")) {
            if (IBEP20(asset).allowance(address(this), address(router)) == 0) {
                IBEP20(asset).safeApprove(address(router), uint(- 1));
            }

            IPancakePair pair = IPancakePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            if (IPancakePair(asset).balanceOf(asset) > 0) {
                IPancakePair(asset).burn(address(DEPLOYER));
            }
            (uint amountToken0, uint amountToken1) = router.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);

            if (IBEP20(token0).allowance(address(this), address(zapPolygon)) == 0) {
                IBEP20(token0).safeApprove(address(zapPolygon), uint(- 1));
            }
            if (IBEP20(token1).allowance(address(this), address(zapPolygon)) == 0) {
                IBEP20(token1).safeApprove(address(zapPolygon), uint(- 1));
            }

            zapPolygon.zapInToken(token0, amountToken0, toAsset);
            zapPolygon.zapInToken(token1, amountToken1, toAsset);
        }
        else {
            if (IBEP20(asset).allowance(address(this), address(zapPolygon)) == 0) {
                IBEP20(asset).safeApprove(address(zapPolygon), uint(- 1));
            }

            zapPolygon.zapInToken(asset, amount, toAsset);
        }

        toAssetAmount = IBEP20(toAsset).balanceOf(address(this)).sub(_initToAssetAmount);
    }

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenBUNNY = BEP20(BUNNY);

        tokenBUNNY.mint(amount);
        if (to != address(this)) {
            tokenBUNNY.transfer(to, amount);
        }

        uint bunnyForDev = amount.mul(15).div(100);
        tokenBUNNY.mint(bunnyForDev);
        IStakingRewards(BUNNY_MAXIMIZER).stakeTo(bunnyForDev, DEPLOYER);
    }
}
