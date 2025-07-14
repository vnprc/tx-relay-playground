#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATADIR="${PROJECT_ROOT}/.devenv/state/bitcoind"
CONF="${PROJECT_ROOT}/config/bitcoin.conf"
CLI="${BITCOIND_PATH:-bitcoin-cli} -datadir=${DATADIR} -conf=${CONF} -regtest -rpcuser=user -rpcpassword=password"

# Wait for bitcoind to be ready with longer timeout
echo "Waiting for bitcoind RPC..."
timeout=60
counter=0
until $CLI getblockchaininfo >/dev/null 2>&1; do
  sleep 1
  counter=$((counter + 1))
  if [ $counter -ge $timeout ]; then
    echo "ERROR: Timeout waiting for bitcoind RPC after ${timeout}s"
    exit 1
  fi
  if [ $((counter % 10)) -eq 0 ]; then
    echo "Still waiting... (${counter}s)"
  fi
done
echo "✓ bitcoind RPC ready"

# Check current block height
echo "Checking block height..."
HEIGHT=$($CLI getblockcount)
echo "Current block height: $HEIGHT"

if [ "$HEIGHT" -ge 100 ]; then
  echo "Block height: $HEIGHT, skipping mining."
  exit 0
fi

echo "Creating default wallet..."
if ! $CLI -rpcwallet=default getwalletinfo >/dev/null 2>&1; then
  echo "Creating new wallet..."
  $CLI createwallet default 2>&1 || echo "Wallet creation failed or already exists"
else
  echo "✓ Wallet already exists"
fi

echo "Getting new address..."
ADDR=$($CLI -rpcwallet=default getnewaddress "mine-to" "bech32" 2>&1) || {
  echo "Failed to get address, trying without address type..."
  ADDR=$($CLI -rpcwallet=default getnewaddress "mine-to" 2>&1)
}
echo "Mining address: $ADDR"

echo "Mining 100 blocks to $ADDR..."
$CLI -rpcwallet=default generatetoaddress 100 "$ADDR" 2>&1

echo "Done."

