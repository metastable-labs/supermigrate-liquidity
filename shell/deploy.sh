#!/bin/bash
# Function to check if the previous command was successful
check_status() {
    if [ $? -eq 0 ]; then
        echo "✅ Success: $1"
    else
        echo "❌ Error: $1 failed"
        exit 1
    fi
}

# Function to check if a variable is set
check_var() {
    if [ -z "${!1}" ]; then
        echo "❌ Error: $1 is not set. Please set it before running this script."
        exit 1
    fi
}

source .env

export ETHERSCAN_API_KEY=$BASESCAN_API_KEY
export BASE_RPC=$BASE_RPC
export ETH_RPC=$ETH_RPC
export PRIVATE_KEY=$PRIVATE_KEY

echo "🚀 Starting Supermigrate Liquidity deployment process..."

# Install Forge dependencies
forge install

# Deploy LiquidityMigration on Ethereum
echo "📝 Deploying LiquidityMigration on Ethereum..."
forge script script/DeployLiquidityMigration.s.sol:DeployLiquidityMigration --rpc-url $ETH_RPC --broadcast -vvvv --private-key $PRIVATE_KEY --verify --delay 15 --via-ir
check_status "LiquidityMigration deployment"

# Deploy L2LiquidityManager on Base
echo "📝 Deploying L2LiquidityManager on Base..."
forge script script/DeployL2LiquidityManager.s.sol:DeployL2LiquidityManager --rpc-url $BASE_RPC --broadcast -vvvv --private-key $PRIVATE_KEY --verify --delay 15 --via-ir
check_status "L2LiquidityManager deployment"

# Setup Trusted Remote on Ethereum
echo "🔗 Setting up Trusted Remote on Ethereum..."
forge script script/SetupETH.s.sol:SetupETH --rpc-url $ETH_RPC --broadcast -vvvv --private-key $PRIVATE_KEY --verify --delay 15 --via-ir
check_status "Ethereum Trusted Remote setup"

# Setup Trusted Remote on Base
echo "🔗 Setting up Trusted Remote on Base..."
forge script script/SetupBase.s.sol:SetupBase --rpc-url $BASE_RPC --broadcast -vvvv --private-key $PRIVATE_KEY --verify --delay 15 --via-ir
check_status "Base Trusted Remote setup"

echo "🎉 Supermigrate deployment and setup process completed successfully!"

# Display deployed addresses
echo "📊 Deployed Addresses:"
cat deployment-addresses.json