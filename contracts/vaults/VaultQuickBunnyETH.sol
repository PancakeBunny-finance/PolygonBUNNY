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

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import { PoolConstant } from "../library/PoolConstant.sol";
import "../interfaces/IPancakePair.sol";
import "../interfaces/IPancakeFactory.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IMasterChef.sol";
import "../interfaces/IBunnyMinter.sol";
import "../interfaces/IQuickStakingRewards.sol";
import "../interfaces/IPresale.sol";
import "../interfaces/IZap.sol";

import "./VaultController.sol";

contract VaultQuickBunnyETH is VaultController, IStrategy {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint;

    /* ========== CONSTANTS ============= */

    address private constant BUNNY = 0x4C16f69302CcB511c5Fac682c7626B9eF0Dc126a; // BUNNY
    address private constant ETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619; // ETH
    address private constant BUNNY_ETH = 0x62052b489Cb5bC72a9DC8EEAE4B24FD50639921a; // QUICK Swap
    address private constant presaleContract = 0x172B554118ecd915C5F046819cA225351566566E;

    IBEP20 private constant QUICK = IBEP20(0x831753DD7087CaC61aB5644b308642cc1c33Dc13);
    IZap public constant zap = IZap(0x663462430834E220851a3E981D0E1199501b84F6);
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.FlipToFlip;

    uint private constant DUST = 1000;
    uint private constant timestamp2HoursAfterPresaleEnds = 1625097600 + (2 hours);
    uint private constant timestamp90DaysAfterPresaleEnds = 1625097600 + (90 days);

    /* ========== STATE VARIABLES ========== */

    uint public totalShares;
    uint public totalBalance;
    mapping(address => uint) private _shares;
    mapping(address => uint) private _principal;
    mapping(address => uint) private _depositedAt;

    IQuickStakingRewards private qVault;

    uint public override pid; // unused

    /* ========== PRESALE ============== */

    mapping(address => uint) private _presaleBalance;

    /* ========== EVENTS ========== */

    event RewardAdded(uint reward);
    event RewardsDurationUpdated(uint newDuration);

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __VaultController_init(IBEP20(BUNNY_ETH));

        QUICK.safeApprove(address(zap), uint(-1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setMinter(address newMinter) public override onlyOwner {
        VaultController.setMinter(newMinter);
    }

    function setBunnyChef(IBunnyChef _chef) public override onlyOwner {
        require(address(_bunnyChef) == address(0), "VaultBunnyETH: setBunnyChef only once");
        VaultController.setBunnyChef(IBunnyChef(_chef));
    }

    function stakeTo(uint amount, address _to) external {
        if (msg.sender == presaleContract) {
            _depositTo(amount, _to);
            _presaleBalance[_to] = _presaleBalance[_to].add(amount);
        }
    }

    function setQuickVault(address _qVault) public onlyOwner {
        require(address(qVault) == address(0), "VaultBunnyETH: qVault already set");
        qVault = IQuickStakingRewards(_qVault);
        _stakingToken.safeApprove(_qVault, uint(-1));

        qVault.stake(totalBalance);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function balance() public view override returns (uint amount) {
        if (address(qVault) == address(0)) {
            amount = totalBalance;
        } else {
            amount = qVault.balanceOf(address(this));
        }
    }

    function balanceOf(address account) public view override returns (uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        if (block.timestamp > timestamp90DaysAfterPresaleEnds) {
            // unlock all presale bunny after 90 days of presale
            return balanceOf(account);
        } else if (block.timestamp < timestamp2HoursAfterPresaleEnds) {
            return balanceOf(account).sub(_presaleBalance[account]);
        } else {
            uint soldInPresale = IPresale(presaleContract).totalBalance().mul(3).div(2);
            uint bunnySupply = IBEP20(BUNNY).totalSupply().mul(100).div(115);

            if (soldInPresale >= bunnySupply) {
                return balanceOf(account).sub(_presaleBalance[account]);
            }

            uint bunnyNewMint = bunnySupply.sub(soldInPresale);
            if (bunnyNewMint >= soldInPresale) {
                return balanceOf(account);
            }

            uint lockedRatio = (soldInPresale.sub(bunnyNewMint)).mul(1e18).div(soldInPresale);
            uint lockedBalance = _presaleBalance[account].mul(lockedRatio).div(1e18);
            return balanceOf(account).sub(lockedBalance);
        }
    }

    function withdrawablePrincipalOf(address account) public view returns (uint) {
        if (block.timestamp > timestamp90DaysAfterPresaleEnds) {
            // unlock all presale bunny after 90 days from presale End
            return balanceOf(account);
        } else if (block.timestamp < timestamp2HoursAfterPresaleEnds) {
            // only withdrawable balance of after presale
            return balanceOf(account).sub(_presaleBalance[account]);
        } else {
            // bunny in presale * 150%
            uint soldInPresale = IPresale(presaleContract).totalBalance().mul(3).div(2);
            uint bunnySupply = IBEP20(BUNNY).totalSupply().mul(100).div(115);

            if (soldInPresale >= bunnySupply) {
                return principalOf(account).sub(_presaleBalance[account]);
            }

            // new bunny minted after presale
            uint bunnyNewMint = bunnySupply.sub(soldInPresale);
            if (bunnyNewMint >= soldInPresale) {
                return balanceOf(account);
            }

            uint lockedRatio = (soldInPresale.sub(bunnyNewMint)).mul(1e18).div(soldInPresale);
            uint lockedBalance = _presaleBalance[account].mul(lockedRatio).div(1e18);
            return principalOf(account).sub(lockedBalance);
        }
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
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
        return address(_stakingToken);
    }

    function priceShare() external view override returns (uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint _amount) public override {
        _depositTo(_amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        uint amount = balanceOf(msg.sender);
        require(amount <= withdrawableBalanceOf(msg.sender), "VaultBunnyETH: locked");
        uint principal = principalOf(msg.sender);
        uint depositTimestamp = _depositedAt[msg.sender];

        uint shares = _shares[msg.sender];
        _bunnyChef.notifyWithdrawn(msg.sender, shares);
        totalShares = totalShares.sub(shares);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        amount = _withdrawTokenWithCorrection(amount);

        uint profit = amount > principal ? amount.sub(principal) : 0;

        uint withdrawalFee = canMint() ? _minter.withdrawalFee(principal, depositTimestamp) : 0;
        uint performanceFee = canMint() ? _minter.performanceFee(profit) : 0;

        if (address(qVault) == address(0)) {
            totalBalance = totalBalance.sub(amount);
        }

        if (canMint()) {
            if (withdrawalFee.add(performanceFee) > DUST) {
                _minter.mintForV2(address(_stakingToken), withdrawalFee, performanceFee, msg.sender, depositTimestamp);

                if (performanceFee > 0) {
                    emit ProfitPaid(msg.sender, profit, performanceFee);
                }
                amount = amount.sub(withdrawalFee).sub(performanceFee);
            }
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);

        uint bunnyAmount = _bunnyChef.safeBunnyTransfer(msg.sender);
        emit BunnyPaid(msg.sender, bunnyAmount, 0);
    }

    function harvest() external override onlyKeeper {
        if (address(qVault) == address(0)) return;

        uint quickHarvested = _harvest();

        uint before = _stakingToken.balanceOf(address(this));
        zap.zapInToken(address(QUICK), quickHarvested, address(_stakingToken));
        uint harvested = _stakingToken.balanceOf(address(this)).sub(before);

        qVault.stake(harvested);
        emit Harvested(harvested);
    }

    function withdraw(uint) external override onlyWhitelisted {
        revert("N/A");
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint _amount) external {
        uint amount = Math.min(_amount, _principal[msg.sender]);
        require(amount <= withdrawablePrincipalOf(msg.sender), "VaultBunnyETH: locked");
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        _bunnyChef.notifyWithdrawn(msg.sender, shares);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        amount = _withdrawTokenWithCorrection(amount);

        if (address(qVault) == address(0)) {
            totalBalance = totalBalance.sub(amount);
        }

        uint depositTimestamp = _depositedAt[msg.sender];
        uint withdrawalFee = canMint() ? _minter.withdrawalFee(amount, depositTimestamp) : 0;

        if (canMint()) {
            if (withdrawalFee > DUST) {
                _minter.mintForV2(address(_stakingToken), withdrawalFee, 0, msg.sender, depositTimestamp);
                amount = amount.sub(withdrawalFee);
            }
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    // @dev profits only (underlying + bunny) + no withdraw fee + perf fee
    function getReward() external override {
        if (address(qVault) != address(0)) {
            uint amount = earned(msg.sender);
            uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
            _bunnyChef.notifyWithdrawn(msg.sender, shares);
            totalShares = totalShares.sub(shares);
            _shares[msg.sender] = _shares[msg.sender].sub(shares);
            _cleanupIfDustShares();

            amount = _withdrawTokenWithCorrection(amount);
            uint depositTimestamp = _depositedAt[msg.sender];
            uint performanceFee = canMint() ? _minter.performanceFee(amount) : 0;

            if (canMint()) {
                if (performanceFee > DUST) {
                    _minter.mintForV2(address(_stakingToken), 0, performanceFee, msg.sender, depositTimestamp);
                    amount = amount.sub(performanceFee);
                }
            }
            _stakingToken.safeTransfer(msg.sender, amount);
            emit ProfitPaid(msg.sender, amount, performanceFee);
        }

        uint bunnyAmount = _bunnyChef.safeBunnyTransfer(msg.sender);
        emit BunnyPaid(msg.sender, bunnyAmount, 0);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _depositTo(uint _amount, address _to) private notPaused {
        if (_amount == 0) return;

        uint _pool = balance();
        uint _before = _stakingToken.balanceOf(address(this));
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint _after = _stakingToken.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        _bunnyChef.updateRewardsOf(address(this));

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        if (address(qVault) != address(0)) {
            qVault.stake(_amount);
        } else {
            totalBalance = totalBalance.add(_amount);
        }
        _bunnyChef.notifyDeposited(_to, shares);
        emit Deposited(_to, _amount);
    }

    function _withdrawTokenWithCorrection(uint amount) private returns (uint) {
        if (amount == 0) return 0;

        if (address(qVault) == address(0)) {
            return amount;
        } else {
            uint before = _stakingToken.balanceOf(address(this));
            qVault.withdraw(amount);
            return _stakingToken.balanceOf(address(this)).sub(before);
        }
    }

    function _harvest() private returns (uint) {
        if (address(qVault) == address(0)) {
            return 0;
        } else {
            uint before = QUICK.balanceOf(address(this));
            qVault.getReward();
            return QUICK.balanceOf(address(this)).sub(before);
        }
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            _bunnyChef.notifyWithdrawn(msg.sender, shares);
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    // @dev stakingToken must not remain balance in this contract. So dev should salvage staking token transferred by mistake.
    function recoverToken(address token, uint amount) external override onlyOwner {
        require(token != address(_stakingToken), "VaultBunnyETH: cannot recover underlying token");

        IBEP20(token).safeTransfer(owner(), amount);
        emit Recovered(token, amount);
    }
}
