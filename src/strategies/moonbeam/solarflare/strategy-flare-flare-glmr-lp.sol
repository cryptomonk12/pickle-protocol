// SPDX-License-Identifier: MIT
pragma solidity ^0.6.7;

import "./strategy-solarflare-farm-base.sol";

contract StrategyFlareFlareGlmrLp is StrategyFlareFarmBase {
    uint256 public flare_glmr_poolId = 0;

    // Token addresses
    address public flare_glmr_lp = 0x26A2abD79583155EA5d34443b62399879D42748A;
    address public flare = 0xE3e43888fa7803cDC7BEA478aB327cF1A0dc11a7;

    constructor(
        address _governance,
        address _strategist,
        address _controller,
        address _timelock
    )
        public
        StrategyStellaFarmBase(
            flare_glmr_lp,
            flare_glmr_poolId,
            _governance,
            _strategist,
            _controller,
            _timelock
        )
    {
        swapRoutes[glmr] = [flare, glmr];
    }

    // **** Views ****

    function getName() external pure override returns (string memory) {
        return "StrategyFlareFlareGlmrLp";
    }
}
