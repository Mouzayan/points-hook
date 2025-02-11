// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * v4 uses transient storage which is only available after Ethereum's cancun
 * hard fork and on Solidity versions >= 0.8.24
 *
 * We have a memecoin-type coin called TOKEN.
 * We want to attach our hook into ETH <> TOKEN pools.
 * Goal is to:
 * - incentivize swappers to buy TOKEN in exchange for ETH
 * - and for LPs to add liquidity to our pool
 * This incentivization happens through the hook issuing a second POINTS
 * token when desired actions occur.
 *
 * Rules:
 * 1. When a swap takes place which buys TOKEN for ETH - we will issue POINTS
 * equivalent to 20% the amount of how much ETH was swapped in to the user
 *
 * 2. When someone adds liquidity, we will issue POINTS equivalent to how much
 * ETH they added
 *
 * For Case (1) - minting POINTS in case of swaps, we know we will need to use `afterSwap`
 * For Case (2) - the `afterAddLiquidity` hook also gives an additional `BalanceDelta` delta input
 *
 * Final code by Haardik:
 * https://github.com/haardikk21/points-hook
 */
contract PointsHook is BaseHook, ERC20 {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    constructor(IPoolManager _manager, string memory _name, string memory _symbol)
        BaseHook(_manager)
        ERC20(_name, _symbol, 18)
    {}

    // hook permissions to return `true` for
    // the two hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Make sure this is an ETH - TOKEN pool
    // Make sure this swap is to buy TOKEN in exchange for ETH
    // Mint points equal to 20% of the amount of ETH being swapped in
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since its a zeroForOne swap:
        // if amountSpecified < 0:
        //      this is an "exact input for output" swap
        //      amount of ETH they spent is equal to |amountSpecified|
        // if amountSpecified > 0:
        //      this is an "exact output for input" swap
        //      amount of ETH they spent is equal to BalanceDelta.amount0()
        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        // mint the points
        _assignPoints(hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, delta);

        // Mint points equivalent to how much ETH they're adding in liquidity
        uint256 pointsForAddingLiquidity = uint256(int256(-delta.amount0()));

        // Mint the points
        _assignPoints(hookData, pointsForAddingLiquidity);

        return (this.afterAddLiquidity.selector, delta);
    }

    function _assignPoints(bytes calldata hookData, uint256 points) internal {
        // If no hookData is passed in, no points will be assigned to anyone
        if (hookData.length == 0) return;

        // Extract user address from hookData
        address user = abi.decode(hookData, (address));

        // If there is hookData but not in the format we're expecting and user address is zero
        // nobody gets any points
        if (user == address(0)) return;

        // Mint points to the user
        _mint(user, points);
    }
}
