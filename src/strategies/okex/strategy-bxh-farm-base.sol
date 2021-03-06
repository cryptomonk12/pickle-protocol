// SPDX-License-Identifier: MIT
pragma solidity ^0.6.7;

import "./strategy-base.sol";
import "../../interfaces/bxh-chef.sol";

abstract contract StrategyBxhFarmBase is StrategyBase {
    // Token addresses
    address public constant bxh = 0x145aD28A42bF334104610F7836D0945Dffb6DE63;
    address public constant bxhChef =
        0x006854D77b0710859Ba68b98d2c992ea2837c382;
    address public bxhRouter = 0x56cdDEAa7344498a24E3303333DCAa46fDeD1707;

    // <token0>/<token1> pair
    address public token0;
    address public token1;

    uint256 public poolId;
    mapping (address => address[]) public uniswapRoutes;

    constructor(
        address _token0,
        address _token1,
        uint256 _poolId,
        address _lp,
        address _governance,
        address _strategist,
        address _controller,
        address _timelock
    )
        public
        StrategyBase(_lp, _governance, _strategist, _controller, _timelock)
    {
        poolId = _poolId;
        token0 = _token0;
        token1 = _token1;
        sushiRouter = bxhRouter; //use BXH router instead of sushi router
    }

    function balanceOfPool() public view override returns (uint256) {
        (uint256 amount, , ) = IBxhChef(bxhChef).userInfo(
            poolId,
            address(this)
        );
        return amount;
    }

    function getHarvestable() external view returns (uint256) {
        (uint256 pending, ) = IBxhChef(bxhChef).pending(poolId, address(this));
        return pending;
    }

    // **** Setters ****

    function deposit() public override {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeApprove(bxhChef, 0);
            IERC20(want).safeApprove(bxhChef, _want);
            IBxhChef(bxhChef).deposit(poolId, _want);
        }
    }

    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        IBxhChef(bxhChef).withdraw(poolId, _amount);
        return _amount;
    }

    // **** State Mutations ****

    function harvest() public virtual override onlyBenevolent {
        // Anyone can harvest it at any given time.
        // I understand the possibility of being frontrun
        // But ETH is a dark forest, and I wanna see how this plays out
        // i.e. will be be heavily frontrunned?
        //      if so, a new strategy will be deployed.

        // Collects BXH tokens
        IBxhChef(bxhChef).deposit(poolId, 0);
        uint256 _bxh = IERC20(bxh).balanceOf(address(this));

        if (_bxh > 0) {
            uint256 toToken0 = _bxh.div(2);
            uint256 toToken1 = _bxh.sub(toToken0);

            if (uniswapRoutes[token0].length > 1) {
                _swapSushiswapWithPath(uniswapRoutes[token0], toToken0);
            }
            if (uniswapRoutes[token1].length > 1) {
                _swapSushiswapWithPath(uniswapRoutes[token1], toToken1);
            }
        }

        // Adds in liquidity for token0/token1
        uint256 _token0 = IERC20(token0).balanceOf(address(this));
        uint256 _token1 = IERC20(token1).balanceOf(address(this));

        if (_token0 > 0 && _token1 > 0) {
            IERC20(token0).safeApprove(sushiRouter, 0);
            IERC20(token0).safeApprove(sushiRouter, _token0);
            IERC20(token1).safeApprove(sushiRouter, 0);
            IERC20(token1).safeApprove(sushiRouter, _token1);

            UniswapRouterV2(sushiRouter).addLiquidity(
                token0,
                token1,
                _token0,
                _token1,
                0,
                0,
                address(this),
                now + 60
            );

            // Donates DUST
            IERC20(token0).transfer(
                IController(controller).treasury(),
                IERC20(token0).balanceOf(address(this))
            );
            IERC20(token1).safeTransfer(
                IController(controller).treasury(),
                IERC20(token1).balanceOf(address(this))
            );
        }

        _distributePerformanceFeesAndDeposit();
    }
}
