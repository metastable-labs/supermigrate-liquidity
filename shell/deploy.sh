#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to check if the previous command was successful
check_status() {
    if [ $? -eq 0 ]; then
        echo "✅ Success: $1"
    else
        echo "❌ Error: $1 failed"
        exit 1
    fi
}

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | xargs)
else
    echo "❌ Error: .env file not found"
    exit 1
fi

# Check if required environment variables are set
if [ -z "$ETH_RPC" ] || [ -z "$BASE_RPC" ] || [ -z "$PRIVATE_KEY" ]; then
    echo "❌ Error: Missing required environment variables. Please check your .env file."
    exit 1
fi

echo "🚀 Starting Supermigrate Liquidity deployment process..."

# Deploy LiquidityMigration on Ethereum
echo "📝 Deploying LiquidityMigration on Ethereum..."
forge script script/DeployLiquidityMigration.s.sol:DeployLiquidityMigration --rpc-url $ETH_RPC --broadcast --verify
check_status "LiquidityMigration deployment"

# Deploy L2LiquidityManager on Base
echo "📝 Deploying L2LiquidityManager on Base..."
forge script script/DeployL2LiquidityManager.s.sol:DeployL2LiquidityManager --rpc-url $BASE_RPC --broadcast --verify
check_status "L2LiquidityManager deployment"

# Setup Trusted Remote on Ethereum
echo "🔗 Setting up Trusted Remote on Ethereum..."
forge script script/SetupETH.s.sol:SetupETH --rpc-url $ETH_RPC --broadcast --verify
check_status "Ethereum Trusted Remote setup"

# Setup Trusted Remote on Base
echo "🔗 Setting up Trusted Remote on Base..."
forge script script/SetupBase.s.sol:SetupBase --rpc-url $BASE_RPC --broadcast --verify
check_status "Base Trusted Remote setup"

echo "🎉 Supermigrate deployment and setup process completed successfully!"

# Display deployed addresses
echo "📊 Deployed Addresses:"
cat deployment-addresses.json