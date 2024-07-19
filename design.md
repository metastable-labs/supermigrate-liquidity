## L2LiqudiityManager.sol (Deployed only on Base)
- Interacts with aerodrome to deposit Liquidity
- Tracks individual migration positions
- Communicates with the Yield Calculation Module to apply appropriate yields based on migration
- Tracks staking position on Aerodrome

## LiquidityMigration.sol (Deployed on Ethereum)
This contract is the central hub for managing the migration of liquidity from Layer 1 to Layer 2.
- Initiates the process of withdrawing liquidity from Uniswap on L1
- Interacts with the bridge contract to transfer assets to L2
- Coordinates with LayerZero for cross-chain messaging
    - Triggers `L2LiqudiityManager.sol` for liquidity deployment on L2 (Aerodrome) once assets are bridged

##  Yield.sol
This contract is responsible for computing yields based on the migrated liquidity.
- Implements the sigmoid curve function for liquidity-based yield calculation
- Calculates priority factors for low liquidity pools
- Applies liquidity thresholds to determine base yields
- Computes time-based multipliers based on the duration of liquidity provision
- Provides an interface for other contracts to fetch current yield rates
- Dynamically adjusts yields based on the current liquidity needs of the L2 ecosystem

## Reward.sol
This contract manages the distribution of tokens as rewards to liquidity providers.
- Tracks reward accrual for each liquidity provider based on their migrated liquidity
- Handles the claiming process for earned rewards