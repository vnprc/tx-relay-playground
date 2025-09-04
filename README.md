# Bitcoin Transaction Relay over Nostr

A proof-of-concept implementation demonstrating how Bitcoin transactions can be shared between independent Bitcoin nodes using the Nostr protocol, creating a censorship-resistant transaction relay network.

## Overview

This project implements a Bitcoin-over-Nostr mesh network where:

- **Two independent Bitcoin nodes** run in blocks-only mode (no P2P transaction relay)
- **Two relay servers** monitor their respective Bitcoin node mempools
- **Transaction sharing** happens exclusively through the Nostr protocol
- **Two Strfry relays** form a federated Nostr network (Strfry-1 ↔ Strfry-2)
- **Cross-relay propagation** demonstrates Bitcoin transactions bridging multiple Nostr networks

When a transaction is created on Bitcoin Node 1, it gets detected by TX Relay 1, broadcast to Strfry-1, propagated to Strfry-2, received by TX Relay 2, and submitted to Bitcoin Node 2's mempool - demonstrating multi-hop transaction relay across federated Nostr networks.

## Architecture

```
┌─────────────┐              ┌─────────────┐
│ Bitcoin     │              │ Bitcoin     │
│ Node 1      │              │ Node 2      │
│ (18332)     │              │ (18444)     │
└─────┬───────┘              └─────┬───────┘
      │                            │
      │ mempool                    │ mempool
      │ monitoring                 │ monitoring
      │                            │
┌─────▼───────┐              ┌─────▼───────┐
│ TX Relay    │              │ TX Relay    │
│ Server 1    │              │ Server 2    │
│ (7779)      │              │ (7780)      │
└─────┬───────┘              └─────┬───────┘
      │                            │
      ▼                            ▼
┌──────────────┐          ┌──────────────┐
│ Strfry-1     │◄────────►│ Strfry-2     │
│ Nostr Relay  │          │ Nostr Relay  │
│   (7777)     │          │   (7778)     │
└──────────────┘          └──────────────┘

    Federation stream keeps relays synchronized
```

## Features

- **🚫 No P2P Transaction Relay**: Bitcoin nodes run in `blocksonly=1` mode
- **📡 Mempool Monitoring**: Relay servers detect new transactions every 2 seconds
- **🌐 Nostr Broadcasting**: Transactions shared via NIP-01 ephemeral events
- **🔄 Auto-submission**: Remote transactions automatically submitted to local Bitcoin nodes

## Quick Start

### Prerequisites

- [Nix](https://nixos.org/download.html) with flakes enabled
- [Devenv](https://devenv.sh/getting-started/)

### Setup

1. Clone the repository:
```bash
git clone <repo-url>
cd TxRelay
```

2. Start the development environment:
```bash
just up
```

This starts all services and auto-initializes wallets:
- Bitcoin Node 1
- Bitcoin Node 2
- Strfry-1 Nostr Relay
- Strfry-2 Nostr Relay
- TX Relay Server 1
- TX Relay Server 2

### Usage

#### Check System Status
```bash
just status         # Node connectivity, sync, and peer connections
just info           # Bitcoin blockchain info
just balance        # Check both wallet balances
just balance 1      # Check Node 1 wallet balance
```

#### Create and Test Transactions

Create a transaction on Node 1:
```bash
just create-tx 1 0.01
```

Create a transaction on Node 2:
```bash
just create-tx 2 0.05
```

The transaction will:
1. 📡 Be detected by the corresponding relay server
2. 🌐 Be broadcast to the Nostr network
3. 🌐 Be received by the other relay server
4. 📡 Be submitted to the other Bitcoin node

#### Monitor Transaction Flow

Watch the relay logs to see transaction sharing in real-time:

**Terminal 1** - Relay 1 logs:
```bash
tail -f logs/tx-relay-1.log
```

**Terminal 2** - Relay 2 logs:
```bash
tail -f logs/tx-relay-2.log
```

Look for these log patterns:
- `📡 Relay-X: Found transaction ABC123... in LOCAL mempool` - Local detection
- `🌐 Relay-X: Received transaction ABC123... via NOSTR from another relay` - Remote reception

## Key Commands

| Command | Description |
|---------|-------------|
| `just balance 1` | Check wallet balance for a specific node (or `all` for both) |
| `just mine 1 5` | Mine blocks to confirm transactions (node, blocks) |
| `just rescan 2` | Rescan wallet to rebuild UTXO set |
| `just clean logs` | Clean data (`all`, `logs`, `nostr`, `btc`) |
| `just create-tx 1 0.01` | Create transaction (default: 0.00001 BTC) |
| `just` | List all available recipes |
| `just info` | Get node and blockchain info |
| `just status` | Check Bitcoin node status (peers, sync, and connection) |
| `just up` | Start the development environment |

## Project Structure

```
TxRelay/
├── src/bin/tx-relay-server.rs  # Main relay server implementation
├── config/
│   ├── ports.toml              # Centralized port configuration
│   └── bitcoin-base.conf       # Shared Bitcoin node config
├── devenv.nix                  # Development environment
├── justfile                    # Command recipes
├── logs/                       # Service logs
└── scripts/                    # Utility scripts
```

## How It Works

### Transaction Detection
Each relay server polls its Bitcoin node's mempool every 2 seconds using the `getrawmempool` RPC call to detect new transactions.

### Nostr Broadcasting
When a new transaction is found locally, the relay server:
1. Creates a Nostr ephemeral event (kind 20012) containing transaction details
2. Sends it to the Strfry relay via WebSocket
3. Tags it with `#bitcoin` and `#transaction` hashtags

### Remote Reception
Other relay servers:
1. Subscribe to transaction broadcast events from Strfry
2. Receive the Nostr event containing transaction data
3. Extract the raw transaction hex
4. Submit it to their local Bitcoin node using `sendrawtransaction`

### Blocks-Only Mode
Bitcoin nodes are configured with `blocksonly=1` to prevent normal P2P transaction relay, ensuring transactions only propagate through the Nostr network.

## Technical Details

- **Language**: Rust with tokio async runtime
- **Bitcoin Integration**: RPC calls via reqwest HTTP client
- **Nostr Protocol**: NIP-01 events with custom kinds for Bitcoin transactions
- **WebSocket**: tokio-tungstenite for Nostr relay communication
- **Development**: Nix/devenv for reproducible environments

## Use Cases

- **Censorship Resistance**: Alternative transaction relay when P2P networks are filtered
- **Privacy**: Transactions routed through different network paths
- **Research**: Studying decentralized transaction propagation mechanisms
- **Testing**: Bitcoin application development with controlled relay behavior

## Configuration

### Centralized Port Management
All ports and data directories are configured in `config/ports.toml`. The configuration includes:
- Bitcoin RPC/P2P ports and data directories
- Nostr relay WebSocket ports
- TX relay server ports
- Operational timeouts

The `justfile` uses `yq` to dynamically load these configurations, ensuring consistency across all services.

## Limitations

- **Proof of Concept**: Not production-ready
- **Federated Relays**: Relies on two Strfry instances with federation
- **No Transaction Validation**: Blindly forwards all received transactions
- **Regtest Only**: Designed for testing environments

## Future Work

### Anti-Spam & Validation
- **Transaction Validation at Relay Level**: Implement basic transaction validation (signature checks, input verification) to prevent malformed or spam transactions from propagating through the network
- **Ecash Postage**: Integrate Cashu ecash tokens as "postage" for transaction relay - users pay small ecash amounts to relay transactions, creating economic spam resistance

### Network Discovery & Scaling
- **Nostr Relay Discovery**: Implement NIP-11 relay information and discovery mechanisms to allow dynamic relay network formation instead of hardcoded federation
- **Gossip Protocol**: Add peer discovery and gossip protocols for automatic relay network topology management

### Data Distribution
- **UTXO Set BitTorrent Seeding**: Distribute UTXO set snapshots via BitTorrent protocol for efficient initial sync of new Bitcoin nodes
- **Block Relay via Blossom**: Use Nostr Blossom (NIP-96) for efficient block distribution - store blocks as blobs and share references via Nostr events

### Performance & Reliability
- **Mempool Synchronization**: Beyond transaction relay, implement full mempool state synchronization between nodes
- **Priority Queuing**: Implement fee-based priority queuing for transaction relay during high network congestion
- **Redundant Relay Paths**: Add multiple relay paths and automatic failover for censorship resistance

### Privacy Enhancements
- **Onion Routing**: Route transactions through multiple relays using onion-style encryption
- **Transaction Mixing**: Implement CoinJoin-style transaction batching at the relay level
- **Timing Obfuscation**: Add random delays and batching to prevent transaction timing analysis

## Contributing

This is a research project demonstrating Bitcoin-over-Nostr concepts. Contributions welcome for:

- Additional relay redundancy
- Transaction validation and filtering
- Performance optimizations
- Production hardening
