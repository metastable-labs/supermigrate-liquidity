import {Test, console} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {L2LiquidityManager} from "../../src/modules/L2LiquidityManager.sol";
import {LiquidityMigration} from "../../src/LiquidityMigration.sol";


contract ForkTest is Test {

    IUniswapV2Factory public constant uniswapV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IRouter public constant uniswapV2Router = IRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV3Factory public constant uniswapV3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager public constant nonfungiblePositionManager 
        = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    StandardBridge public constant l1StandardBridge 
        = StandardBridge(0x3154Cf16ccdb4C6d922629664174b904d80F2C35); // base l1 standard bridge

    ERC20 WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 pool = ERC20(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc);

    address public constant endpoint = 0x1a44076050125825900e736c501f859c50fE728c;

    address public delegate;
    address public l2LiquidityManager;

    LiquidityMigration liquidityMigration;

    address user;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));

        delegate = makeAddr("delegate");
        l2LiquidityManager= makeAddr("l2LiquidityManager");
        user = makeAddr("user");

        liquidityMigration = new LiquidityMigration(
            endpoint, 
            delegate, 
            address(uniswapV2Factory), 
            address(uniswapV2Router), 
            address(uniswapV3Factory), 
            address(nonfungiblePositionManager), 
            address(l1StandardBridge), 
            l2LiquidityManager
        );
    }
    // Token pair used in testing: WETH/USDC
    function test_migrateV2Liquidity() public {
        deal(address(WETH), user, 10e18);
        deal(address(USDC), user, 25_000e6);

        
        uint256 lpTokens = _addV2Liquidity(user);

        pool.approve(address(liquidityMigration), pool.balanceOf(user));
        
        LiquidityMigration.MigrationParams memory params = LiquidityMigration.MigrationParams({
            dstEid: uint32(45),
            tokenA: address(WETH),
            tokenB: address(USDC),
            l2TokenA: address(0x4200000000000000000000000000000000000006),
            l2TokenB: address(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA),
            liquidity: lpTokens,
            tokenId: 0,
            amountAMin: 0,       
            amountBMin: 0,  
            deadline: block.timestamp,
            minGasLimit: 50_000,
            poolType: LiquidityMigration.PoolType(0),
            stakeLPtokens: false
        });

        liquidityMigration.migrateERC20Liquidity(params, "");
        vm.stopPrank();
    }

    function _addV2Liquidity(address _user) internal returns(uint256 lpTokens) {
        vm.startPrank(_user);
        WETH.approve(address(uniswapV2Router), type(uint256).max);
        USDC.approve(address(uniswapV2Router), type(uint256).max);

        uniswapV2Router.addLiquidity(address(WETH), address(USDC), 1e18, 2_500e6, 0, 0, _user, block.timestamp);

        lpTokens = pool.balanceOf(_user);
    }
}

//////////////
//INTERFACES//
//////////////
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface StandardBridge {
    event ERC20BridgeFinalized(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );
    event ERC20BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );
    event ETHBridgeFinalized(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);

    function bridgeERC20(
        address _localToken,
        address _remoteToken,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes memory _extraData
    ) external;
    function bridgeERC20To(
        address _localToken,
        address _remoteToken,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes memory _extraData
    ) external;
    function bridgeETH(uint32 _minGasLimit, bytes memory _extraData) external payable;
    function bridgeETHTo(address _to, uint32 _minGasLimit, bytes memory _extraData) external payable;
    function deposits(address, address) external view returns (uint256);
    function finalizeBridgeERC20(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _extraData
    ) external;
    function finalizeBridgeETH(address _from, address _to, uint256 _amount, bytes memory _extraData) external payable;
    function messenger() external view returns (address);
    function OTHER_BRIDGE() external view returns (address);
}

interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}