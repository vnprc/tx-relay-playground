# Bitcoin development commands for TxRelay
#
# Port configuration is centralized in config/ports.toml
# Ports are loaded dynamically using yq
#
# Bitcoin Node Ports (loaded dynamically from config/ports.toml)
NODE1_RPC := `yq eval '.bitcoin.node1.rpc' config/ports.toml`
NODE1_P2P := `yq eval '.bitcoin.node1.p2p' config/ports.toml`
NODE2_RPC := `yq eval '.bitcoin.node2.rpc' config/ports.toml`
NODE2_P2P := `yq eval '.bitcoin.node2.p2p' config/ports.toml`
NODE1_DATADIR := `yq eval '.bitcoin.node1.datadir' config/ports.toml`
NODE2_DATADIR := `yq eval '.bitcoin.node2.datadir' config/ports.toml`

# List all available recipes
default:
    @just --list

# Start the development environment  
up:
    #!/usr/bin/env bash
    if [ -z "$DEVENV_STATE" ]; then
        echo "Starting devenv shell and running devenv up..."
        devenv shell -c "just up"
    else
        devenv up
    fi



# Create transaction and leave in mempool (don't mine block)  
create-tx node="1" amount="0.00001":
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    if [ "{{node}}" = "1" ]; then
        DATADIR="$PWD/.devenv/state/{{NODE1_DATADIR}}"
        CONF="$PWD/config/bitcoin-base.conf"
        RPC_PORT="-rpcport={{NODE1_RPC}}"
        NODE_NAME="Node 1"
    elif [ "{{node}}" = "2" ]; then
        DATADIR="$PWD/.devenv/state/{{NODE2_DATADIR}}"
        CONF="$PWD/config/bitcoin-base.conf"
        RPC_PORT="-rpcport={{NODE2_RPC}}"
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
    FEE="0.00001"
    TOTAL_NEEDED=$(echo "{{amount}} + $FEE" | bc -l)
    
    # Check if we have enough funds
    if [ $(echo "$UTXO_AMOUNT < $TOTAL_NEEDED" | bc -l) -eq 1 ]; then
        echo "Error: Insufficient funds. UTXO: $UTXO_AMOUNT BTC, needed: $TOTAL_NEEDED BTC ({{amount}} + $FEE fee)"
        exit 1
    fi
    
    CHANGE=$(printf "%.8f" $(echo "$UTXO_AMOUNT - {{amount}} - $FEE" | bc -l))
    
    # Create raw transaction
    RAW_TX=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT createrawtransaction "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "{\"$ADDR\":{{amount}},\"$(echo $($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getrawchangeaddress))\":$CHANGE}")
    
    # Sign the transaction
    SIGNED_TX=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default signrawtransactionwithwallet $RAW_TX | jq -r '.hex')
    
    # Broadcast to mempool
    TXID=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT sendrawtransaction $SIGNED_TX 2>&1)
    
    if [ $? -eq 0 ] && [[ "$TXID" =~ ^[a-f0-9]{64}$ ]]; then
        echo "✓ Transaction $TXID created in $NODE_NAME mempool (not mined yet)"
    else
        echo "✗ Transaction failed in $NODE_NAME:"
        echo "$TXID"
        exit 1
    fi


# Mine blocks to confirm mempool transactions (default: node 1, 1 block)
mine node="1" blocks="1":
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    if [ "{{node}}" = "1" ]; then
        DATADIR="$PWD/.devenv/state/{{NODE1_DATADIR}}"
        CONF="$PWD/config/bitcoin-base.conf"
        RPC_PORT="-rpcport={{NODE1_RPC}}"
        NODE_NAME="Node 1"
    elif [ "{{node}}" = "2" ]; then
        DATADIR="$PWD/.devenv/state/{{NODE2_DATADIR}}"
        CONF="$PWD/config/bitcoin-base.conf"
        RPC_PORT="-rpcport={{NODE2_RPC}}"
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
    
    # Check mempool before mining
    MEMPOOL_COUNT=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT getmempoolinfo | jq -r '.size')
    echo "Mining {{blocks}} block(s) with $NODE_NAME (mempool: $MEMPOOL_COUNT txs)"
    
    # Get mining address
    ADDR=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default getnewaddress "mining")
    
    # Mine blocks
    BLOCK_HASHES=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT -rpcwallet=default generatetoaddress {{blocks}} "$ADDR")
    
    # Show results
    NEW_HEIGHT=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT getblockcount)
    NEW_MEMPOOL=$($CLI -datadir=$DATADIR -conf=$CONF -regtest -rpcuser=user -rpcpassword=password $RPC_PORT getmempoolinfo | jq -r '.size')
    
    echo "✓ Mined {{blocks}} block(s) to height $NEW_HEIGHT (mempool now: $NEW_MEMPOOL txs)"
    if [ {{blocks}} -eq 1 ]; then
        BLOCK_HASH=$(echo "$BLOCK_HASHES" | jq -r '.[0]')
        echo "Block hash: ${BLOCK_HASH:0:16}..."
    fi

# Get blockchain info  
info:
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    echo "=== Bitcoin Node 1 Blockchain Info ==="
    BLOCKCHAIN_INFO=$($CLI -datadir=$PWD/.devenv/state/{{NODE1_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE1_RPC}} getblockchaininfo 2>/dev/null)
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
        LATEST_BLOCK=$($CLI -datadir=$PWD/.devenv/state/{{NODE1_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE1_RPC}} getblock "$BEST_HASH" 2>/dev/null)
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
    
    # Get dynamic port values
    STRFRY1_PORT=`yq eval '.nostr.strfry1' config/ports.toml`
    STRFRY2_PORT=`yq eval '.nostr.strfry2' config/ports.toml` 
    SERVER1_PORT=`yq eval '.txrelay.server1' config/ports.toml`
    SERVER2_PORT=`yq eval '.txrelay.server2' config/ports.toml`
    
    echo "┌───────────────────────────┐"
    echo "│ 🚀 TxRelay Network Status │"
    echo "└───────────────────────────┘"
    echo ""
    
    # Bitcoin Nodes Combined
    echo "🟡 Bitcoin Nodes"
    
    # Node 1
    NODE1_INFO=$($CLI -datadir=$PWD/.devenv/state/{{NODE1_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE1_RPC}} getnetworkinfo 2>/dev/null)
    if [ $? -eq 0 ]; then
        HEIGHT1=$($CLI -datadir=$PWD/.devenv/state/{{NODE1_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE1_RPC}} getblockcount)
        echo "  Bitcoin Node 1 - Height: $HEIGHT1"
        echo "    TX-Relay-1 RPC (18332)"
        
        # Check if Node 2 P2P connection exists
        PEERS1=$($CLI -datadir=$PWD/.devenv/state/{{NODE1_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE1_RPC}} getpeerinfo | jq -r '.[].addr')
        if [[ "$PEERS1" == *":{{NODE2_P2P}}"* ]]; then
            echo "    Bitcoin Node 2 P2P ({{NODE2_P2P}})"
        else
            echo "    Bitcoin Node 2 P2P ({{NODE2_P2P}}) - ✗ not connected"
        fi
    else
        echo "  ✗ Bitcoin Node 1 not responding"
        HEIGHT1="N/A"
    fi
    
    # Node 2  
    NODE2_INFO=$($CLI -datadir=$PWD/.devenv/state/{{NODE2_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE2_RPC}} getnetworkinfo 2>/dev/null)
    if [ $? -eq 0 ]; then
        HEIGHT2=$($CLI -datadir=$PWD/.devenv/state/{{NODE2_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE2_RPC}} getblockcount)
        echo "  Bitcoin Node 2 - Height: $HEIGHT2"
        echo "    TX-Relay-2 RPC (18444)"
        
        # Check if Node 1 P2P connection exists
        PEERS2=$($CLI -datadir=$PWD/.devenv/state/{{NODE2_DATADIR}} -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport={{NODE2_RPC}} getpeerinfo | jq -r '.[].addr')
        if [[ "$PEERS2" == *":{{NODE1_P2P}}"* ]]; then
            echo "    Bitcoin Node 1 P2P ({{NODE1_P2P}})"
        else
            echo "    Bitcoin Node 1 P2P ({{NODE1_P2P}}) - ✗ not connected"
        fi
        
        # Sync status
        if [ "$HEIGHT1" = "$HEIGHT2" ] && [ "$HEIGHT1" != "N/A" ]; then
            echo "  ✓ Nodes synchronized at height $HEIGHT1"
        else
            echo "  ✗ Nodes NOT synchronized (Node1:$HEIGHT1 Node2:$HEIGHT2)"
        fi
    else
        echo "  ✗ Bitcoin Node 2 not responding"
    fi
    
    echo ""
    echo "🟣 Nostr Relays"
    
    # Strfry-1
    if nc -z 127.0.0.1 $STRFRY1_PORT 2>/dev/null; then
        echo "  ✓ Strfry-1"
        echo "    TX-Relay-1 WebSocket ($SERVER1_PORT)"
        echo "    Strfry-2 federation ($STRFRY2_PORT)"
    else
        echo "  ✗ Strfry-1 ($STRFRY1_PORT) not responding"
    fi
    
    # Strfry-2
    if nc -z 127.0.0.1 $STRFRY2_PORT 2>/dev/null; then
        echo "  ✓ Strfry-2"
        echo "    TX-Relay-2 WebSocket ($SERVER2_PORT)"  
        echo "    Strfry-1 federation ($STRFRY1_PORT)"
    else
        echo "  ✗ Strfry-2 ($STRFRY2_PORT) not responding"
    fi
    
    echo ""
    echo "🟢 Transaction Relays"
    
    # TX-Relay-1
    if nc -z 127.0.0.1 $SERVER1_PORT 2>/dev/null; then
        echo "  ✓ TX-Relay-1"
        echo "    Bitcoin Node 1 RPC ({{NODE1_RPC}})"
        echo "    Strfry-1 WebSocket ($STRFRY1_PORT)"
    else
        echo "  ✗ TX-Relay-1 ($SERVER1_PORT) not responding"
    fi
    
    # TX-Relay-2
    if nc -z 127.0.0.1 $SERVER2_PORT 2>/dev/null; then
        echo "  ✓ TX-Relay-2"
        echo "    Bitcoin Node 2 RPC ({{NODE2_RPC}})"
        echo "    Strfry-2 WebSocket ($STRFRY2_PORT)"
    else
        echo "  ✗ TX-Relay-2 ($SERVER2_PORT) not responding"
    fi

# Rescan wallet to rebuild UTXO set (options: 1, 2, or "all")
rescan node="all":
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    
    rescan_wallet() {
        local node_num=$1
        local datadir=$2
        local rpc_port=$3
        local node_name=$4
        
        echo "=== Rescanning $node_name Wallet ==="
        # Ensure wallet is loaded
        if ! $CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
            echo "Loading wallet..."
            $CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port loadwallet default >/dev/null 2>&1 || {
                echo "Error: No wallet found for $node_name"
                return 1
            }
        fi
        
        echo "Rescanning blockchain for $node_name..."
        $CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default rescanblockchain 0 >/dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo "✓ $node_name wallet rescan completed"
            # Show updated balance
            BALANCE=$($CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default getbalance)
            UTXO_COUNT=$($CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default listunspent | jq length)
            echo "Balance: $BALANCE BTC, UTXOs: $UTXO_COUNT"
        else
            echo "✗ $node_name wallet rescan failed"
        fi
        echo ""
    }
    
    if [ "{{node}}" = "all" ]; then
        rescan_wallet 1 "$PWD/.devenv/state/{{NODE1_DATADIR}}" "{{NODE1_RPC}}" "Node 1"
        rescan_wallet 2 "$PWD/.devenv/state/{{NODE2_DATADIR}}" "{{NODE2_RPC}}" "Node 2"
    elif [ "{{node}}" = "1" ]; then
        rescan_wallet 1 "$PWD/.devenv/state/{{NODE1_DATADIR}}" "{{NODE1_RPC}}" "Node 1"
    elif [ "{{node}}" = "2" ]; then
        rescan_wallet 2 "$PWD/.devenv/state/{{NODE2_DATADIR}}" "{{NODE2_RPC}}" "Node 2"
    else
        echo "Error: node must be 1, 2, or 'all'"
        exit 1
    fi

# Check wallet balance for a specific node (or "all" for both nodes)
balance node="all":
    #!/usr/bin/env bash
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    
    show_balance() {
        local node_num=$1
        local datadir=$2
        local rpc_port=$3
        local node_name=$4
        
        echo "=== $node_name Wallet Balance ==="
        # Try to load wallet if it's not loaded
        if ! $CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
            echo "Loading wallet..."
            $CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port loadwallet default >/dev/null 2>&1 || {
                echo "Error: No wallet found. Run 'just init' to create wallets."
                return 1
            }
        fi
        
        BALANCE=$($CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default getbalance)
        echo "Spendable balance: $BALANCE BTC"
        
        # Show detailed balance breakdown if available
        $CLI -datadir=$datadir -conf=$PWD/config/bitcoin-base.conf -regtest -rpcuser=user -rpcpassword=password -rpcport=$rpc_port -rpcwallet=default getbalances 2>/dev/null && echo "" || true
        echo ""
    }
    
    if [ "{{node}}" = "all" ]; then
        show_balance 1 "$PWD/.devenv/state/{{NODE1_DATADIR}}" "{{NODE1_RPC}}" "Node 1"
        show_balance 2 "$PWD/.devenv/state/{{NODE2_DATADIR}}" "{{NODE2_RPC}}" "Node 2"
    elif [ "{{node}}" = "1" ]; then
        show_balance 1 "$PWD/.devenv/state/{{NODE1_DATADIR}}" "{{NODE1_RPC}}" "Node 1"
    elif [ "{{node}}" = "2" ]; then
        show_balance 2 "$PWD/.devenv/state/{{NODE2_DATADIR}}" "{{NODE2_RPC}}" "Node 2"
    else
        echo "Error: node must be 1, 2, or 'all'"
        exit 1
    fi



# Clean data (options: all, logs, nostr, btc)
clean type="all":
    #!/usr/bin/env bash
    case "{{type}}" in
        "all")
            echo "Cleaning all data..."
            rm -rf .devenv/state/bitcoind/* .devenv/state/bitcoind2/* .devenv/state/stirfry/* .devenv/state/strfry2/* logs/*
            echo "✓ All data cleaned"
            ;;
        "logs")
            echo "Cleaning logs..."
            rm -f logs/*.log
            echo "✓ Logs cleaned"
            ;;
        "nostr")
            echo "Cleaning Nostr relay data..."
            rm -rf .devenv/state/stirfry/* .devenv/state/strfry2/*
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


