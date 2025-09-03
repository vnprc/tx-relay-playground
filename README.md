# Bitcoin Transaction Relay over Nostr

A proof-of-concept implementation demonstrating how Bitcoin transactions can be shared between independent Bitcoin nodes using the Nostr protocol, creating a censorship-resistant transaction relay network.

## Overview

This project implements a Bitcoin-over-Nostr mesh network where:

- **Two independent Bitcoin nodes** run in blocks-only mode (no P2P transaction relay)
- **Two relay servers** monitor their respective Bitcoin node mempools
- **Transaction sharing** happens exclusively through the Nostr protocol
- **Strfry** acts as the central Nostr relay for message coordination

When a transaction is created on one Bitcoin node, it gets detected by the corresponding relay server, broadcast to the Nostr network, and then received and submitted to other Bitcoin nodes by their relay servers.

## Architecture

```
┌─────────────┐    ┌─────────────┐
│ Bitcoin     │    │ Bitcoin     │
│ Node 1      │    │ Node 2      │
│ (18443)     │    │ (18444)     │
└─────┬───────┘    └─────┬───────┘
      │                  │
      │ mempool          │ mempool 
      │ monitoring       │ monitoring
      │                  │
┌─────▼───────┐    ┌─────▼───────┐
│ TX Relay    │    │ TX Relay    │
│ Server 1    │    │ Server 2    │
│ (7779)      │    │ (7780)      │
└─────────────┘    └─────────────┘
      ▲                  ▲
      │                  │
      └────────┬─────────┘
               │
    ┌─────────▼──────────┐
    │ Strfry Nostr Relay │
    │      (7777)        │
    └────────────────────┘
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
- Bitcoin Node 1 (RPC: 18443, P2P: 18333)
- Bitcoin Node 2 (RPC: 18444, P2P: 18445) 
- Strfry Nostr Relay (WebSocket: 7777)
- TX Relay Server 1 (WebSocket: 7779)
- TX Relay Server 2 (WebSocket: 7780)

### Usage

#### Check System Status
```bash
just status         # Node connectivity, sync, and peer connections
just info           # Bitcoin blockchain info
just balance 1      # Check Node 1 wallet balance
just balance 2      # Check Node 2 wallet balance
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
| `just balance node="1"` | Check wallet balance for a specific node |
| `just clean type="all"` | Clean data (`all`, `logs`, `nostr`, `btc`) |
| `just create-tx node="1" amount="0.1"` | Create transaction and submit to one node |
| `just` | List all available recipes |
| `just info` | Get node and blockchain info |
| `just status` | Check Bitcoin node status (peers, sync, and connection) |
| `just up` | Start the development environment |

## Project Structure

```
TxRelay/
├── src/bin/tx-relay-server.rs  # Main relay server implementation
├── config/
│   ├── bitcoin1.conf           # Bitcoin Node 1 config
│   └── bitcoin2.conf           # Bitcoin Node 2 config  
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

## Limitations

- **Proof of Concept**: Not production-ready
- **Single Point of Failure**: Relies on one Strfry relay instance
- **No Transaction Validation**: Blindly forwards all received transactions
- **Regtest Only**: Designed for testing environments

## Contributing

This is a research project demonstrating Bitcoin-over-Nostr concepts. Contributions welcome for:

- Additional relay redundancy
- Transaction validation and filtering
- Performance optimizations
- Production hardening
