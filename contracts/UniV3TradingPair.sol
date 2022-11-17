// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2; 

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

//import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
/*import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";

import "@openzeppelin/master/contracts/introspection/ERC165.sol";*/

contract UniV3TradingPair is IERC721Receiver {
    
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable owner;
    address public immutable poolToken0;
    address public immutable poolToken1;
    uint24 public immutable FEE;

    uint256 private constant MINT_BURN_SLIPPAGE = 200; // .5% max slippage on order creation

    string public pairName;

    INonfungiblePositionManager public immutable nftManager;

    IUniswapV3Pool public immutable pool;

    struct Order {
        bool side; // true buy 0 for 1, false buy 1 for 0
        int24 tickLower; // lower price tick for position
        int24 tickUpper; // higher price tick for position
        uint256 quantity;
        uint128 liquidity;
        address owner;
        bool active;
    }

    mapping(uint256 => Order) orders;
    
    constructor(
        //IUniswapV3Pool _pool,
        //INonfungiblePositionManager _nftManager
    ) {
        //_registerInterface(IERC721Receiver.onERC721Received.selector);
        //pool = _pool;
        //nftManager = _nftManager;
        pool = IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
        nftManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        pairName = "ETH/USDC";
        owner = msg.sender;
        poolToken0 = IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8).token0();
        poolToken1 = IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8).token1();
        FEE = IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8).fee();
    }

    /*----------------------------------------------------------*/
    /*                     ERC721 ENABLER                       */
    /*----------------------------------------------------------*/

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) public override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /*----------------------------------------------------------*/
    /*                          EVENTS                          */
    /*----------------------------------------------------------*/

    event Open();
    event Close();
    event Increase();
    event Decrease();
    event PriceChanged();

    /*----------------------------------------------------------*/
    /*                  USER FACING FUNCTIONS                   */
    /*----------------------------------------------------------*/

    /// notice: Opens a limit order my minting a LP position on the 0.3% Uniswap v3 Pair
    function createOrder(bool side, int24 tickLower, int24 tickUpper, uint256 quantity) public payable returns (uint256 positionId) {

        address token = side ? poolToken1 : poolToken0; 

        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            quantity
        );

        IERC20(token).safeIncreaseAllowance(
            address(nftManager),
            quantity
        );

        uint128 _liquidity;
        uint256 _amount0;
        uint256 _amount1;

        (
            positionId,
            _liquidity,
            _amount0,
            _amount1
        ) = mintNewPosition(side, tickLower, tickUpper, quantity);

        orders[positionId] = Order({
            side: side,
            tickLower: tickLower,
            tickUpper: tickUpper,
            quantity: _amount0 + _amount1,
            liquidity: _liquidity,
            owner: msg.sender,
            active: true
        });

        emit Open();
    }
/*
    function increaseSize(
        uint256 positionId,
        uint256 quantity
    ) external {
        require(
            orders[positionId].owner == msg.sender && orders[positionId].active,
            "NTO/NA" //not the owner/Not active
        );

        address token = getLiquidityToken(positionId);
        
        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            quantity
        );

        uint256 amount = orders[positionId].side ? 0 : quantity;
        
        increaseLiquidityCurrentRange(positionId, token, amount);
        
        orders[positionId].quantity += quantity;
        
        emit Increase();
    }
*/
    /// notice: Decreases the order size of a limit order position
    function decreaseSize(
        uint256 positionId,
        uint256 quantity
    ) public returns 
    (
        uint256 amount0,
        uint256 amount1
    ) {
        require(
            orders[positionId].owner == msg.sender,
            "NTO" //not the owner
        );
        require(
            orders[positionId].quantity >= quantity,
            "NEF" //not enough funds
        );
        require(
            orders[positionId].active,
            "NA" //not active
        );
        
        uint256 _amount0;
        uint256 _amount1;
        uint256 fees0;
        uint256 fees1;

        (_amount0, _amount1, fees0, fees1) = withdraw(positionId, quantity);

        //update liquidity values
        orders[positionId].quantity -= quantity;
        orders[positionId].liquidity = getPositionLiquidity(positionId);
        if(orders[positionId].liquidity<0) {
            orders[positionId].active = false;
            burn(positionId);
        }
        
        //transfer back the tokens to the msg.sender
        uint256 refund0 = _amount0 + fees0;
        uint256 refund1 = _amount1 + fees1;

        IERC20(poolToken0).safeTransfer(msg.sender, refund0);
        IERC20(poolToken1).safeTransfer(msg.sender, refund1);

        emit Decrease();
    }

    /// notice: Closes a limit order position, has to be triggered by the owner of the position
    function closePositionOwner(
        uint256 positionId
    )
    external {
        uint256 _quantity = orders[positionId].quantity;
        decreaseSize(positionId,_quantity); //decrease by the total position Size
    }

    //
    function settleOrder(
        uint256 positionId
    ) external {
        int24 poolTick = getCurrentPoolTick();
        address token = getLiquidityToken(positionId);

        //Check that the position is fully out of range
        require(
            orders[positionId].side ? 
            poolTick < orders[positionId].tickLower :
            poolTick > orders[positionId].tickUpper
            ,"ONF" // order not filled
        );


    }

    function mintNewPosition(
        bool side,
        int24 tickLower,
        int24 tickUpper,
        uint256 quantity
    ) private returns(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ){
        
        uint256 amount0ToMint = side ? 0 : quantity;
        uint256 amount1ToMint = side ? quantity : 0;
        
        (tokenId, liquidity, amount0, amount1) = nftManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: poolToken0,
                token1: poolToken1,
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: amount0.sub(amount0.div(MINT_BURN_SLIPPAGE)),
                amount1Min: amount1.sub(amount1.div(MINT_BURN_SLIPPAGE)),
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        //refund unused tokens
        if(amount0ToMint > amount0){
            uint256 refund0 = amount0ToMint - amount0;
            IERC20(poolToken0).safeTransfer(msg.sender, refund0);
        }

        if(amount1ToMint > amount1){
            uint256 refund1 = amount1ToMint - amount1;
            IERC20(poolToken1).safeTransfer(msg.sender, refund1);
        }

    }

    function increaseLiquidityCurrentRange(
        uint256 positionId,
        address token,
        uint256 amount
    ) private {
        //increase liquidity here
    }

    function withdraw(
        uint256 positionId,
        uint256 amount 
    ) private returns (
        uint256 _amount0,
        uint256 _amount1,
        uint256 feesCollected0,
        uint256 feesCollected1
    ) {
        //translate amount requested into Uni pool's liquidity value
        uint128 _liquidity = getLiquidityFromAmount(positionId,amount);
        require(_liquidity<=getPositionLiquidity(positionId), "NEF"); 

        //collect accrued fees
        (feesCollected0, feesCollected1) = collect(positionId); // collected by the contract

        //decrease Liq
        (_amount0, _amount1) = decreaseLiquidityCurrentRange(positionId,_liquidity);

        //harvest total position
        collectPosition(uint128(_amount0), uint128(_amount1), positionId);

        // !!! At the end of the operation, the position's tokens are still held by the contract
        // If the withdraw function is triggered from decreaseSize() or closePositionOwner(), the 
        // full balance is returned to the user (see each functions).
        // If the withdraw function is triggered from settleOrder(), the balance harvested is returned
        // to the user minus service fee. 
    }



    function getLiquidityFromAmount(uint256 positionId, uint256 amount) private returns (uint128 _liquidity) {
        _liquidity = uint128(amount.mul(orders[positionId].liquidity).div(orders[positionId].quantity));
    }

    function decreaseLiquidityCurrentRange(
        uint256 positionId,
        uint128 liquidity
    ) private returns (uint256 amount0, uint256 amount1){
        //decrease liq
        require(orders[positionId].active,"NA"); //not active

        (int24 tickLower, int24 tickUpper) = getTicks(positionId);

        uint256 _amount0;
        uint256 _amount1;

        (_amount0, _amount1) = LiquidityAmounts.getAmountsForLiquidity(
            getPoolPrice(),
            getPriceFromTick(tickLower),
            getPriceFromTick(tickUpper),
            liquidity
        );

        (amount0, amount1) = nftManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: liquidity,
                amount0Min: _amount0,
                amount1Min: _amount1,
                deadline: block.timestamp
            })
        );
    }

    function getAmountsForLiquidity(
        uint128 liquidity,
        uint256 positionId
    ) public view returns (uint256 amount0, uint256 amount1) {
        (int24 tickLower, int24 tickUpper) = getTicks(positionId);
        
    }

    function getTicks(
        uint256 positionId
    ) public view returns (int24 tickLower, int24 tickUpper) {
        (, , , , , tickLower, tickUpper, , , , , ) = nftManager.positions(
            positionId
        );
    }

    

    function burn(uint256 tokenId) private {
        nftManager.burn(tokenId);
    }
    
    /**
     * notice Collect fees generated from position
     */

    function collect(
        uint256 positionId
    ) private returns (uint256 collected0, uint256 collected1) {
        (collected0, collected1) = collectPosition(
            type(uint128).max,
            type(uint128).max,
            positionId
        );
    }

    function getLiquidityToken(uint256 positionId) private view returns(address token) {
        return orders[positionId].side ? poolToken1 : poolToken0;
    }

    /**
     *  dev Collect token amounts from pool position -- tokens need to have been withdrawn with decreaseLiquidity
     */
    function collectPosition(
        uint128 amount0,
        uint128 amount1,
        uint256 positionId
    ) private returns (uint256 collected0, uint256 collected1) {

        (collected0, collected1) = nftManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: amount0,
                amount1Max: amount1
            })
        );
    }

    function collectFees(
        uint256 positionId,
        address recipient
    ) private {
        //collect fees
    }


    /*----------------------------------------------------------*/
    /*                      UNISWAP UTILS                       */
    /*----------------------------------------------------------*/

    function getPriceFromTick(int24 tick) public pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function getCurrentPoolTick() public view returns (int24 tick){
        (, tick , , , , , ) = pool.slot0();
    }

    function getPositionLiquidity(
        uint256 positionId
    ) public view returns (uint128 liquidity) {
        (, , , , , , , liquidity, , , , ) = nftManager.positions(positionId);
    }

    function getPoolPrice() public view returns (uint160 price) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return sqrtRatioX96;
    }


    /*----------------------------------------------------------*/
    /*                      TEST FUNCTIONS                      */
    /*----------------------------------------------------------*/

   function getSide(uint256 positionId) public view returns (bool side) {
        side = orders[positionId].side;
    }
    function getTickLower(uint256 positionId) public view returns (int24 tickLower) {
        tickLower = orders[positionId].tickLower;
    }
    function getTickUpper(uint256 positionId) public view returns (int24 tickUpper) {
        tickUpper = orders[positionId].tickUpper;
    }
    function getQuantity(uint256 positionId) public view returns (uint256 quantity) {
        quantity = orders[positionId].quantity;
    }
    function getOwner(uint256 positionId) public view returns (address _owner) {
        _owner = orders[positionId].owner;
    }
    function getActivityStatus(uint256 positionId) public view returns (bool active) {
        active = orders[positionId].active;
    }
    
    /*function getPosition(uint256 positionId) public view returns(Order order) {
        order = orders[positionId];
    }*/

    
    /*receive() external payable {
        //If someone sends gas to the contract, account it uner their address
        gasProvision[msg.sender]+=msg.value; 
    }*/
}