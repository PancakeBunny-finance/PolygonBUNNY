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
* SOFTWARE.
*/

import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IBunnyMinter.sol";
import "../interfaces/IBunnyChef.sol";
import "../interfaces/IPresale.sol";
import "./VaultController.sol";
import { PoolConstant } from "../library/PoolConstant.sol";
import "../interfaces/legacy/IStrategyLegacy.sol";
import "../interfaces/IZap.sol";

contract VaultBunnyMaximizer is VaultController, IStrategy, ReentrancyGuardUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address private constant BUNNY = 0x4C16f69302CcB511c5Fac682c7626B9eF0Dc126a;
    address private constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address private constant presaleContract = 0x172B554118ecd915C5F046819cA225351566566E;
    address private constant deadAddress = 0x000000000000000000000000000000000000dEaD;
    address private constant TIMELOCK = 0xf36eC1522625b2eBD0b4071945F3e97134653F8f;

    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.BunnyToBunny;
    address public constant BUNNY_POOL = 0x10C8CFCa4953Bc554e71ddE3Fa19c335e163D7Ac;

    IZap public constant zap = IZap(0x663462430834E220851a3E981D0E1199501b84F6);

    uint private constant timestampPresaleEnds = 1625097600;
    uint private constant timestamp2HoursAfterPresaleEnds = timestampPresaleEnds + (2 hours);
    uint private constant timestamp90DaysAfterPresaleEnds = timestampPresaleEnds + (90 days);

    uint private constant DUST = 1000;

    uint public constant override pid = 9999;

    /* ========== STATE VARIABLES ========== */

    uint private totalShares;
    mapping(address => uint) private _shares;
    mapping(address => uint) private _principal;
    mapping(address => uint) private _depositedAt;
    mapping(address => bool) private _stakePermission;

    /* ========== PRESALE ============== */

    mapping(address => uint) private _presaleBalance;

    /* ========== MODIFIERS ========== */

    modifier canStakeTo() {
        require(_stakePermission[msg.sender], "VaultBunnyMaximizer: auth");
        _;
    }

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __VaultController_init(IBEP20(BUNNY));
        __ReentrancyGuard_init();

        _stakePermission[msg.sender] = true;
        _stakePermission[presaleContract] = true;
        IBEP20(WETH).approve(address(zap), uint(-1));

        _stakingToken.approve(BUNNY_POOL, uint(-1));
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function balance() public view override returns (uint) {
        return IStrategyLegacy(BUNNY_POOL).balanceOf(address(this));
    }

    function balanceOf(address account) public view override returns (uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
    }

    function presaleBalanceOf(address account) public view returns (uint) {
        return _presaleBalance[account];
    }

    function principalOf(address account) public view override returns (uint) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        return BUNNY;
    }

    function priceShare() external view override returns (uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        if (block.timestamp > timestamp90DaysAfterPresaleEnds) {
            // unlock all presale bunny after 90 days from presale End
            return balanceOf(account);
        } else if (block.timestamp < timestamp2HoursAfterPresaleEnds) {
            // only withdrawable balance of after presale
            return balanceOf(account).sub(presaleBalanceOf(account));
        } else {
            // bunny in presale * 150%
            uint soldInPresale = IPresale(presaleContract).totalBalance().mul(3).div(2);
            uint bunnySupply = _stakingToken.totalSupply().mul(100).div(115);

            if (soldInPresale >= bunnySupply) {
                return balanceOf(account).sub(presaleBalanceOf(account));
            }

            // new bunny minted after presale
            uint bunnyNewMint = bunnySupply.sub(soldInPresale);
            if (bunnyNewMint >= soldInPresale) {
                return balanceOf(account);
            }

            uint lockedRatio = (soldInPresale.sub(bunnyNewMint)).mul(1e18).div(soldInPresale);
            uint lockedBalance = presaleBalanceOf(account).mul(lockedRatio).div(1e18);
            return balanceOf(account).sub(lockedBalance);
        }
    }

    function withdrawablePrincipalOf(address account) public view returns (uint) {
        if (block.timestamp > timestamp90DaysAfterPresaleEnds) {
            // unlock all presale bunny after 90 days from presale End
            return balanceOf(account);
        } else if (block.timestamp < timestamp2HoursAfterPresaleEnds) {
            // only withdrawable balance of after presale
            return balanceOf(account).sub(presaleBalanceOf(account));
        } else {
            // bunny in presale * 150%
            uint soldInPresale = IPresale(presaleContract).totalBalance().mul(3).div(2);
            uint bunnySupply = _stakingToken.totalSupply().mul(100).div(115);

            if (soldInPresale >= bunnySupply) {
                return principalOf(account).sub(presaleBalanceOf(account));
            }

            // new bunny minted after presale
            uint bunnyNewMint = bunnySupply.sub(soldInPresale);
            if (bunnyNewMint >= soldInPresale) {
                return balanceOf(account);
            }

            uint lockedRatio = (soldInPresale.sub(bunnyNewMint)).mul(1e18).div(soldInPresale);
            uint lockedBalance = presaleBalanceOf(account).mul(lockedRatio).div(1e18);
            return principalOf(account).sub(lockedBalance);
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint amount) public override {
        _deposit(amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        uint amount = balanceOf(msg.sender);
        uint principal = principalOf(msg.sender);
        uint depositTimestamp = _depositedAt[msg.sender];

        require(amount <= withdrawableBalanceOf(msg.sender), "VaultBunnyMaximizer: locked");

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        IStrategyLegacy(BUNNY_POOL).withdraw(amount);

        uint withdrawalFee = _minter.withdrawalFee(principal, depositTimestamp);
        if (withdrawalFee > 0) {
            _stakingToken.safeTransfer(TIMELOCK, withdrawalFee);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function harvest() public override onlyKeeper {
        IStrategyLegacy(BUNNY_POOL).getReward();

        uint before = IBEP20(BUNNY).balanceOf(address(this));
        zap.zapInToken(WETH, IBEP20(WETH).balanceOf(address(this)), BUNNY);
        uint harvested = IBEP20(BUNNY).balanceOf(address(this)).sub(before);
        emit Harvested(harvested);

        IStrategyLegacy(BUNNY_POOL).deposit(harvested);
    }

    function withdraw(uint) external override onlyWhitelisted {
        revert("N/A");
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint _amount) external {
        uint amount = Math.min(_amount, _principal[msg.sender]);
        require(amount <= withdrawablePrincipalOf(msg.sender), "VaultBunnyMaximizer: locked");
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        IStrategyLegacy(BUNNY_POOL).withdraw(amount);

        uint depositTimestamp = _depositedAt[msg.sender];
        uint withdrawalFee = _minter.withdrawalFee(amount, depositTimestamp);
        if (withdrawalFee > 0) {
            _stakingToken.safeTransfer(TIMELOCK, withdrawalFee);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function getReward() public override nonReentrant {
        uint amount = earned(msg.sender);
        require(amount <= withdrawableBalanceOf(msg.sender), "VaultBunnyMaximizer: locked");
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        IStrategyLegacy(BUNNY_POOL).withdraw(amount);

        _stakingToken.safeTransfer(msg.sender, amount);
        emit ProfitPaid(msg.sender, amount, 0);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setStakePermission(address _address, bool permission) public onlyOwner {
        _stakePermission[_address] = permission;
    }

    function setMinter(address newMinter) public override onlyOwner {
        setStakePermission(address(_minter), false);
        VaultController.setMinter(newMinter);
        setStakePermission(newMinter, true);
    }

    function setBunnyChef(IBunnyChef _chef) public override onlyOwner {
        require(address(_bunnyChef) == address(0), "VaultBunnyMaximizer: setBunnyChef only once");
        VaultController.setBunnyChef(IBunnyChef(_chef));
    }

    function stakeTo(uint amount, address _to) external canStakeTo {
        _deposit(amount, _to);
        if (msg.sender == presaleContract) {
            _presaleBalance[_to] = _presaleBalance[_to].add(amount);
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _deposit(uint _amount, address _to) private nonReentrant notPaused {
        uint _pool = balance();
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint shares = totalShares == 0 ? _amount : (_amount.mul(totalShares)).div(_pool);

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        IStrategyLegacy(BUNNY_POOL).deposit(_amount);
        emit Deposited(_to, _amount);
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    function recoverToken(address tokenAddress, uint tokenAmount) external override onlyOwner {
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
