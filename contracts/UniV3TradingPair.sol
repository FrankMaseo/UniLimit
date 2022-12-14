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
    
    //using SafeMath for uint160;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable owner;
    address public immutable poolToken0;
    address public immutable poolToken1;
    uint24 public immutable FEE;
    address public immutable treasury;

    uint256 private constant MINT_BURN_SLIPPAGE = 200; // .5% max slippage on order creation
    
    uint256 public protocolFee = 5; //protocol fee share in bps
    uint256 public settlerFee = 0; //settlerFee in bps

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
        address pool_address,
        address _nftManager,
        address _treasury
    ) {
        //pool = _pool;
        //nftManager = _nftManager;
        pool = IUniswapV3Pool(pool_address);
        nftManager = INonfungiblePositionManager(_nftManager);
        owner = msg.sender;
        poolToken0 = IUniswapV3Pool(pool_address).token0();
        poolToken1 = IUniswapV3Pool(pool_address).token1();
        FEE = IUniswapV3Pool(pool_address).fee();
        treasury = _treasury;
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

    event Open(
        uint256 positionId,
        address indexed trader,
        bool side,
        uint160 sqrtPriceX96,
        uint256 quantity
    );

    event Close(
        uint256 positionId
    );

    event SizeChanged(
        uint256 positionId,
        uint256 newQuantity
    );

    event Settled(
            bool side,
            uint256 positionId,
            address indexed trader,
            uint256 executionPrice,
            uint256 quantity
    );

    /*----------------------------------------------------------*/
    /*                  USER FACING FUNCTIONS                   */
    /*----------------------------------------------------------*/

    /// Opens a limit order my minting a LP position on the Uniswap v3 Pair
    /// params: 
    /// - side: true if you buy token0 for token1, false if you buy token1 for token0
    /// - sqrtPriceX96: sqrt(tokenRatio) * 2 ** 96 ::see uniswap doc
    /// - quantity: the number of tokens in the position
    function createOrder(
        bool side,
        uint160 sqrtPriceX96, 
        uint256 quantity
    ) public payable returns (uint256 positionId) {

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

        int24 tickUpper;
        int24 tickLower;
        ( tickLower, tickUpper) = getTicksFromPrice(side, sqrtPriceX96);

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
            quantity: _amount0.add(_amount1),
            liquidity: _liquidity,
            owner: msg.sender,
            active: true
        });

        emit Open(
            positionId,
            msg.sender,
            side,
            getPriceFromTicks(tickLower, tickUpper),
            orders[positionId].quantity
        );
    }

    function increaseSize(
        uint256 positionId,
        uint256 quantity
    ) external {
        require(
            orders[positionId].owner == msg.sender,
            "NTO" //not the owner
        );
        require(
            orders[positionId].active,
            "NA" //not active
        );

        address token = getLiquidityToken(positionId);
        
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

        (_liquidity, _amount0, _amount1) = increaseLiquidityCurrentRange(positionId, token, quantity);
        
        orders[positionId].quantity = _amount0.add(_amount1);
        orders[positionId].liquidity = _liquidity;
        
        emit SizeChanged(
            positionId,
            orders[positionId].quantity
        );
    }

    /// notice: Decreases the order size of a limit order position
    function decreaseSize(
        uint256 positionId,
        uint256 quantity
    ) public {
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
        
        uint256 amount0;
        uint256 amount1;
        //uint256 fees0;
        //uint256 fees1;

        (, ,amount0, amount1) = withdraw(positionId, quantity);

        //update liquidity values
        orders[positionId].quantity -= amount0 + amount1;
        orders[positionId].liquidity = getPositionLiquidity(positionId);
        
        
        //transfer back the tokens to the msg.sender
        uint256 refund0 = amount0;
        uint256 refund1 = amount1;

        if(amount0 > 0) {
            IERC20(poolToken0).safeTransfer(msg.sender, refund0);
        }
        if(amount1 > 0) {
            IERC20(poolToken1).safeTransfer(msg.sender, refund1);
        }
        
        //decrease position to zero and emit events
        if(orders[positionId].liquidity==0) {
            orders[positionId].active = false;
            emit Close(positionId);
        }
        else{
            emit SizeChanged(
                positionId,
                orders[positionId].quantity
            );
        }
        
    }

    /// notice: Closes a limit order position, has to be triggered by the owner of the position
    function closePositionOwner(uint256 positionId) external {
        require(orders[positionId].owner == msg.sender, "NTO");
        require(orders[positionId].active, "NA");

        uint256 _quantity = orders[positionId].quantity;
        decreaseSize(positionId,_quantity); //decrease by the total position Size
    }

    /// Settle order can be called by anyone once a position is closeable.
    function settleOrder(
        uint256 positionId
    ) public {
        int24 poolTick = getCurrentPoolTick();

        //Check that the position is fully out of range
        require(
            orders[positionId].side ? 
            poolTick < orders[positionId].tickLower :
            poolTick > orders[positionId].tickUpper
            ,"ONF" // order not filled
        );

        //check that the position is active
        require(
            orders[positionId].active,
            "NA" //not active
        );

        //uint256 _amount0;
        //uint256 _amount1;
        uint256 amount0;
        uint256 amount1;

        (, , amount0, amount1) = withdraw(
            positionId
            ,orders[positionId].quantity //withdraw function handles conversion of quantity to liquidity --> no worries
        );

        //handles tokens distribution between user, treasury and settler
        settle(positionId, amount0, amount1);

        //update position
        orders[positionId].active = false;

        //calculate executionPrice as token0/token1 -- for USDC/WETH pool: amount of USDC sent/received divided by amount of WETH sent/received
        uint256 executionPrice = getExecutionPrice(positionId, amount0, amount1);

        emit Settled(
            orders[positionId].side,
            positionId,
            orders[positionId].owner,
            executionPrice,
            orders[positionId].quantity
        );
    }

    function settle(
        uint256 positionId,
        uint256 amount0,
        uint256 amount1
    ) private {
        
        //Gas optimisation possibility: keep settler fees and add a claimFees() function
        uint256 bpsDivide = 10000; // 100*100
        bool _side = orders[positionId].side;

        //calc protocol + settler fees
        uint256 protocolFees0 = _side ? amount0.div(bpsDivide).mul(protocolFee) : amount0.mul(protocolFee.div(protocolFee.add(settlerFee)));
        uint256 protocolFees1 = _side ? amount1.mul(protocolFee.div(protocolFee.add(settlerFee))) : amount1.div(bpsDivide).mul(protocolFee);
        uint256 settlerFees0 = _side ? amount0.div(bpsDivide).mul(settlerFee) : amount0.mul(settlerFee.div(protocolFee.add(settlerFee)));
        uint256 settlerFees1 = _side ? amount1.mul(settlerFee.div(protocolFee.add(settlerFee))) : amount1.div(bpsDivide).mul(settlerFee);

        //all that remains goes to the user
        uint256 userAmount0 = _side ? amount0.sub(protocolFees0.add(settlerFees0)) : 0 ;
        uint256 userAmount1 = _side ? 0 : amount1.sub(protocolFees1.add(settlerFees1)) ;

        //settle user amounts, we chose not to send dust (accumulated Uniswap fees on the other side of the trade) to the user
        if (userAmount0 > 0) {
            IERC20(poolToken0).safeTransfer(orders[positionId].owner, userAmount0);
        }
        if (userAmount1 > 0) {
            IERC20(poolToken1).safeTransfer(orders[positionId].owner, userAmount1);
        }

        //settle treasury amounts
        if(protocolFees0 > 0) {
            IERC20(poolToken0).safeTransfer(treasury, protocolFees0);
        }
        if(protocolFees1 > 0) {
            IERC20(poolToken1).safeTransfer(treasury, protocolFees1);
        }

        //settle settler amounts
        if(settlerFees0 > 0) {
            IERC20(poolToken0).safeTransfer(msg.sender, settlerFees0);
        }
        if(settlerFees1 > 0) {
            IERC20(poolToken1).safeTransfer(msg.sender, settlerFees1);
        }
    }

    /*----------------------------------------------------------*/
    /*          UNISWAP POSITION MANAGER FUNCTIONS              */
    /*----------------------------------------------------------*/

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

        //refund unused tokens -- this should be optimized for gas: first calculated the amount to send, then take it from the user
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
        uint256 quantity
    ) private returns(
        uint128 newLiquidity,
        uint256 newAmount0,
        uint256 newAmount1
    ){
        (int24 tickLower, int24 tickUpper) = getTicks(positionId);

        //require that pool price is outside of order range
        int24 currentTick = getCurrentPoolTick();
        require(
            tickUpper != currentTick && tickLower != currentTick, // ticks are always next to each other so that's enough
            "LPA" // Liquidity position is active
        );

        uint256 amount0toAdd = orders[positionId].side ? 0 : quantity;
        uint256 amount1toAdd = orders[positionId].side ? quantity : 0;

        //add liquidity
        (newLiquidity, newAmount0, newAmount1) = nftManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0toAdd,
                amount1Desired: amount1toAdd,
                amount0Min: amount0toAdd.sub(
                    amount0toAdd.div(MINT_BURN_SLIPPAGE)
                ),
                amount1Min: amount1toAdd.sub(
                    amount1toAdd.div(MINT_BURN_SLIPPAGE)
                ),
                deadline: block.timestamp
            })
        );

        //refund unspent tokens to the user
        uint256 refund = orders[positionId].side ? amount1toAdd + orders[positionId].quantity - newAmount1 : amount0toAdd + orders[positionId].quantity - newAmount0; 
        IERC20(token).safeTransfer(msg.sender, refund);
    }

    function decreaseLiquidityCurrentRange(
        uint256 positionId,
        uint128 liquidity
    ) private returns (uint256 amount0, uint256 amount1){
        
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

    function withdraw(
        uint256 positionId,
        uint256 amount 
    ) private returns (
        uint256 _amount0,
        uint256 _amount1,
        uint256 totalCollected0,
        uint256 totalCollected1
    ) {
        //translate amount requested into Uni pool's liquidity value
        uint128 _liquidity = getLiquidityFromAmount(positionId, amount);
        require(_liquidity <= getPositionLiquidity(positionId), "NEF"); 

        //decrease Liq
        (_amount0, _amount1) = decreaseLiquidityCurrentRange(positionId,_liquidity);

        //collect fees + liq
        (totalCollected0, totalCollected1) = collect(positionId); // collected by the contract

        // !!! At the end of the operation, the position's tokens are still held by the contract
        // If the withdraw function is triggered from decreaseSize() or closePositionOwner(), the 
        // full balance is returned to the user (see each functions).
        // If the withdraw function is triggered from settleOrder(), the balance harvested is returned
        // to the user minus service fee. 
    }

    function burn(uint256 tokenId) private {
        nftManager.burn(tokenId);
    }
    
    // Collect fees
    function collect(
        uint256 positionId
    ) private returns (uint256 collected0, uint256 collected1) {
        (collected0, collected1) = collectPosition(
            type(uint128).max,
            type(uint128).max,
            positionId
        );
    }

    //Collect token amounts from pool position -- tokens need to have been withdrawn with decreaseLiquidity
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
    
    /*----------------------------------------------------------*/
    /*                  TRADING PAIR UTILS                      */
    /*----------------------------------------------------------*/

    function getLiquidityToken(uint256 positionId) private view returns(address token) {
        return orders[positionId].side ? poolToken1 : poolToken0;
    }

    function getLiquidityFromAmount(uint256 positionId, uint256 amount) private view returns (uint128 _liquidity) {
        _liquidity = uint128(amount.mul(orders[positionId].liquidity).div(orders[positionId].quantity));
    }

    function getExecutionPrice(
        uint256 positionId,
        uint256 userAmount0,
        uint256 userAmount1
    ) public view returns(
        uint256 price
    ) {
        price = orders[positionId].side ? userAmount0.div(orders[positionId].quantity) : orders[positionId].quantity.div(userAmount1);
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

    function getTicks(
        uint256 positionId
    ) public view returns (int24 tickLower, int24 tickUpper) {
        (, , , , , tickLower, tickUpper, , , , , ) = nftManager.positions(
            positionId
        );
    }

    function getPriceFromTicks(
        int24 tickLower,
        int24 tickUpper
    ) public view returns(uint160 sqrtPriceX96){
        uint160 p1 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 p2 = TickMath.getSqrtRatioAtTick(tickUpper);
        sqrtPriceX96 = (p1 + p2) / 2;
    }

    function getTicksFromPrice(
        bool side,
        uint160 sqrtPriceX96
    ) public view returns(
        int24 tickLower,
        int24 tickUpper
    ) {
        int24 tickSpacing = pool.tickSpacing();
        int24 closestTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        if(side) {
            tickUpper = closestTick - (closestTick % tickSpacing);
            tickLower = tickUpper - tickSpacing;
        } else {
            tickLower = closestTick - (closestTick % tickSpacing) + tickSpacing;
            tickUpper = tickLower + tickSpacing;
        }
    }

    /*----------------------------------------------------------*/
    /*                    POSITION GETTERS                      */
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

    /*----------------------------------------------------------*/
    /*                         SETTERS                          */
    /*----------------------------------------------------------*/

    function setProtocolFee(uint256 feeBips) public {
        require(msg.sender == owner, "Not the owner");
        protocolFee = feeBips;
    }

    function setSettlerFee(uint256 feeBips) public {
        require(msg.sender == owner, "Not the owner");
        settlerFee = feeBips;
    }
}