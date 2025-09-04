#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Bitcoin CLI path
CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"

# Blockchain selection
CHAIN="${BITCOIN_CHAIN:-regtest}"

# Load chain-specific port configuration 
NODE1_RPC=$(yq eval ".bitcoin.${CHAIN}.node1.rpc" "${PROJECT_ROOT}/config/ports.toml")
NODE1_DATADIR=$(yq eval ".bitcoin.${CHAIN}.node1.datadir" "${PROJECT_ROOT}/config/ports.toml")
NODE2_RPC=$(yq eval ".bitcoin.${CHAIN}.node2.rpc" "${PROJECT_ROOT}/config/ports.toml")
NODE2_DATADIR=$(yq eval ".bitcoin.${CHAIN}.node2.datadir" "${PROJECT_ROOT}/config/ports.toml")

# Chain flag configuration
if [ "$CHAIN" = "regtest" ]; then
  CHAIN_ARG="-regtest"
elif [ "$CHAIN" = "testnet4" ]; then
  CHAIN_ARG="-testnet4"
elif [ "$CHAIN" = "signet" ]; then
  CHAIN_ARG="-signet"
else
  echo "Unknown chain $CHAIN"; exit 1
fi

# Node configurations using centralized config
NODE1_DATADIR_FULL="${PROJECT_ROOT}/.devenv/state/${NODE1_DATADIR}"
NODE1_CONF="${PROJECT_ROOT}/config/bitcoin-base.conf"
NODE1_CLI="$CLI -datadir=$NODE1_DATADIR_FULL -conf=$NODE1_CONF $CHAIN_ARG -rpcuser=user -rpcpassword=password -rpcport=$NODE1_RPC"

NODE2_DATADIR_FULL="${PROJECT_ROOT}/.devenv/state/${NODE2_DATADIR}"
NODE2_CONF="${PROJECT_ROOT}/config/bitcoin-base.conf"
NODE2_CLI="$CLI -datadir=$NODE2_DATADIR_FULL -conf=$NODE2_CONF $CHAIN_ARG -rpcuser=user -rpcpassword=password -rpcport=$NODE2_RPC"

# Function to wait for a node to be ready
wait_for_node() {
    local node_name="$1"
    local node_cli="$2"
    local timeout=60
    local counter=0
    
    echo "Waiting for $node_name RPC..."
    until $node_cli getblockchaininfo >/dev/null 2>&1; do
        sleep 1
        counter=$((counter + 1))
        if [ $counter -ge $timeout ]; then
            echo "ERROR: Timeout waiting for $node_name RPC after ${timeout}s"
            return 1
        fi
        if [ $((counter % 10)) -eq 0 ]; then
            echo "Still waiting for $node_name... (${counter}s)"
        fi
    done
    echo "✓ $node_name RPC ready"
}

# Function to setup wallet
setup_wallet() {
    local node_name="$1"
    local node_cli="$2"
    
    echo "Setting up $node_name wallet..."
    if ! $node_cli -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
        if ! $node_cli loadwallet default >/dev/null 2>&1; then
            echo "Creating new wallet for $node_name..."
            $node_cli createwallet default >/dev/null 2>&1 || echo "Wallet creation failed or already exists"
        fi
    else
        echo "✓ $node_name wallet already exists"
    fi
}

# Function to wait for block propagation between nodes
wait_for_block_propagation() {
    local expected_height=$1
    echo "Waiting for block $expected_height to propagate between nodes..."
    for i in {1..30}; do
        HEIGHT1=$($NODE1_CLI getblockcount 2>/dev/null || echo "0")
        HEIGHT2=$($NODE2_CLI getblockcount 2>/dev/null || echo "0")
        HASH1=$($NODE1_CLI getblockhash $expected_height 2>/dev/null || echo "")
        HASH2=$($NODE2_CLI getblockhash $expected_height 2>/dev/null || echo "")
        
        if [ "$HEIGHT1" -eq "$HEIGHT2" ] && [ "$HASH1" = "$HASH2" ] && [ -n "$HASH1" ]; then
            echo "✓ Block $expected_height propagated successfully: ${HASH1:0:16}..."
            return 0
        fi
        echo "Waiting... Node1: h=$HEIGHT1 hash=${HASH1:0:8}, Node2: h=$HEIGHT2 hash=${HASH2:0:8} (attempt $i/30)"
        sleep 1
    done
    echo "ERROR: Block $expected_height failed to propagate after 30s"
    return 1
}

echo "=== Bitcoin Wallet Initialization ==="

# Wait for all nodes to be ready
wait_for_node "Node 1" "$NODE1_CLI" || exit 1
wait_for_node "Node 2" "$NODE2_CLI" || exit 1

# Setup wallets for all nodes
setup_wallet "Node 1" "$NODE1_CLI"
setup_wallet "Node 2" "$NODE2_CLI"

if [ "$CHAIN" = "regtest" ]; then
    # Check if we need to do initialization
    HEIGHT1=$($NODE1_CLI getblockcount 2>/dev/null || echo "0")
    HEIGHT2=$($NODE2_CLI getblockcount 2>/dev/null || echo "0")

    # Use the highest height as reference
    CURRENT_HEIGHT=$((HEIGHT1 > HEIGHT2 ? HEIGHT1 : HEIGHT2))

    if [ "$CURRENT_HEIGHT" -ge 102 ]; then
        echo "Current block height: $CURRENT_HEIGHT (>= 102), skipping mining"
    else
        echo ""
        echo "=== Strategic Mining for Spendable Coinbase ==="
        echo "Current height: $CURRENT_HEIGHT"
        echo "Strategy: Mine 1 block to each node, then mine 100+ more to make them spendable"
        
        if [ "$CURRENT_HEIGHT" -lt 1 ]; then
            # Mine first block to Node 1
            echo "Mining block 1 to Node 1..."
            ADDR1=$($NODE1_CLI -rpcwallet=default getnewaddress "early-mining" 2>/dev/null || $NODE1_CLI -rpcwallet=default getnewaddress 2>/dev/null)
            $NODE1_CLI -rpcwallet=default generatetoaddress 1 "$ADDR1" >/dev/null 2>&1
            echo "✓ Block 1 mined to Node 1 (50 BTC coinbase)"
            wait_for_block_propagation 1 || { echo "Block 1 propagation failed!"; exit 1; }
        fi
        
        if [ "$CURRENT_HEIGHT" -lt 2 ]; then
            # Mine second block to Node 2  
            echo "Mining block 2 to Node 2..."
            ADDR2=$($NODE2_CLI -rpcwallet=default getnewaddress "early-mining" 2>/dev/null || $NODE2_CLI -rpcwallet=default getnewaddress 2>/dev/null)
            $NODE2_CLI -rpcwallet=default generatetoaddress 1 "$ADDR2" >/dev/null 2>&1
            echo "✓ Block 2 mined to Node 2 (50 BTC coinbase)"
            wait_for_block_propagation 2 || { echo "Block 2 propagation failed!"; exit 1; }
        fi
        
        
        # Now mine 100+ more blocks to make the early coinbase rewards spendable
        UPDATED_HEIGHT=$($NODE1_CLI getblockcount)
        BLOCKS_NEEDED=$((102 - UPDATED_HEIGHT))
        
        if [ "$BLOCKS_NEEDED" -gt 0 ]; then
            echo "Mining $BLOCKS_NEEDED more blocks to Node 1 to mature the coinbase rewards..."
            $NODE1_CLI -rpcwallet=default generatetoaddress $BLOCKS_NEEDED "$ADDR1" >/dev/null 2>&1
            echo "✓ Mined $BLOCKS_NEEDED additional blocks"
            
            # Wait for all nodes to sync
            echo "Waiting for all nodes to sync..."
            for i in {1..30}; do
                HEIGHT1=$($NODE1_CLI getblockcount 2>/dev/null || echo "0")
                HEIGHT2=$($NODE2_CLI getblockcount 2>/dev/null || echo "0")
                if [ "$HEIGHT1" = "$HEIGHT2" ]; then
                    echo "✓ Both nodes synchronized at height $HEIGHT1"
                    
                    # Rescan wallets to detect coinbase rewards
                    echo "Rescanning Node 2 wallet to detect coinbase rewards..."
                    $NODE2_CLI -rpcwallet=default rescanblockchain 0 >/dev/null 2>&1 || echo "Node 2 rescan failed, but continuing..."
                    sleep 2
                    break
                fi
                echo "Waiting for sync... Node 1: $HEIGHT1, Node 2: $HEIGHT2 (attempt $i/30)"
                sleep 2
            done
        fi
    fi

    echo ""
    echo "=== Final Status ==="
    HEIGHT1=$($NODE1_CLI getblockcount)
    HEIGHT2=$($NODE2_CLI getblockcount)
    echo "Node 1 height: $HEIGHT1"
    echo "Node 2 height: $HEIGHT2"

    # Check spendable balances
    BALANCE1=$($NODE1_CLI -rpcwallet=default getbalance 2>/dev/null || echo "0")
    BALANCE2=$($NODE2_CLI -rpcwallet=default getbalance 2>/dev/null || echo "0")
    echo "Node 1 spendable balance: $BALANCE1 BTC"
    echo "Node 2 spendable balance: $BALANCE2 BTC"

    # Check total balances including immature
    TOTAL1=$($NODE1_CLI -rpcwallet=default getbalances 2>/dev/null | jq -r '.mine.trusted + .mine.untrusted_pending' 2>/dev/null || echo "$BALANCE1")
    TOTAL2=$($NODE2_CLI -rpcwallet=default getbalances 2>/dev/null | jq -r '.mine.trusted + .mine.untrusted_pending' 2>/dev/null || echo "$BALANCE2")
    echo "Node 1 total balance: $TOTAL1 BTC"
    echo "Node 2 total balance: $TOTAL2 BTC"

    if [ "$(echo "$BALANCE1 > 0" | bc -l 2>/dev/null || echo "0")" = "1" ] && [ "$(echo "$BALANCE2 > 0" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
        echo ""
        echo "✓ Wallet initialization complete!"
        echo "Both nodes have spendable Bitcoin and can create transactions."
    else
        echo ""
        echo "⚠ Warning: Some nodes may not have spendable Bitcoin yet."
        if [ "$HEIGHT1" != "$HEIGHT2" ]; then
            echo "Nodes are not synchronized! Node 1: $HEIGHT1, Node 2: $HEIGHT2"
            echo "The Bitcoin nodes may not be properly connected as peers."
        fi
        echo "You may need to check node synchronization or run 'just status'"
    fi
else
  echo "Skipping mining (chain=$CHAIN). Use a faucet to fund wallets."
fi