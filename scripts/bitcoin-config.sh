#!/usr/bin/env bash

# Shared Bitcoin configuration and helper functions

# Setup node parameters based on node number
setup_node_params() {
    local node=$1
    
    # Get CLI path
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    
    # Determine chain
    BITCOIN_CHAIN="${BITCOIN_CHAIN:-regtest}"
    case "$BITCOIN_CHAIN" in
        "regtest")
            CHAIN_FLAG="-regtest"
            ;;
        "testnet4")
            CHAIN_FLAG="-testnet4"
            ;;
        "signet")
            CHAIN_FLAG="-signet"
            ;;
        *)
            CHAIN_FLAG=""
            ;;
    esac
    
    # Set node-specific parameters
    if [ "$node" = "1" ]; then
        DATADIR="$PWD/.devenv/state/bitcoind"
        RPC_PORT="18332"
        NODE_NAME="Node 1"
    elif [ "$node" = "2" ]; then
        DATADIR="$PWD/.devenv/state/bitcoind2"
        RPC_PORT="18444"
        NODE_NAME="Node 2"
    else
        echo "Error: node must be 1 or 2"
        exit 1
    fi
    
}

# Ensure wallet is loaded
ensure_wallet_loaded() {
    if ! bitcoin_cli_wallet getwalletinfo >/dev/null 2>&1; then
        if ! bitcoin_cli loadwallet default >/dev/null 2>&1; then
            bitcoin_cli createwallet default >/dev/null 2>&1
        fi
    fi
}

# Execute bitcoin-cli command with proper parameters
bitcoin_cli() {
    $CLI -datadir=$DATADIR $CHAIN_FLAG \
         -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT "$@"
}

# Execute bitcoin-cli command with wallet
bitcoin_cli_wallet() {
    bitcoin_cli -rpcwallet=default "$@"
}