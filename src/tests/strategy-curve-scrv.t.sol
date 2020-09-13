pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./hevm.sol";
import "./user.sol";

import "../interfaces/strategy.sol";
import "../interfaces/curve.sol";
import "../interfaces/uniswapv2.sol";

import "../pickle-jar.sol";
import "../controller.sol";
import "../strategies/strategy-curve-scrv.sol";

contract PickleJarTest is DSTest {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address pickle = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;
    address burn = 0x000000000000000000000000000000000000dEaD;

    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address curve = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address scrv = 0xC25a3A3b969415c80451098fa907EC722572917F;
    address crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address snx = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;

    address governance;
    address strategist;
    address rewards;

    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address onesplit = 0xC586BeF4a0992C495Cf22e1aeEE4E446CECDee0E;
    uint256 parts = 2;

    PickleJar pickleJar;
    Controller controller;
    StrategyCurveSCRV strategy;

    Hevm hevm;
    UniswapRouterV2 univ2 = UniswapRouterV2(
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    );

    uint256 startTime = block.timestamp;

    function setUp() public {
        governance = address(this);
        strategist = address(this);
        rewards = address(this);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        controller = new Controller(governance, strategist, rewards);

        strategy = new StrategyCurveSCRV(
            governance,
            strategist,
            address(controller)
        );

        pickleJar = new PickleJar(
            strategy.want(),
            governance,
            address(controller)
        );

        controller.setVault(strategy.want(), address(pickleJar));
        controller.approveStrategy(strategy.want(), address(strategy));
        controller.setStrategy(strategy.want(), address(strategy));

        hevm.warp(startTime);
    }

    function _swap(
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        // Onesplit params
        uint256 expected;
        uint256[] memory distribution;

        uint256 value = 0;

        if (_from != eth) {
            IERC20(_from).safeApprove(onesplit, 0);
            IERC20(_from).safeApprove(onesplit, _amount);
        } else {
            value = _amount;
        }

        (expected, distribution) = OneSplitAudit(onesplit).getExpectedReturn(
            _from,
            _to,
            _amount,
            parts,
            0
        );

        OneSplitAudit(onesplit).swap{value: value}(
            _from,
            _to,
            _amount,
            parts,
            distribution,
            0
        );
    }

    function _getDAI(uint256 _amount) internal {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = dai;

        uint256[] memory ins = univ2.getAmountsIn(_amount, path);
        uint256 ethAmount = ins[0];

        univ2.swapETHForExactTokens{value: ethAmount}(
            _amount,
            path,
            address(this),
            now + 60
        );
    }

    function _getSCRV(uint256 daiAmount) internal {
        _getDAI(daiAmount);
        uint256[4] memory liquidity;
        liquidity[0] = IERC20(dai).balanceOf(address(this));
        IERC20(dai).approve(curve, liquidity[0]);
        ICurveFi(curve).add_liquidity(liquidity, 0);
    }

    // **** Tests ****

    function test_swap() public {
        address to = dai;

        uint256 _before = IERC20(to).balanceOf(address(this));
        _swap(eth, to, 1 ether);
        uint256 _after = IERC20(to).balanceOf(address(this));

        assertTrue(_after > _before);
    }

    function test_add_liquidity() public {
        uint256 _before = IERC20(scrv).balanceOf(address(this));

        // Swap some DAI and add to liquidity pool
        _swap(eth, dai, 1 ether);
        uint256[4] memory liquidity;
        liquidity[0] = IERC20(dai).balanceOf(address(this));
        IERC20(dai).approve(curve, liquidity[0]);
        ICurveFi(curve).add_liquidity(liquidity, 0);

        uint256 _after = IERC20(scrv).balanceOf(address(this));

        assertTrue(_after > _before);
    }

    function test_deposit() public {
        // Get some sCRV
        _getSCRV(5 ether);
        uint256 _scrv = IERC20(scrv).balanceOf(address(this));

        // Deposit into pickle jar
        uint256 _before = pickleJar.balanceOf(address(this));
        IERC20(scrv).approve(address(pickleJar), _scrv);
        pickleJar.deposit(_scrv);
        uint256 _after = pickleJar.balanceOf(address(this));

        // More balance than when we started
        assertTrue(_after > _before);
    }

    function test_earn() public {
        // Get some sCRV
        _getSCRV(5 ether);
        uint256 _scrv = IERC20(scrv).balanceOf(address(this));
        IERC20(scrv).approve(address(pickleJar), _scrv);
        pickleJar.deposit(_scrv);
        pickleJar.earn(); // Once earn is called, it should be deposited
    }

    function test_harvest_strategy() public {
        // Deposit sCRV, and earn
        _getSCRV(1000000 ether); // 1 million DAI
        uint256 _scrv = IERC20(scrv).balanceOf(address(this));
        IERC20(scrv).approve(address(pickleJar), _scrv);
        pickleJar.deposit(_scrv);
        pickleJar.earn();

        // Fast forward one week
        hevm.warp(block.timestamp + 1 weeks);

        // Call the harvest function
        uint256 _before = pickleJar.balance();
        strategy.harvest();
        uint256 _after = pickleJar.balance();

        assertTrue(_after > _before);
    }

    function test_harvest_strategy_rewards() public {
        User user = new User();

        // Deposit sCRV, and earn
        _getSCRV(1000000 ether); // 1 million DAI
        uint256 _scrv = IERC20(scrv).balanceOf(address(this));
        IERC20(scrv).approve(address(pickleJar), _scrv);
        pickleJar.deposit(_scrv);
        pickleJar.earn();
        (address to, ) = strategy.getMostPremiumStablecoin();

        // Fast forward one week
        hevm.warp(block.timestamp + 1 weeks);

        // Call the harvest function
        uint256 _before = pickleJar.balance();
        uint256 _userBefore = IERC20(to).balanceOf(address(user));
        uint256 _picklesBefore = IERC20(pickle).balanceOf(burn);
        uint256 _rewardsBefore = IERC20(scrv).balanceOf(rewards);
        user.execute(address(strategy), 0, "harvest()", "");
        uint256 _after = pickleJar.balance();
        uint256 _userAfter = IERC20(to).balanceOf(address(user));
        uint256 _picklesAfter = IERC20(pickle).balanceOf(burn);
        uint256 _rewardsAfter = IERC20(scrv).balanceOf(rewards);

        uint256 earned = _after.sub(_before).mul(1000).div(970);
        uint256 earnedRewards = earned.mul(3).div(100); // 3%
        uint256 actualRewardsEarned = _rewardsAfter.sub(_rewardsBefore);

        // Allow errors up to 6 decimal places
        actualRewardsEarned = actualRewardsEarned.div(1e6).mul(1e6);
        earnedRewards = earnedRewards.div(1e6).mul(1e6);

        // 3 % performance fee is given
        assertTrue(earnedRewards == actualRewardsEarned);

        // Caller is given some stablecoin as gas compensation
        assertTrue(_userAfter > _userBefore);

        // Pickles are burned
        assertTrue(_picklesAfter > _picklesBefore);

        // Shares have appreciated
        assertTrue(_after > _before);
    }
}
