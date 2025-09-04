# TX-Relay Library Extraction Plan

## Current Codebase Analysis
The current `tx-relay` project has:
- **Binary**: `src/bin/tx-relay-server.rs` (main server application)
- **Library modules**: 
  - `src/bitcoin_rpc.rs` - Bitcoin Core RPC client
  - `src/validation.rs` - Transaction validation with caching
  - `src/nostr.rs` - Nostr client for WebSocket communication
  - `src/lib.rs` - Library root (currently minimal)

## Library Structure Design

### New Repository: `bitcoin-nostr-relay`
```
bitcoin-nostr-relay/
├── flake.nix                    # Nix flake for library
├── Cargo.toml                   # Library-focused dependencies
├── src/
│   ├── lib.rs                   # Main library API
│   ├── bitcoin/
│   │   ├── mod.rs              # Bitcoin module
│   │   ├── rpc.rs              # Bitcoin RPC client
│   │   └── transaction.rs      # Transaction utilities
│   ├── nostr/
│   │   ├── mod.rs              # Nostr module  
│   │   ├── client.rs           # Nostr WebSocket client
│   │   ├── events.rs           # Bitcoin transaction event types
│   │   └── relay.rs            # Relay connection management
│   ├── validation/
│   │   ├── mod.rs              # Validation module
│   │   ├── cache.rs            # Transaction cache
│   │   └── rules.rs            # Validation rules
│   └── relay/
│       ├── mod.rs              # Relay orchestration
│       ├── server.rs           # Core relay server logic
│       └── config.rs           # Configuration types
├── examples/
│   ├── simple_relay.rs         # Basic relay example
│   └── multi_chain.rs          # Multi-chain example
└── README.md
```

## Library API Design

### Core API (`src/lib.rs`):
```rust
pub use bitcoin::BitcoinRpcClient;
pub use nostr::{NostrClient, BitcoinTxEvent};
pub use validation::{TransactionValidator, ValidationConfig};
pub use relay::{RelayServer, RelayConfig};

// High-level API
pub struct BitcoinNostrRelay {
    bitcoin_client: BitcoinRpcClient,
    nostr_client: NostrClient,
    validator: TransactionValidator,
    config: RelayConfig,
}

impl BitcoinNostrRelay {
    pub fn new(config: RelayConfig) -> Result<Self>;
    pub async fn start(&mut self) -> Result<()>;
    pub async fn broadcast_transaction(&self, tx_hex: &str) -> Result<()>;
    pub async fn subscribe_to_transactions(&self) -> Result<()>;
}
```

## Migration Steps

### Phase 1: Extract Core Library
1. Create new `bitcoin-nostr-relay` repository
2. Move `bitcoin_rpc.rs`, `validation.rs`, `nostr.rs` to organized modules
3. Create comprehensive library API
4. Add configuration management
5. Create flake.nix with proper library dependencies

### Phase 2: Update Original Project
1. Add `bitcoin-nostr-relay` as dependency in TxRelay
2. Replace local modules with library calls
3. Simplify `tx-relay-server.rs` to focus on application logic
4. Update devenv.nix to use library flake as input

## Benefits
- **Reusable**: Other projects can use Bitcoin-over-Nostr functionality
- **Modular**: Clean separation of concerns
- **Testable**: Library can be unit tested independently  
- **Extensible**: Plugin architecture for custom features
- **Maintainable**: Clear API boundaries

This creates a robust, reusable library while keeping the original TxRelay project as a demonstration application.