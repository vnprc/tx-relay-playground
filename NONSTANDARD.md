# Non-Standard Transaction Testing via Nostr Relay

## Overview

This document describes the implementation plan for testing mempool policy violations and non-standard transactions through the Nostr relay network. The goal is to demonstrate that transactions rejected by Bitcoin's P2P mempool policies can still be relayed via Nostr and potentially included in blocks.

## Key Concepts

### Mempool Policy vs Consensus Rules

- **Mempool Policies**: Node-specific rules for DoS protection (configurable)
  - Minimum relay fee
  - Dust thresholds
  - Standard script templates
  - Transaction size limits
  
- **Consensus Rules**: Network-wide validation rules (immutable)
  - Script validity
  - Input/output verification
  - Block size/weight limits

Transactions that violate mempool policies but follow consensus rules are still valid and mineable.

## Transaction Types to Test

| Type | Description | Policy Violation | Consensus Valid |
|------|-------------|-----------------|-----------------|
| `standard` | Normal transaction with proper fee | None | ✓ |
| `zero-fee` | Transaction with 0 sat/vB fee | `minrelaytxfee` | ✓ |
| `dust` | Output of 100 sats | `dustrelayfee` | ✓ |
| `large-opreturn` | 200-byte OP_RETURN data | `datacarriersize` | ✓ |
| `low-fee` | Transaction with 0.1 sat/vB | `minrelaytxfee` | ✓ |
| `bare-multisig` | 1-of-2 bare multisig output | `permitbaremultisig` | ✓ |

## Phase 1: Create Transaction Generation Script

### File: `scripts/create-tx.sh`

#### Requirements
- Accept parameters: `<type> <node> <amount>`
- Source existing `bitcoin-config.sh` for node setup
- Generate appropriate transaction for each type
- Output transaction hex on success
- Show clear error messages on failure

#### Implementation Details

**Standard Transaction**
- Calculate fee at 2 sat/vB
- Create normal P2PKH or P2WPKH output
- Should work with any mempool policy

**Zero-Fee Transaction**
- Set output amount = input amount (no fee)
- Will be rejected by standard policy
- Accepted by permissive policy

**Dust Output Transaction**
- Create output of 100 sats (below 546 sat dust threshold)
- Include normal change output with remaining funds
- Rejected by standard policy due to dust

**Large OP_RETURN Transaction**
- Create OP_RETURN output with 200 bytes of data
- Standard policy limits to 83 bytes
- Use hex-encoded zeros for test data

**Low-Fee Transaction**
- Calculate fee at 0.1 sat/vB (below standard 1 sat/vB minimum)
- Should be rejected by standard but accepted by permissive

**Bare Multisig Transaction**
- Create 1-of-2 multisig output without P2SH wrapping
- Generate two public keys from wallet
- Non-standard script type

#### Script Structure
```bash
#!/usr/bin/env bash
# Usage: ./create-tx.sh <type> <node> <amount>

TYPE="$1"
NODE="$2"
AMOUNT="$3"

# Source configuration
source "$(dirname "$0")/bitcoin-config.sh"

# Setup node parameters
setup_node_params "$NODE"

# Ensure wallet is loaded
ensure_wallet_loaded

# Generate transaction based on type
case "$TYPE" in
    "standard")
        create_standard_tx "$AMOUNT"
        ;;
    "zero-fee")
        create_zero_fee_tx "$AMOUNT"
        ;;
    # ... other types
esac
```

## Phase 2: Create Permissive Config File

### File: `config/bitcoin-permissive.conf`

```conf
# Permissive mempool policies for testing non-standard transactions
# Includes all base configuration
includeconf=bitcoin-base.conf

# Relaxed mempool policies
minrelaytxfee=0.00000000      # Accept zero-fee transactions
dustrelayfee=0.00000000       # Accept dust outputs
blockmintxfee=0.00000000      # Mine zero-fee transactions
datacarriersize=1000          # Accept large OP_RETURN (up to 1KB)
permitbaremultisig=1          # Accept bare multisig outputs

# Maximum mempool size and expiry
maxmempool=1000               # 1GB mempool
mempoolexpiry=87600           # Keep transactions for 1 week

# Chain-specific settings
[regtest]
acceptnonstdtxn=1             # Accept non-standard transactions
```

## Phase 3: Update Justfile

### Replace `create-tx` Recipe

```makefile
# Create transaction of specified type
create-tx type="standard" node="1" amount="0.00001":
    #!/usr/bin/env bash
    ./scripts/create-tx.sh {{type}} {{node}} {{amount}}
```

### Add `restart-node` Recipe

```makefile
# Restart bitcoin node with specific mempool policy
restart-node node="1" policy="base":
    #!/usr/bin/env bash
    set -e
    
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
    BITCOIND="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoind"
    
    if [ "{{node}}" = "1" ]; then
        DATADIR="$PWD/.devenv/state/{{NODE1_DATADIR}}"
        RPC_PORT="{{NODE1_RPC}}"
        P2P_PORT="{{NODE1_P2P}}"
    elif [ "{{node}}" = "2" ]; then
        DATADIR="$PWD/.devenv/state/{{NODE2_DATADIR}}"
        RPC_PORT="{{NODE2_RPC}}"
        P2P_PORT="{{NODE2_P2P}}"
    else
        echo "Error: node must be 1 or 2"
        exit 1
    fi
    
    # Stop the node gracefully
    echo "Stopping Bitcoin Node {{node}}..."
    $CLI -datadir=$DATADIR -conf=$PWD/config/bitcoin-{{policy}}.conf {{CHAIN_FLAG}} \
         -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT stop 2>/dev/null || true
    
    # Wait for shutdown
    sleep 3
    
    # Start with new config
    echo "Starting Bitcoin Node {{node}} with {{policy}} policy..."
    $BITCOIND -datadir=$DATADIR -conf=$PWD/config/bitcoin-{{policy}}.conf {{CHAIN_FLAG}} \
              -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT \
              -port=$P2P_PORT -daemon
    
    # Wait for startup
    sleep 5
    
    # Load wallet
    $CLI -datadir=$DATADIR -conf=$PWD/config/bitcoin-{{policy}}.conf {{CHAIN_FLAG}} \
         -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT loadwallet default 2>/dev/null || \
    $CLI -datadir=$DATADIR -conf=$PWD/config/bitcoin-{{policy}}.conf {{CHAIN_FLAG}} \
         -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT createwallet default
    
    # Save policy state for status command
    echo "{{policy}}" > $DATADIR/.mempool_policy
    
    echo "✓ Node {{node}} restarted with {{policy}} mempool policy"
```

## Phase 4: Update Status Display

### Modify `status` Recipe

Add policy detection to the status output:

```bash
# In the status recipe, for each node:
POLICY_FILE="$PWD/.devenv/state/{{NODE1_DATADIR}}/.mempool_policy"
if [ -f "$POLICY_FILE" ]; then
    POLICY=$(cat "$POLICY_FILE")
else
    POLICY="base"
fi
echo "  Bitcoin Node 1 - Height: $HEIGHT1 [Policy: $POLICY]"
```

## Phase 5: Add Helper Script for Common Functions

### File: `scripts/bitcoin-config.sh`

Add new functions if not already present:

```bash
# Setup node parameters based on node number
setup_node_params() {
    local node=$1
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
    
    CONF="$PWD/config/bitcoin-base.conf"
    CHAIN_FLAG="-regtest"  # Or detect from BITCOIN_CHAIN env
    CLI="/nix/store/m2ds8wlwzbljnmw4kasaqn6578a4g7n1-devenv-profile/bin/bitcoin-cli"
}

# Ensure wallet is loaded
ensure_wallet_loaded() {
    if ! $CLI -datadir=$DATADIR -conf=$CONF $CHAIN_FLAG \
         -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT \
         -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
        
        $CLI -datadir=$DATADIR -conf=$CONF $CHAIN_FLAG \
             -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT \
             loadwallet default >/dev/null 2>&1 || \
        $CLI -datadir=$DATADIR -conf=$CONF $CHAIN_FLAG \
             -rpcuser=user -rpcpassword=password -rpcport=$RPC_PORT \
             createwallet default >/dev/null 2>&1
    fi
}
```

## Testing Workflow

### Test 1: Standard Policy Rejection

```bash
# Both nodes running with base (standard) policy
just create-tx zero-fee 1 0.001
# Expected: Transaction rejected with "min relay fee not met"
```

### Test 2: Permissive Policy Acceptance

```bash
# Restart node 1 with permissive policy
just restart-node 1 permissive

# Create zero-fee transaction
just create-tx zero-fee 1 0.001
# Expected: Transaction accepted into Node 1 mempool

# Monitor logs to see if it propagates via Nostr
tail -f logs/tx-relay-1.log
```

### Test 3: Mixed Policy Network

```bash
# Node 1 permissive, Node 2 standard
just restart-node 1 permissive
just restart-node 2 base

# Create non-standard transaction on Node 1
just create-tx dust 1 0.001

# Watch if Node 2 rejects it
tail -f logs/tx-relay-2.log
```

### Test 4: Direct Mining of Policy-Invalid Transactions

```bash
# Even if rejected from mempool, can still mine directly
TXHEX=$(just create-tx zero-fee 1 0.001 | grep "Raw transaction:" | cut -d' ' -f3)
bitcoin-cli generateblock <address> "[\"$TXHEX\"]"
```

## Expected Outcomes

1. **With Standard Policy**:
   - Non-standard transactions rejected from mempool
   - Won't propagate via P2P or Nostr relay
   - Can still be mined directly using `generateblock`

2. **With Permissive Policy**:
   - Non-standard transactions accepted into mempool
   - Detected by tx-relay server
   - Broadcast via Nostr to other nodes
   - Other nodes accept/reject based on their policy

3. **Mixed Network**:
   - Demonstrates policy heterogeneity
   - Shows Nostr as alternative propagation path
   - Highlights difference between policy and consensus

## Monitoring and Verification

### Check Mempool Contents
```bash
bitcoin-cli -rpcport=18332 getrawmempool
bitcoin-cli -rpcport=18444 getrawmempool
```

### Test Mempool Acceptance
```bash
bitcoin-cli -rpcport=18332 testmempoolaccept '["<raw_tx_hex>"]'
```

### Monitor Relay Logs
```bash
# Terminal 1
tail -f logs/tx-relay-1.log | grep -E "Found transaction|Received transaction"

# Terminal 2
tail -f logs/tx-relay-2.log | grep -E "Found transaction|Received transaction"
```

## Implementation Timeline

1. **Phase 1** (30 min): Create transaction generation script
2. **Phase 2** (10 min): Create permissive config file
3. **Phase 3** (20 min): Update justfile with new recipes
4. **Phase 4** (15 min): Update status display
5. **Phase 5** (15 min): Test and refine

Total estimated time: ~1.5 hours

## Future Enhancements

1. **Direct Nostr Broadcasting**: Script to send raw transactions directly to Nostr, bypassing local mempool entirely
2. **Policy Comparison Tool**: Automated testing of which policies allow which transactions
3. **Mining Strategies**: Test including non-standard transactions in blocks via `generateblock`
4. **Fee Bumping**: Test RBF with non-standard transactions
5. **Package Relay**: Test CPFP with mixed standard/non-standard transactions