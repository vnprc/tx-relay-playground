#!/usr/bin/env bash

# Create various types of Bitcoin transactions
# Usage: ./create-tx.sh <type> <node> <amount>
# Types: standard, zero-fee, dust, large-opreturn, low-fee, bare-multisig

set -e

# Parse arguments
TYPE="${1:-standard}"
NODE="${2:-1}"
AMOUNT="${3:-0.00001}"

# Source configuration
source "$(dirname "$0")/bitcoin-config.sh"

# Setup node parameters
setup_node_params "$NODE"

# Ensure wallet is loaded
ensure_wallet_loaded

# Helper function to get a suitable UTXO
get_utxo() {
    local min_amount=$1
    
    UTXOS=$(bitcoin_cli_wallet listunspent 1 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error getting UTXOs" >&2
        exit 1
    fi
    
    UTXO=$(echo "$UTXOS" | jq -r --arg min "$min_amount" \
        '.[] | select(.amount >= ($min | tonumber)) | {txid, vout, amount} | @base64' | head -1)
    
    if [ -z "$UTXO" ]; then
        echo "Error: No UTXO found with at least $min_amount BTC" >&2
        echo "Available UTXOs:" >&2
        echo "$UTXOS" | jq -r '.[] | "  \(.txid):\(.vout) = \(.amount) BTC"' >&2
        exit 1
    fi
    
    # Decode UTXO info
    UTXO_INFO=$(echo "$UTXO" | base64 -d)
    UTXO_TXID=$(echo "$UTXO_INFO" | jq -r '.txid')
    UTXO_VOUT=$(echo "$UTXO_INFO" | jq -r '.vout')
    UTXO_AMOUNT=$(echo "$UTXO_INFO" | jq -r '.amount')
}

# Create standard transaction
create_standard_tx() {
    echo "Creating standard transaction with 2 sat/vB fee..."
    
    # Get UTXO with enough for amount + fee
    REQUIRED=$(echo "$AMOUNT + 0.00001" | bc -l)
    get_utxo "$REQUIRED"
    
    # Create destination address
    ADDR=$(bitcoin_cli_wallet getnewaddress)
    
    # Calculate change (2 sat/vB fee estimate)
    FEE="0.00001"
    CHANGE=$(echo "$UTXO_AMOUNT - $AMOUNT - $FEE" | bc -l)
    
    # Build outputs
    if [ $(echo "$CHANGE > 0.00001" | bc -l) -eq 1 ]; then
        CHANGE_ADDR=$(bitcoin_cli_wallet getnewaddress)
        OUTPUTS="{\"$ADDR\":$AMOUNT,\"$CHANGE_ADDR\":$CHANGE}"
    else
        OUTPUTS="{\"$ADDR\":$AMOUNT}"
    fi
    
    # Create and sign transaction
    RAW_TX=$(bitcoin_cli createrawtransaction \
        "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "$OUTPUTS")
    
    SIGNED_TX=$(bitcoin_cli_wallet signrawtransactionwithwallet "$RAW_TX" | jq -r '.hex')
    
    # Broadcast
    TXID=$(bitcoin_cli sendrawtransaction "$SIGNED_TX" 2>&1) || {
        echo "Failed to broadcast: $TXID" >&2
        echo "Raw tx hex: $SIGNED_TX"
        exit 1
    }
    
    echo "✓ Standard transaction created: $TXID"
    echo "Raw tx hex: $SIGNED_TX"
}

# Create zero-fee transaction
create_zero_fee_tx() {
    echo "Creating zero-fee transaction (violates minrelaytxfee)..."
    
    # Get UTXO
    get_utxo "$AMOUNT"
    
    # Create destination address
    ADDR=$(bitcoin_cli_wallet getnewaddress)
    
    # Output = Input (no fee)
    OUTPUTS="{\"$ADDR\":$UTXO_AMOUNT}"
    
    # Create and sign transaction
    RAW_TX=$(bitcoin_cli createrawtransaction \
        "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "$OUTPUTS")
    
    SIGNED_TX=$(bitcoin_cli_wallet signrawtransactionwithwallet "$RAW_TX" | jq -r '.hex')
    
    # Try to broadcast
    TXID=$(bitcoin_cli sendrawtransaction "$SIGNED_TX" 2>&1) || {
        echo "Expected rejection: $TXID" >&2
        echo "Raw tx hex: $SIGNED_TX"
        exit 1
    }
    
    echo "✓ Zero-fee transaction created: $TXID"
    echo "Raw tx hex: $SIGNED_TX"
}

# Create dust output transaction
create_dust_tx() {
    echo "Creating transaction with dust output (100 sats)..."
    
    # Get UTXO with enough funds
    get_utxo "0.0001"
    
    # Create addresses
    DUST_ADDR=$(bitcoin_cli_wallet getnewaddress)
    CHANGE_ADDR=$(bitcoin_cli_wallet getnewaddress)
    
    # Create dust output (100 sats) and change
    DUST="0.00000100"
    FEE="0.00001"
    CHANGE=$(echo "$UTXO_AMOUNT - $DUST - $FEE" | bc -l)
    
    OUTPUTS="{\"$DUST_ADDR\":$DUST,\"$CHANGE_ADDR\":$CHANGE}"
    
    # Create and sign transaction
    RAW_TX=$(bitcoin_cli createrawtransaction \
        "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "$OUTPUTS")
    
    SIGNED_TX=$(bitcoin_cli_wallet signrawtransactionwithwallet "$RAW_TX" | jq -r '.hex')
    
    # Try to broadcast
    TXID=$(bitcoin_cli sendrawtransaction "$SIGNED_TX" 2>&1) || {
        echo "Expected rejection: $TXID" >&2
        echo "Raw tx hex: $SIGNED_TX"
        exit 1
    }
    
    echo "✓ Dust output transaction created: $TXID"
    echo "Raw tx hex: $SIGNED_TX"
}

# Create large OP_RETURN transaction
create_large_opreturn_tx() {
    echo "Creating transaction with 200-byte OP_RETURN..."
    
    # Get UTXO
    get_utxo "0.0001"
    
    # Create change address
    ADDR=$(bitcoin_cli_wallet getnewaddress)
    
    # Create 200 bytes of data (400 hex chars)
    DATA=$(printf '%0400x' 0)
    
    # Calculate change
    FEE="0.00001"
    CHANGE=$(echo "$UTXO_AMOUNT - $FEE" | bc -l)
    
    # Create transaction with OP_RETURN
    OUTPUTS="{\"$ADDR\":$CHANGE,\"data\":\"$DATA\"}"
    
    RAW_TX=$(bitcoin_cli createrawtransaction \
        "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "$OUTPUTS")
    
    SIGNED_TX=$(bitcoin_cli_wallet signrawtransactionwithwallet "$RAW_TX" | jq -r '.hex')
    
    # Try to broadcast
    TXID=$(bitcoin_cli sendrawtransaction "$SIGNED_TX" 2>&1) || {
        echo "Expected rejection: $TXID" >&2
        echo "Raw tx hex: $SIGNED_TX"
        exit 1
    }
    
    echo "✓ Large OP_RETURN transaction created: $TXID"
    echo "Raw tx hex: $SIGNED_TX"
}

# Create low-fee transaction
create_low_fee_tx() {
    echo "Creating low-fee transaction (0.1 sat/vB)..."
    
    # Get UTXO
    get_utxo "$AMOUNT"
    
    # Create destination address
    ADDR=$(bitcoin_cli_wallet getnewaddress)
    
    # Calculate very low fee (0.1 sat/vB, ~25 bytes for 1-in-1-out)
    FEE="0.00000025"
    OUTPUT_AMOUNT=$(echo "$UTXO_AMOUNT - $FEE" | bc -l)
    
    OUTPUTS="{\"$ADDR\":$OUTPUT_AMOUNT}"
    
    # Create and sign transaction
    RAW_TX=$(bitcoin_cli createrawtransaction \
        "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" "$OUTPUTS")
    
    SIGNED_TX=$(bitcoin_cli_wallet signrawtransactionwithwallet "$RAW_TX" | jq -r '.hex')
    
    # Try to broadcast
    TXID=$(bitcoin_cli sendrawtransaction "$SIGNED_TX" 2>&1) || {
        echo "Expected rejection: $TXID" >&2
        echo "Raw tx hex: $SIGNED_TX"
        exit 1
    }
    
    echo "✓ Low-fee transaction created: $TXID"
    echo "Raw tx hex: $SIGNED_TX"
}

# Create bare multisig transaction
create_bare_multisig_tx() {
    echo "Creating bare multisig transaction (1-of-2)..."
    
    # Get UTXO
    get_utxo "$AMOUNT"
    
    # Get two public keys from wallet
    ADDR1=$(bitcoin_cli_wallet getnewaddress)
    ADDR2=$(bitcoin_cli_wallet getnewaddress)
    
    # Get address info to extract pubkeys
    INFO1=$(bitcoin_cli_wallet getaddressinfo "$ADDR1")
    INFO2=$(bitcoin_cli_wallet getaddressinfo "$ADDR2")
    
    PUBKEY1=$(echo "$INFO1" | jq -r '.pubkey')
    PUBKEY2=$(echo "$INFO2" | jq -r '.pubkey')
    
    if [ "$PUBKEY1" = "null" ] || [ "$PUBKEY2" = "null" ]; then
        echo "Error: Could not get public keys. Wallet might be descriptor-based." >&2
        echo "Creating simple transaction with OP_RETURN instead..." >&2
        
        # Fallback: Create transaction with OP_RETURN output
        ADDR=$(bitcoin_cli_wallet getnewaddress)
        FEE="0.00001"
        CHANGE=$(echo "$UTXO_AMOUNT - $FEE" | bc -l)
        
        # Create transaction with OP_RETURN and change output
        RAW_TX=$(bitcoin_cli createrawtransaction \
            "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" \
            "{\"$ADDR\":$CHANGE,\"data\":\"51\"}")  # OP_TRUE in OP_RETURN + change
        
    else
        # Create bare 1-of-2 multisig using createmultisig
        echo "Creating 1-of-2 multisig address..."
        MULTISIG_INFO=$(bitcoin_cli createmultisig 1 "[\"$PUBKEY1\",\"$PUBKEY2\"]")
        MULTISIG_ADDR=$(echo "$MULTISIG_INFO" | jq -r '.address')
        
        # Calculate multisig output amount
        FEE="0.00001"
        MULTISIG_AMOUNT=$(echo "$UTXO_AMOUNT - $FEE" | bc -l)
        
        # Create transaction to multisig address
        RAW_TX=$(bitcoin_cli createrawtransaction \
            "[{\"txid\":\"$UTXO_TXID\",\"vout\":$UTXO_VOUT}]" \
            "{\"$MULTISIG_ADDR\":$MULTISIG_AMOUNT}")
    fi
    
    SIGNED_TX=$(bitcoin_cli_wallet signrawtransactionwithwallet "$RAW_TX" | jq -r '.hex')
    
    # Try to broadcast
    TXID=$(bitcoin_cli sendrawtransaction "$SIGNED_TX" 2>&1) || {
        echo "Expected rejection: $TXID" >&2
        echo "Raw tx hex: $SIGNED_TX"
        exit 1
    }
    
    echo "✓ Bare multisig transaction created: $TXID"
    echo "Raw tx hex: $SIGNED_TX"
}

# Main execution
case "$TYPE" in
    "standard")
        create_standard_tx
        ;;
    "zero-fee")
        create_zero_fee_tx
        ;;
    "dust")
        create_dust_tx
        ;;
    "large-opreturn")
        create_large_opreturn_tx
        ;;
    "low-fee")
        create_low_fee_tx
        ;;
    "bare-multisig")
        create_bare_multisig_tx
        ;;
    *)
        echo "Error: Unknown transaction type '$TYPE'"
        echo "Valid types: standard, zero-fee, dust, large-opreturn, low-fee, bare-multisig"
        exit 1
        ;;
esac