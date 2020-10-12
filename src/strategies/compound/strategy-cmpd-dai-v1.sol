// SPDX-License-Identifier: MIT
pragma solidity ^0.6.2;

import "../../lib/erc20.sol";
import "../../lib/safe-math.sol";
import "../../lib/exponential.sol";

import "../strategy-base.sol";

import "../../interfaces/jar.sol";
import "../../interfaces/uniswapv2.sol";
import "../../interfaces/controller.sol";
import "../../interfaces/compound.sol";

contract StrategyCmpdDaiV1 is StrategyBase, Exponential {
    address
        public constant comptroller = 0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B;
    address public constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant comp = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address public constant cdai = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    address public constant cether = 0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5;

    // Safety parameters
    // 10% buffer allowed when leveraging
    uint256 colRatioLeverageBuffer = 100;
    uint256 colRatioLeverageBufferMax = 1000;

    // Keeper bots
    // Maintain leverage within buffer
    mapping(address => bool) keepers;

    constructor(
        address _governance,
        address _strategist,
        address _controller,
        address _timelock
    )
        public
        StrategyBase(dai, _governance, _strategist, _controller, _timelock)
    {
        // Enter cDAI Market
        address[] memory ctokens = new address[](1);
        ctokens[0] = cdai;
        IComptroller(comptroller).enterMarkets(ctokens);
    }

    // **** Modifiers **** //

    modifier onlyKeepers {
        require(
            keepers[msg.sender] ||
                msg.sender == address(this) ||
                msg.sender == strategist ||
                msg.sender == governance,
            "!keepers"
        );
        _;
    }

    // **** Views **** //

    function getName() external override pure returns (string memory) {
        return "StrategyCompoundDaiV1";
    }

    function getSuppliedView() public view returns (uint256) {
        (, uint256 cTokenBal, , uint256 exchangeRate) = ICToken(cdai)
            .getAccountSnapshot(address(this));

        (, uint256 bal) = mulScalarTruncate(
            Exp({mantissa: exchangeRate}),
            cTokenBal
        );

        return bal;
    }

    function getBorrowedView() public view returns (uint256) {
        return ICToken(cdai).borrowBalanceStored(address(this));
    }

    function balanceOfPool() public override view returns (uint256) {
        uint256 supplied = getSuppliedView();
        uint256 borrowed = getBorrowedView();
        return supplied.sub(borrowed);
    }

    // Given an unleveraged supply balance, return the target
    // leveraged supply balance which is still within the safety buffer
    function getLeveragedSupplyTarget(uint256 supplyBalance)
        public
        view
        returns (uint256)
    {
        uint256 leverage = getMaxLeverage();
        return supplyBalance.mul(leverage).div(1e18);
    }

    function getSafeColRatio() public view returns (uint256) {
        (, uint256 colFactor) = IComptroller(comptroller).markets(cdai);

        // Collateral factor within the buffer
        uint256 safeColFactor = colFactor.sub(
            colRatioLeverageBuffer.mul(1e18).div(colRatioLeverageBufferMax)
        );

        return safeColFactor;
    }

    // Max leverage we can go up to, w.r.t safe buffer
    function getMaxLeverage() public view returns (uint256) {
        uint256 safeColFactor = getSafeColRatio();

        // Infinite geometric series
        uint256 leverage = 1e36 / (1e18 - safeColFactor);
        return leverage;
    }

    // **** Pseudo-view functions (use `callStatic` on these) **** //
    /* The reason why these exists is because of the nature of the
       interest accruing supply + borrow balance. The "view" methods
       are technically snapshots and don't represent the real value.
       As such there are pseudo view methods where you can retrieve the
       results by calling `callStatic`.
    */

    function getCompAccruedBorrow() public returns (uint256) {
        // https://github.com/compound-finance/compound-protocol/blob/master/contracts/ComptrollerG4.sol#L1163

        // Borrow
        (uint224 borrowedStateIndex, uint32 borrowedStateBlock) = IComptroller(
            comptroller
        )
            .compBorrowState(cdai);
        Exp memory marketBorrowIndex = Exp({
            mantissa: ICToken(cdai).borrowIndex()
        });
        uint256 borrowSpeed = IComptroller(comptroller).compSpeeds(cdai);
        uint256 borrowDeltaBlocks = block.number.sub(
            uint256(borrowedStateBlock)
        );

        if (borrowDeltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(
                ICToken(cdai).totalBorrows(),
                marketBorrowIndex
            );
            uint256 compAccrued = mul_(borrowDeltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(compAccrued, borrowAmount)
                : Double({mantissa: 0});
            Double memory borrowIndex = add_(
                Double({mantissa: borrowedStateIndex}),
                ratio
            );
            Double memory borrowerIndex = Double({
                mantissa: IComptroller(comptroller).compBorrowerIndex(
                    cdai,
                    address(this)
                )
            });

            if (borrowerIndex.mantissa > 0) {
                Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
                uint256 borrowerAmount = div_(
                    ICToken(cdai).borrowBalanceStored(address(this)),
                    marketBorrowIndex
                );
                uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);
                uint256 borrowerAccrued = add_(
                    IComptroller(comptroller).compAccrued(address(this)),
                    borrowerDelta
                );

                return borrowerAccrued;
            }
        }

        return 0;
    }

    function getCompAccruedSupply() public returns (uint256) {
        // https://github.com/compound-finance/compound-protocol/blob/master/contracts/ComptrollerG4.sol#L1140
        uint224 compInitialIndex = 1e36;

        // Supply
        (uint224 supplyStateIndex, uint32 supplyStateBlock) = IComptroller(
            comptroller
        )
            .compSupplyState(cdai);
        uint256 supplySpeed = IComptroller(comptroller).compSpeeds(cdai);
        uint256 supplyDeltaBlocks = block.number.sub(uint256(supplyStateBlock));

        if (supplyDeltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = ICToken(cdai).totalSupply();
            uint256 compAccrued = mul_(supplyDeltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(compAccrued, supplyTokens)
                : Double({mantissa: 0});
            Double memory supplyIndex = add_(
                Double({mantissa: supplyStateIndex}),
                ratio
            );
            Double memory supplierIndex = Double({
                mantissa: IComptroller(comptroller).compSupplierIndex(
                    cdai,
                    address(this)
                )
            });

            if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
                supplierIndex.mantissa = compInitialIndex;
            }

            Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
            uint256 supplierTokens = ICToken(cdai).balanceOf(address(this));
            uint256 supplierDelta = mul_(supplierTokens, deltaIndex);
            uint256 supplierAccrued = add_(
                IComptroller(comptroller).compAccrued(address(this)),
                supplierDelta
            );

            return supplierAccrued;
        }

        return 0;
    }

    function getCompAccrued() public returns (uint256) {
        uint256 borrowAccrued = getCompAccruedBorrow();
        uint256 supplyAccrued = getCompAccruedSupply();
        return borrowAccrued.add(supplyAccrued);
    }

    function getColRatio() public returns (uint256) {
        uint256 supplied = getSupplied();
        uint256 borrowed = getBorrowed();

        return borrowed.mul(1e18).div(supplied);
    }

    function getSuppliedUnleveraged() public returns (uint256) {
        uint256 supplied = getSupplied();
        uint256 borrowed = getBorrowed();

        return supplied.sub(borrowed);
    }

    function getSupplied() public returns (uint256) {
        return ICToken(cdai).balanceOfUnderlying(address(this));
    }

    function getBorrowed() public returns (uint256) {
        return ICToken(cdai).borrowBalanceCurrent(address(this));
    }

    function getBorrowable() public returns (uint256) {
        uint256 supplied = getSupplied();
        uint256 borrowed = getBorrowed();

        (, uint256 colFactor) = IComptroller(comptroller).markets(cdai);

        // 99.99% just in case some dust accumulates
        return
            supplied.mul(colFactor).div(1e18).sub(borrowed).mul(9999).div(
                10000
            );
    }

    function getCurrentLeverage() public returns (uint256) {
        uint256 supplied = getSupplied();
        uint256 borrowed = getBorrowed();

        return supplied.mul(1e18).div(supplied.sub(borrowed));
    }

    // **** Setters **** //

    function addKeeper(address _keeper) public {
        require(
            msg.sender == governance || msg.sender == strategist,
            "!governance"
        );
        keepers[_keeper] = true;
    }

    function removeKeeper(address _keeper) public {
        require(
            msg.sender == governance || msg.sender == strategist,
            "!governance"
        );
        keepers[_keeper] = false;
    }

    function setColRatioLeverageBuffer(uint256 _colRatioLeverageBuffer) public {
        require(
            msg.sender == governance || msg.sender == strategist,
            "!governance"
        );
        colRatioLeverageBuffer = _colRatioLeverageBuffer;
    }

    // **** State mutations **** //

    function maxLeverage() public {
        uint256 unleveragedSupply = getSuppliedUnleveraged();
        uint256 idealSupply = getLeveragedSupplyTarget(unleveragedSupply);
        leverageUntil(idealSupply);
    }

    // Leverages until we're supplying <x> amount
    // 1. Redeem <x> DAI
    // 2. Repay <x> DAI
    function leverageUntil(uint256 _supplyAmount) public onlyKeepers {
        // 1. Borrow out <X> DAI
        // 2. Supply <X> DAI

        uint256 leverage = getMaxLeverage();
        uint256 unleveragedSupply = getSuppliedUnleveraged();
        require(
            _supplyAmount >= unleveragedSupply &&
                _supplyAmount <= unleveragedSupply.mul(leverage).div(1e18),
            "!leverage"
        );

        // Since we're only leveraging one asset
        // Supplied = borrowed
        uint256 _borrowAndSupply;
        uint256 supplied = getSupplied();
        while (supplied < _supplyAmount) {
            _borrowAndSupply = getBorrowable();

            if (supplied.add(_borrowAndSupply) > _supplyAmount) {
                _borrowAndSupply = _supplyAmount.sub(supplied);
            }

            ICToken(cdai).borrow(_borrowAndSupply);
            deposit();

            supplied = supplied.add(_borrowAndSupply);
        }
    }

    function maxDeleverage() public {
        uint256 unleveragedSupply = getSuppliedUnleveraged();
        deleverageUntil(unleveragedSupply);
    }

    // Deleverages until we're supplying <x> amount
    // 1. Redeem <x> DAI
    // 2. Repay <x> DAI
    function deleverageUntil(uint256 _supplyAmount) public onlyKeepers {
        uint256 unleveragedSupply = getSuppliedUnleveraged();
        uint256 supplied = getSupplied();
        require(
            _supplyAmount >= unleveragedSupply && _supplyAmount <= supplied,
            "!deleverage"
        );

        // Since we're only leveraging on 1 asset
        // redeemable = borrowable
        uint256 _redeemAndRepay = getBorrowable();
        do {
            if (supplied.sub(_redeemAndRepay) < _supplyAmount) {
                _redeemAndRepay = supplied.sub(_supplyAmount);
            }

            ICToken(cdai).redeemUnderlying(_redeemAndRepay);
            IERC20(dai).safeApprove(cdai, 0);
            IERC20(dai).safeApprove(cdai, _redeemAndRepay);
            ICToken(cdai).repayBorrow(_redeemAndRepay);

            supplied = supplied.sub(_redeemAndRepay);
        } while (supplied > _supplyAmount);
    }

    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        uint256 _want = balanceOfWant();
        if (_want < _amount) {
            // Make sure market can cover liquidity
            require(ICToken(cdai).getCash() >= _amount, "!cash-liquidity");

            // How much borrowed amount do we need to free?
            uint256 borrowed = getBorrowed();
            uint256 supplied = getSupplied();
            uint256 curLeverage = getCurrentLeverage();
            uint256 borrowedToBeFree = _amount.sub(_want).mul(curLeverage).div(
                1e18
            );

            // If the amount we need to free is > borrowed
            // Just free up all the borrowed amount
            if (borrowedToBeFree > borrowed) {
                this.maxDeleverage();
            } else {
                // Otherwise just keep freeing up borrowed amounts until
                // we hit a safe number to redeem our underlying
                this.deleverageUntil(supplied.sub(borrowedToBeFree));
            }

            // Redeems underlying
            ICToken(cdai).redeemUnderlying(_amount.sub(_want));
        }

        return _amount;
    }

    function harvest() public override onlyBenevolent {
        address[] memory ctokens = new address[](1);
        ctokens[0] = cdai;

        IComptroller(comptroller).claimComp(address(this), ctokens);
        uint256 _comp = IERC20(comp).balanceOf(address(this));
        if (_comp > 0) {
            _swapUniswap(comp, want, _comp);
        }

        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            // Fees 4.5% goes to treasury
            IERC20(want).safeTransfer(
                IController(controller).treasury(),
                _want.mul(performanceFee).div(performanceMax)
            );

            deposit();
        }
    }

    function deposit() public override {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeApprove(cdai, 0);
            IERC20(want).safeApprove(cdai, _want);
            ICToken(cdai).mint(_want);
        }
    }
}
