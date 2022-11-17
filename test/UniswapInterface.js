var token0 = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' //USDC
var token1 = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' // WETH 
var sqrtprice = '2945663776449003716655840979308674'
var side = true
var quantity  = '100000000000000000'
var bignumber = '100000000000000000000000'

const pair = {'token0': token0, 'token1': token1}
const BigNumber = require('bignumber.js');
const order = {'pair': pair, 'side': side, 'sqrtPriceX96': sqrtprice, 'quantity':quantity }
const { assert } = require("chai")

const weth_abi = [{"constant":true,"inputs":[],"name":"name","outputs":[{"name":"","type":"string"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":false,"inputs":[{"name":"guy","type":"address"},{"name":"wad","type":"uint256"}],"name":"approve","outputs":[{"name":"","type":"bool"}],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":true,"inputs":[],"name":"totalSupply","outputs":[{"name":"","type":"uint256"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":false,"inputs":[{"name":"src","type":"address"},{"name":"dst","type":"address"},{"name":"wad","type":"uint256"}],"name":"transferFrom","outputs":[{"name":"","type":"bool"}],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":false,"inputs":[{"name":"wad","type":"uint256"}],"name":"withdraw","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":true,"inputs":[],"name":"decimals","outputs":[{"name":"","type":"uint8"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":true,"inputs":[{"name":"","type":"address"}],"name":"balanceOf","outputs":[{"name":"","type":"uint256"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":true,"inputs":[],"name":"symbol","outputs":[{"name":"","type":"string"}],"payable":false,"stateMutability":"view","type":"function"},{"constant":false,"inputs":[{"name":"dst","type":"address"},{"name":"wad","type":"uint256"}],"name":"transfer","outputs":[{"name":"","type":"bool"}],"payable":false,"stateMutability":"nonpayable","type":"function"},{"constant":false,"inputs":[],"name":"deposit","outputs":[],"payable":true,"stateMutability":"payable","type":"function"},{"constant":true,"inputs":[{"name":"","type":"address"},{"name":"","type":"address"}],"name":"allowance","outputs":[{"name":"","type":"uint256"}],"payable":false,"stateMutability":"view","type":"function"},{"payable":true,"stateMutability":"payable","type":"fallback"},{"anonymous":false,"inputs":[{"indexed":true,"name":"src","type":"address"},{"indexed":true,"name":"guy","type":"address"},{"indexed":false,"name":"wad","type":"uint256"}],"name":"Approval","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"name":"src","type":"address"},{"indexed":true,"name":"dst","type":"address"},{"indexed":false,"name":"wad","type":"uint256"}],"name":"Transfer","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"name":"dst","type":"address"},{"indexed":false,"name":"wad","type":"uint256"}],"name":"Deposit","type":"event"},{"anonymous":false,"inputs":[{"indexed":true,"name":"src","type":"address"},{"indexed":false,"name":"wad","type":"uint256"}],"name":"Withdrawal","type":"event"}]
const weth_address = token1
const WETH = new web3.eth.Contract(weth_abi, weth_address) 

//const PositionManager = artifacts.require("./PositionManager.sol")
const UniV3TradingPair = artifacts.require("./UniV3TradingPair.sol")

require("ethers")

require("chai")
  .use(require("chai-as-promised"))
  .should()


contract('UniV3TradingPair', ([contractOwner, secondAddress, thirdAddress]) => {
  
  before(async () => {
    uni = await UniV3TradingPair.deployed()
  })

  // check if deployment goes smooth
  describe('deployment', () => {
    // check if the smart contract is deployed 
    // by checking the address of the smart contract
    it('deploys successfully', async () => {
      const uni_address = await uni.address

      assert.notEqual(uni_address, '')
      assert.notEqual(uni_address, undefined)
      assert.notEqual(uni_address, null)
      assert.notEqual(uni_address, 0x0)
    })
  })

  describe('Approvals:', () => {
    
    it('Approves WETH for the trade', async () => {
      // approve WETH
      const uni_address = await uni.address
      await WETH.methods.approve(uni_address, bignumber).send({from:contractOwner})

    })

    it('Checks that our wallet balance is 8 WETH', async () => {
      // approve WETH
      const uni_address = await uni.address
      const weth_balance = await WETH.methods.balanceOf(contractOwner).call()
      assert.equal(weth_balance, '8000000000000000000')

    })
})

describe('Place Order:', () => {

    it('Checks current pool tick', async () => {
      var tick = await uni.getCurrentPoolTick()
      assert.equal(tick, 204883)
    })

    // check if owner can set new message, check if setMessage works
    it('Creates a basic limit order: sell WETH', async () => {
      // Sell order, ticks need to be lower (price is calculated as token0/token1)
      var tickLower = '204000'
      var tickUpper = '204060'

      const weth_balance_init = await WETH.methods.balanceOf(contractOwner).call()

      const posId = BigNumber(await uni.createOrder(side, tickLower, tickUpper, quantity, {from:contractOwner})).toString()
        //).toString()

      /*const createdOrderSide = await uni.getSide(posId)
      assert.equal(createdOrderSide, side)
      const createdOrdertL = await uni.getTickLower(posId)
      assert.equal(createdOrdertL, tickLower)
      const createdOrdertU = await uni.getTickUpper(posId)
      assert.equal(createdOrdertU, tickUpper)
      
      var createdOwner = await uni.getOwner(posId)
      assert.equal(createdOwner, contractOwner)*/

      const weth_balance_deposit = await WETH.methods.balanceOf(contractOwner).call()

      // decrease by quantity/2
      await uni.decreaseSize(posId, '50000000000000000', {from:contractOwner})

      //close position
      await uni.closePosition(posId, {from:contractOwner})

      const weth_balance_final = await WETH.methods.balanceOf(contractOwner).call()

      assert.equal(weth_balance_final, weth_balance_init)
    })
    
    
  })
})
