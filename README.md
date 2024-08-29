# Supermigrate Protocol Documentation

## 1. Introduction

Supermigrate is a protocol designed to facilitate the seamless migration of liquidity from Ethereum (L1) to the Superchain. The primary focus is on migrating liquidity from Uniswap V2 and V3 pools on Ethereum to Aerodrome pools on Base. This documentation provides a comprehensive overview of the protocol's components, functionality, and usage.

## 2. System Overview

The Supermigrate protocol consists of two main components:

1. **LiquidityMigration Contract (L1)**: Deployed on Ethereum, this contract handles the removal of liquidity from Uniswap pools and initiates the cross-chain transfer.

2. **L2LiquidityManager Contract (L2)**: Deployed on Base (Layer 2), this contract receives the migrated assets and manages their deployment into Aerodrome pools.

The system utilizes LayerZero for cross-chain messaging and asset bridging.

## 3. LiquidityMigration Contract (L1)

### Key Functions:
- `migrateERC20Liquidity`: Initiates the migration process for ERC20 tokens.
- `_removeLiquidity`: Internal function to remove liquidity from Uniswap V2 or V3 pools.
- `_bridgeTokens`: Internal function to bridge tokens to L2.

### Features:
- Supports both Uniswap V2 and V3 pools
- Handles ERC20 tokens and ETH (wrapped as WETH)
- Utilizes LayerZero for cross-chain messaging

## 4. L2LiquidityManager Contract (L2)

### Key Functions:
- `_lzReceive`: Receives cross-chain messages and processes migrated liquidity.
- `_depositLiquidity`: Internal function to deposit liquidity into Aerodrome pools.
- `_balanceTokenRatio`: Ensures optimal token ratio before liquidity provision.

### Features:
- Supports various Aerodrome pool types (stable, volatile, concentrated)
- Manages user positions and staked LP tokens
- Handles token swaps to balance liquidity ratios

## 5. Migration Process

1. User initiates migration by calling `migrateERC20Liquidity` on the L1 contract.
2. LiquidityMigration removes liquidity from Uniswap.
3. Assets are bridged to L2 using the L1 Standard Bridge.
4. A cross-chain message is sent to L2 via LayerZero.
5. L2LiquidityManager receives the message and bridged assets.
6. Liquidity is automatically deposited into corresponding Aerodrome pools.
7. LP tokens are minted and sent to the user.

## 6. Key Features

- **Cross-Chain Compatibility**: Seamless migration between Ethereum and Base.
- **Multi-Pool Support**: Handles Uniswap V2, V3, and Aerodrome pools.
- **Optimized Liquidity Provision**: Balances token ratios for optimal liquidity deployment.
- **Flexible Asset Handling**: Supports ERC20 tokens and ETH.
- **User Position Tracking**: Maintains records of user liquidity and staked LP tokens.
- **Fee Mechanism**: Incorporates a fee system for protocol sustainability.

## 7. Security Considerations

- **Slippage Protection**: Implements slippage checks to protect users during token swaps and liquidity provision.
- **Access Control**: Utilizes OpenZeppelin's Ownable for critical functions.
- **Cross-Chain Security**: Leverages LayerZero's security features for cross-chain messaging.
- **Decimal Handling**: Properly manages token decimals to prevent rounding errors.

## 8. Integration Guide

### LiquidityMigration Contract (L1)

### `migrateERC20Liquidity`

Initiates the migration of liquidity from Uniswap V2 or V3 pools to L2.

```solidity
function migrateERC20Liquidity(MigrationParams calldata params, bytes calldata _options)
    external
    payable
    returns (MessagingReceipt memory receipt)
```

#### Parameters:
- `params`: A struct containing migration parameters:
  - `dstEid`: Destination chain ID (uint32)
  - `tokenA`: Address of the first token in the pair
  - `tokenB`: Address of the second token in the pair
  - `l2TokenA`: Address of the first token on L2
  - `l2TokenB`: Address of the second token on L2
  - `liquidity`: Amount of liquidity to migrate (uint256)
  - `tokenId`: Token ID for Uniswap V3 positions (uint256)
  - `amountAMin`: Minimum amount of tokenA to receive (uint256)
  - `amountBMin`: Minimum amount of tokenB to receive (uint256)
  - `deadline`: Expiration timestamp for the transaction (uint256)
  - `minGasLimit`: Minimum gas limit for the L2 transaction (uint32)
  - `poolType`: Enum representing the pool type (STABLE, VOLATILE, CONCENTRATED)
  - `stakeLPtokens`: Boolean indicating whether to stake LP tokens on L2
- `_options`: LayerZero options for cross-chain messaging

#### Returns:
- `receipt`: A struct containing information about the cross-chain message

#### Notes:
- This function requires `msg.value` to cover the LayerZero fee.
- Ensure tokens are approved for the contract before calling.

### `quote`

Provides a quote for the LayerZero fee required for migration.

```solidity
function quote(
    uint32 _dstEid,
    address tokenA,
    address tokenB,
    uint256 liquidity,
    bytes memory _options,
    bool _payInLzToken
) public view returns (MessagingFee memory fee)
```

#### Parameters:
- `_dstEid`: Destination chain ID
- `tokenA`: Address of the first token in the pair
- `tokenB`: Address of the second token in the pair
- `liquidity`: Amount of liquidity to migrate
- `_options`: LayerZero options
- `_payInLzToken`: Whether to pay the fee in LZ token

#### Returns:
- `fee`: A struct containing the fee details

### `isV3Pool`

Checks if a given token pair has a Uniswap V3 pool.

```solidity
function isV3Pool(address tokenA, address tokenB) public view returns (bool)
```

#### Parameters:
- `tokenA`: Address of the first token
- `tokenB`: Address of the second token

#### Returns:
- `bool`: True if a V3 pool exists, false otherwise

### L2LiquidityManager Contract (L2)

### `setPool`

Adds a new pool to the Supermigrate system. Only callable by the contract owner.

```solidity
function setPool(address tokenA, address tokenB, address pool, address gauge) external onlyOwner
```

#### Parameters:
- `tokenA`: Address of the first token in the pair
- `tokenB`: Address of the second token in the pair
- `pool`: Address of the Aerodrome pool
- `gauge`: Address of the gauge for the pool

### `setFee`

Sets the migration fee. Only callable by the contract owner.

```solidity
function setFee(uint256 _newFee) external onlyOwner
```

#### Parameters:
- `_newFee`: New fee percentage (based on FEE_DENOMINATOR)

### `getPool`

Retrieves pool and gauge addresses for a token pair.

```solidity
function getPool(address tokenA, address tokenB) external view returns (address pool, address gauge)
```

#### Parameters:
- `tokenA`: Address of the first token
- `tokenB`: Address of the second token

#### Returns:
- `pool`: Address of the Aerodrome pool
- `gauge`: Address of the gauge

### `getPoolsCount`

Returns the total number of pools in the Supermigrate system.

```solidity
function getPoolsCount() external view returns (uint256)
```

#### Returns:
- `uint256`: Number of pools

### `getPools`

Retrieves a range of pools within the Supermigrate system.

```solidity
function getPools(uint256 start, uint256 end) external view returns (address[] memory pools, address[] memory gauges)
```

#### Parameters:
- `start`: Start index of the range
- `end`: End index of the range (exclusive)

#### Returns:
- `pools`: Array of pool addresses
- `gauges`: Array of corresponding gauge addresses

### `getUserLiquidity`

Gets the liquidity amount for a user and token.

```solidity
function getUserLiquidity(address user, address token) external view returns (uint256)
```

#### Parameters:
- `user`: Address of the user
- `token`: Address of the token

#### Returns:
- `uint256`: Liquidity amount

### `getUserStakedLP`

Gets the staked LP token amount for a user and pool.

```solidity
function getUserStakedLP(address user, address pool) external view returns (uint256)
```

#### Parameters:
- `user`: Address of the user
- `pool`: Address of the pool

#### Returns:
- `uint256`: Staked LP token amount

### `stakeLPToken`

Stakes LP tokens in the corresponding gauge.

```solidity
function stakeLPToken(uint256 amount, address tokenA, address tokenB) external
```

#### Parameters:
- `amount`: The amount of LP tokens to stake
- `tokenA`: The address of the first token in the pair
- `tokenB`: The address of the second token in the pair

#### Notes:
- User must approve the gauge to spend their LP tokens before calling this function

### `unstakeLPToken`

Unstakes LP tokens from the corresponding gauge.

```solidity
function unstakeLPToken(uint256 amount, address tokenA, address tokenB) external
```

#### Parameters:
- `amount`: The amount of LP tokens to unstake
- `tokenA`: The address of the first token in the pair
- `tokenB`: The address of the second token in the pair

#### Notes:
- This function will fail if the user tries to unstake more than they have staked

### `claimAeroRewards`

Claims Aero rewards for the caller from the specified pool's gauge.

```solidity
function claimAeroRewards(address tokenA, address tokenB) external
```

#### Parameters:
- `tokenA`: The address of the first token in the pair
- `tokenB`: The address of the second token in the pair

## Integration Notes

1. Always check return values and handle potential reverts.
2. For functions that modify state, ensure proper gas estimation.
3. Use `quote` function before calling `migrateERC20Liquidity` to estimate required ETH for LayerZero fees.
4. Monitor emitted events for additional information and transaction confirmation.
5. For L2 operations, ensure proper token approvals before staking or unstaking LP tokens.

For any questions or issues, please refer to the full contract code or contact the Supermigrate development team.

## 9. Future Improvements

- Support for additional Superchain networks and DEXes.
- Integration with yield farming protocols on L2.

For more information or support, please contact the Supermigrate team or refer to our GitHub repository.