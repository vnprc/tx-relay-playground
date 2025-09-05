use anyhow::Result;
use bitcoin_nostr_relay::{BitcoinNostrRelay, Network, RelayConfig};
use std::env;
use tracing::{info, warn};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    // Parse command line arguments
    let args: Vec<String> = env::args().collect();
    
    if args.len() > 1 && (args[1] == "--help" || args[1] == "-h") {
        print_usage();
        return Ok(());
    }
    
    // Determine relay configuration based on environment and arguments
    let relay_id = args.get(1)
        .and_then(|arg| arg.parse::<u16>().ok())
        .unwrap_or(1);
        
    let bitcoin_chain = env::var("BITCOIN_CHAIN").unwrap_or_else(|_| "regtest".to_string());
    
    // Create configuration based on chain type using new API
    let config = match bitcoin_chain.as_str() {
        "testnet4" => {
            info!("Using testnet4 configuration");
            RelayConfig::for_network(Network::Testnet4, relay_id)
        },
        "regtest" | _ => {
            if bitcoin_chain != "regtest" {
                warn!("Unknown chain '{}', defaulting to regtest", bitcoin_chain);
            }
            info!("Using regtest configuration");
            RelayConfig::for_network(Network::Regtest, relay_id)
        }
    };
    
    info!("🚀 Starting TX Relay Server {}", relay_id);
    info!("🔗 Chain: {}", bitcoin_chain);
    info!("📊 Bitcoin RPC: {}", config.bitcoin_rpc_url);
    info!("📡 Strfry URL: {}", config.strfry_url);
    info!("🔌 WebSocket: {}", config.websocket_listen_addr);
    info!("⚡ Validation: {}", if config.validation_config.enable_validation { "enabled" } else { "disabled" });
    info!("⏱️  Mempool polling: {}s", config.mempool_poll_interval.as_secs());
    
    // Create and start the relay using the library
    let mut relay = BitcoinNostrRelay::new(config)?;
    
    info!("🎯 Relay server started - monitoring mempool and relaying transactions");
    
    // Start the relay (this will run indefinitely)
    relay.start().await?;
    
    Ok(())
}

fn print_usage() {
    println!("TX Relay Server - Bitcoin transaction relay over Nostr");
    println!();
    println!("USAGE:");
    println!("    tx-relay-server [RELAY_ID]");
    println!();
    println!("ARGUMENTS:");
    println!("    <RELAY_ID>    Relay identifier (1 or 2) [default: 1]");
    println!();
    println!("ENVIRONMENT VARIABLES:");
    println!("    BITCOIN_CHAIN    Bitcoin network (regtest, testnet4) [default: regtest]");
    println!();
    println!("EXAMPLES:");
    println!("    tx-relay-server              # Start relay 1 on regtest");
    println!("    tx-relay-server 2            # Start relay 2 on regtest");
    println!("    BITCOIN_CHAIN=testnet4 tx-relay-server 1    # Start relay 1 on testnet4");
    println!();
    println!("The relay will:");
    println!("  - Monitor Bitcoin node mempool for new transactions");  
    println!("  - Broadcast transactions to Nostr relay network");
    println!("  - Receive and submit transactions from other relays");
    println!("  - Validate transactions using built-in validation system");
}