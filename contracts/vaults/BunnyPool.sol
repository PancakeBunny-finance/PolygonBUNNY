// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../library/RewardsDistributionRecipientUpgradeable.sol";
import "../library/PausableUpgradeable.sol";

import "../interfaces/legacy/IStrategyHelper.sol";
import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/legacy/IStrategyLegacy.sol";
import "../interfaces/IPriceCalculator.sol";

contract BunnyPool is
    IStrategyLegacy,
    RewardsDistributionRecipientUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ========== */

    address public constant ETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address private constant BUNNY_MAXIMIZER = 0x4Ad69DC9eA7Cc01CE13A37F20817baC4bF0De1ba;

    IBEP20 public constant stakingToken = IBEP20(0x4C16f69302CcB511c5Fac682c7626B9eF0Dc126a);
    IPancakeRouter02 private constant QUICK_ROUTER = IPancakeRouter02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xE3B11c3Bd6d90CfeBBb4FB9d59486B0381D38021);

    /* ========== STATE VARIABLES ========== */

    IBEP20 public rewardsToken; // bunny/bnb flip
    uint public periodFinish;
    uint public rewardRate;
    uint public rewardsDuration;
    uint public lastUpdateTime;
    uint public rewardPerTokenStored;

    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public rewards;

    uint private _totalSupply;
    mapping(address => uint) private _balances;
    mapping(address => bool) private _whitelist;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __RewardsDistributionRecipient_init();
        __ReentrancyGuard_init();
        __PausableUpgradeable_init();

        periodFinish = 0;
        rewardRate = 0;
        rewardsDuration = 90 days;

        rewardsDistribution = msg.sender;

        IBEP20(ETH).safeApprove(address(QUICK_ROUTER), uint(-1));
        stakingToken.safeApprove(address(QUICK_ROUTER), uint(-1));
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyValidator() {
        require(msg.sender == tx.origin
            || _whitelist[msg.sender], "BunnyPool: only whitelist");
        _;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint) {
        return _totalSupply;
    }

    function balance() external view override returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint) {
        return _balances[account];
    }

    function principalOf(address account) external view override returns (uint) {
        return _balances[account];
    }

    function profitOf(address account)
        public
        view
        override
        returns (
            uint _usd,
            uint _bunny,
            uint _bnb
        )
    {
        _usd = 0;
        _bunny = 0;
        (_bnb, ) = priceCalculator.valueOfAsset(address(rewardsToken), earned(account));
    }

    function tvl() public view override returns (uint) {
        (uint priceInBNB, ) = priceCalculator.valueOfAsset(address(stakingToken), _totalSupply);
        return priceInBNB;
    }

    function apy()
        public
        view
        override
        returns (
            uint _usd,
            uint _bunny,
            uint _bnb
        )
    {
        uint tokenDecimals = 1e18;
        uint __totalSupply = _totalSupply;
        if (__totalSupply == 0) {
            __totalSupply = tokenDecimals;
        }

        uint rewardPerTokenPerSecond = rewardRate.mul(tokenDecimals).div(__totalSupply);
        (uint bunnyPrice, ) = priceCalculator.valueOfAsset(address(stakingToken), 1e18);
        (uint flipPrice, ) = priceCalculator.valueOfAsset(address(rewardsToken), 1e18);

        _usd = 0;
        _bunny = 0;
        _bnb = rewardPerTokenPerSecond.mul(365 days).mul(flipPrice).div(bunnyPrice);
    }

    function lastTimeRewardApplicable() public view returns (uint) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public override view returns (uint) {
        return
            _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(
                rewards[account]
            );
    }

    function getRewardForDuration() external view returns (uint) {
        return rewardRate.mul(rewardsDuration);
    }

    function isWhitelist(address account) public view returns (bool) {
        return _whitelist[account];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint amount) public override onlyValidator {
        _deposit(amount, msg.sender);
    }

    function depositAll() external override onlyValidator {
        deposit(stakingToken.balanceOf(msg.sender));
    }

    function withdraw(uint amount) public override nonReentrant onlyValidator updateReward(msg.sender) {
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawAll() external override onlyValidator {
        uint _withdraw = _balances[msg.sender];
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        getReward();
    }

    function getReward() public override nonReentrant onlyValidator updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            reward = _flipToWETH(reward);
            IBEP20(ETH).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }



    function harvest() external override {}

    /* ========== PRIVATE FUNCTIONS ========== */

    function _deposit(uint amount, address _to) private nonReentrant notPaused updateReward(_to) {
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(_to, amount);
    }

    function _flipToWETH(uint amount) private returns (uint reward) {
        (uint rewardBunny, ) = QUICK_ROUTER.removeLiquidity(
            address(stakingToken),
            ETH,
            amount,
            0,
            0,
            address(this),
            block.timestamp
        );
        address[] memory path = new address[](2);
        path[0] = address(stakingToken);
        path[1] = ETH;
        QUICK_ROUTER.swapExactTokensForTokens(rewardBunny, 0, path, address(this), block.timestamp);

        reward = IBEP20(ETH).balanceOf(address(this));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setRewardsToken(address _rewardsToken) external onlyOwner {
        require(address(rewardsToken) == address(0), "set rewards token already");

        rewardsToken = IBEP20(_rewardsToken);
        IBEP20(_rewardsToken).safeApprove(address(QUICK_ROUTER), uint(-1));
    }

    function notifyRewardAmount(uint reward) external override onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint remaining = periodFinish.sub(block.timestamp);
            uint leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint _balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "reward");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function recoverBEP20(address tokenAddress, uint tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken) && tokenAddress != address(rewardsToken), "tokenAddress");
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "period");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function setWhitelist(address _address, bool _on) external onlyOwner {
        _whitelist[_address] = _on;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint reward);
    event Staked(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);
    event RewardPaid(address indexed user, uint reward);
    event RewardsDurationUpdated(uint newDuration);
    event Recovered(address token, uint amount);
}
