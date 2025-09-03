# Bitcoin development commands for TxRelay

# List all available recipes
default:
    @just --list

# Start the development environment
up:
    devenv up



# Create transaction and leave in mempool (don't mine block)  
create-tx node="1" amount="0.1":
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    if [ "{{node}}" = "1" ]; then
        DATADIR="$PWD/.devenv/state/bitcoind"
        CONF="$PWD/config/bitcoin1.conf"
        RPC_PORT=""
        NODE_NAME="Node 1"
    elif [ "{{node}}" = "2" ]; then
        DATADIR="$PWD/.devenv/state/bitcoind2"
        CONF="$PWD/config/bitcoin2.conf"
        RPC_PORT="-rpcport=18444"
        NODE_NAME="Node 2"
    else
        echo "Error: node must be 1 or 2"
        exit 1
    fi
    
    # Ensure wallet exists and is loaded
    if ! $CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
        if ! $CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT loadwallet default >/dev/null 2>&1; then
            $CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT createwallet default >/dev/null 2>&1
        fi
    fi
    
    # Create and broadcast raw transaction to ensure it stays in mempool
    ADDR=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getnewaddress)
    
    # Get a UTXO to spend
    UTXO=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default listunspent 1 | jq -r '.[0] | "\(.txid):\(.vout):\(.amount)"')
    if [ "$UTXO" = "null:null:null" ] || [ -z "$UTXO" ]; then
        echo "Error: No UTXOs available in $NODE_NAME wallet"
        exit 1
    fi
    
    UTXO_TXID=$(echo $UTXO | cut -d: -f1)
    UTXO_VOUT=$(echo $UTXO | cut -d: -f2)
    UTXO_AMOUNT=$(echo $UTXO | cut -d: -f3)
    
    # Calculate change amount (subtract small fee)
    CHANGE=$(echo "$UTXO_AMOUNT - {{amount}} - 0.00001" | bc -l)
    
    # Create raw transaction
    RAW_TX=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT createrawtransaction "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "{\"$ADDR\":{{amount}},\"$(echo $($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getrawchangeaddress))\":$CHANGE}")
    
    # Sign the transaction
    SIGNED_TX=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default signrawtransactionwithwallet $RAW_TX | jq -r '.hex')
    
    # Broadcast to mempool
    TXID=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT sendrawtransaction $SIGNED_TX)
    
    echo "Transaction $TXID created in $NODE_NAME mempool (not mined yet)"


# Get blockchain info  
info:
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    echo "=== Bitcoin Node 1 Blockchain Info ==="
    BLOCKCHAIN_INFO=$($CLI -datadir=$PWD/.devenv/state/bitcoind -conf=$PWD/config/bitcoin1.conf -regtest -rpcuser=user -rpcpassword=password getblockchaininfo 2>/dev/null)
    if [ $? -eq 0 ]; then
        BLOCKS=$(echo "$BLOCKCHAIN_INFO" | jq -r '.blocks')
        BEST_HASH=$(echo "$BLOCKCHAIN_INFO" | jq -r '.bestblockhash')
        CHAIN=$(echo "$BLOCKCHAIN_INFO" | jq -r '.chain')
        DIFFICULTY=$(echo "$BLOCKCHAIN_INFO" | jq -r '.difficulty')
        
        echo "Chain: $CHAIN"
        echo "Block height: $BLOCKS"
        echo "Best block hash: $BEST_HASH"
        echo "Difficulty: $DIFFICULTY"
        
        # Get the latest block info
        LATEST_BLOCK=$($CLI -datadir=$PWD/.devenv/state/bitcoind -conf=$PWD/config/bitcoin1.conf -regtest -rpcuser=user -rpcpassword=password getblock "$BEST_HASH" 2>/dev/null)
        if [ $? -eq 0 ]; then
            TIMESTAMP=$(echo "$LATEST_BLOCK" | jq -r '.time')
            TX_COUNT=$(echo "$LATEST_BLOCK" | jq -r '.nTx')
            SIZE=$(echo "$LATEST_BLOCK" | jq -r '.size')
            DATE=$(date -d "@$TIMESTAMP" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
            
            echo ""
            echo "Latest block details:"
            echo "  Timestamp: $DATE"
            echo "  Transaction count: $TX_COUNT"
            echo "  Block size: $SIZE bytes"
        fi
    else
        echo "✗ Bitcoin Node 1 not responding"
    fi



# Check Bitcoin node status (peers, sync, and connection)
status:
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    
    echo "=== Bitcoin Node 1 ==="
    NODE1_INFO=$($CLI -datadir=$PWD/.devenv/state/bitcoind -conf=$PWD/config/bitcoin1.conf -regtest -rpcuser=user -rpcpassword=password getnetworkinfo 2>/dev/null)
    if [ $? -eq 0 ]; then
        # Get RPC port from config file, P2P port from running process
        NODE1_RPC_PORT=$(grep "rpcport=" $PWD/config/bitcoin1.conf | cut -d= -f2)
        NODE1_P2P_PORT=$(echo "$NODE1_INFO" | jq -r '.localaddresses[0].port // empty')
        if [ -z "$NODE1_P2P_PORT" ]; then NODE1_P2P_PORT="18333"; fi
        echo "RPC Port: $NODE1_RPC_PORT, P2P Port: $NODE1_P2P_PORT"
        
        HEIGHT1=$($CLI -datadir=$PWD/.devenv/state/bitcoind -conf=$PWD/config/bitcoin1.conf -regtest -rpcuser=user -rpcpassword=password getblockcount)
        echo "Block height: $HEIGHT1"
        
        PEERS1=$($CLI -datadir=$PWD/.devenv/state/bitcoind -conf=$PWD/config/bitcoin1.conf -regtest -rpcuser=user -rpcpassword=password getpeerinfo | jq -r '.[].addr')
        echo "Connected peers:"
        for peer in $PEERS1; do
            if [[ "$peer" == *":18445" ]]; then
                echo "  $peer (Node 2 P2P)"
            elif [[ "$peer" == *":18333" ]]; then
                echo "  $peer (Node 1 P2P - self?)"
            else
                echo "  $peer (ephemeral outbound connection)"
            fi
        done
        PEER_COUNT=$(echo "$PEERS1" | wc -w)
        echo "Total peers: $PEER_COUNT"
    else
        echo "✗ Node 1 not responding"
        HEIGHT1="N/A"
    fi
    
    echo ""
    echo "=== Bitcoin Node 2 ==="
    NODE2_INFO=$($CLI -datadir=$PWD/.devenv/state/bitcoind2 -conf=$PWD/config/bitcoin2.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 getnetworkinfo 2>/dev/null)
    if [ $? -eq 0 ]; then
        # Get RPC port from config file, P2P port from running process
        NODE2_RPC_PORT=$(grep "rpcport=" $PWD/config/bitcoin2.conf | cut -d= -f2)
        NODE2_P2P_PORT=$(echo "$NODE2_INFO" | jq -r '.localaddresses[0].port // empty')
        if [ -z "$NODE2_P2P_PORT" ]; then NODE2_P2P_PORT="18445"; fi
        echo "RPC Port: $NODE2_RPC_PORT, P2P Port: $NODE2_P2P_PORT"
        
        HEIGHT2=$($CLI -datadir=$PWD/.devenv/state/bitcoind2 -conf=$PWD/config/bitcoin2.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 getblockcount)
        echo "Block height: $HEIGHT2"
        
        PEERS2=$($CLI -datadir=$PWD/.devenv/state/bitcoind2 -conf=$PWD/config/bitcoin2.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=18444 getpeerinfo | jq -r '.[].addr')
        echo "Connected peers:"
        for peer in $PEERS2; do
            if [[ "$peer" == *":18333" ]]; then
                echo "  $peer (Node 1 P2P)"
            elif [[ "$peer" == *":18445" ]]; then
                echo "  $peer (Node 2 P2P - self?)"
            else
                echo "  $peer (ephemeral outbound connection)"
            fi
        done
        PEER_COUNT2=$(echo "$PEERS2" | wc -w)
        echo "Total peers: $PEER_COUNT2"
    else
        echo "✗ Node 2 not responding"
        HEIGHT2="N/A"
    fi
    
    echo ""
    echo "=== Summary ==="
    echo "Node 1 Height: $HEIGHT1"
    echo "Node 2 Height: $HEIGHT2"
    if [ "$HEIGHT1" = "$HEIGHT2" ] && [ "$HEIGHT1" != "N/A" ]; then
        echo "✓ Nodes are synchronized"
    else
        echo "✗ Nodes are NOT synchronized"
    fi
    
    if [ -n "$PEERS1" ] && [ -n "$PEERS2" ] && [[ "$PEERS1" == *":$NODE2_P2P_PORT"* ]] && [[ "$PEERS2" == *":$NODE1_P2P_PORT"* ]]; then
        echo "✓ Nodes are connected to each other"
    else
        echo "✗ Nodes are NOT properly connected"
    fi

# Check wallet balance for a specific node
balance node="1":
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    if [ "{{node}}" = "1" ]; then
        DATADIR="$PWD/.devenv/state/bitcoind"
        CONF="$PWD/config/bitcoin1.conf"
        RPC_PORT=""
        NODE_NAME="Node 1"
    elif [ "{{node}}" = "2" ]; then
        DATADIR="$PWD/.devenv/state/bitcoind2"
        CONF="$PWD/config/bitcoin2.conf"
        RPC_PORT="-rpcport=18444"
        NODE_NAME="Node 2"
    else
        echo "Error: node must be 1 or 2"
        exit 1
    fi
    
    echo "=== $NODE_NAME Wallet Balance ==="
    # Try to load wallet if it's not loaded
    if ! $CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
        echo "Loading wallet..."
        $CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT loadwallet default >/dev/null 2>&1 || {
            echo "Error: No wallet found. Run 'just init' to create wallets."
            exit 1
        }
    fi
    
    BALANCE=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getbalance)
    echo "Spendable balance: $BALANCE BTC"
    
    # Show detailed balance breakdown if available
    $CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getbalances 2>/dev/null && echo "" || true



# Clean data (options: all, logs, nostr, btc)
clean type="all":
    #!/usr/bin/env bash
    case "{{type}}" in
        "all")
            echo "Cleaning all data..."
            rm -rf .devenv/state/bitcoind/* .devenv/state/bitcoind2/* .devenv/state/strfry/* logs/*
            echo "✓ All data cleaned"
            ;;
        "logs")
            echo "Cleaning logs..."
            rm -f logs/*.log
            echo "✓ Logs cleaned"
            ;;
        "nostr")
            echo "Cleaning Nostr relay data..."
            rm -rf .devenv/state/strfry/*
            echo "✓ Nostr relay data cleaned"
            ;;
        "btc")
            echo "Cleaning Bitcoin node data..."
            rm -rf .devenv/state/bitcoind/* .devenv/state/bitcoind2/*
            echo "✓ Bitcoin node data cleaned"
            ;;
        *)
            echo "Error: type must be 'all', 'logs', 'nostr', or 'btc'"
            exit 1
            ;;
    esac


