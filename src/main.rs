use anyhow::Result;
use bitcoin_nostr_relay::{BitcoinNostrRelay, Network, RelayConfig};
use tracing::info;
use std::env;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    info!("Starting TxRelay - Bitcoin to Nostr transaction relay using library");
    
    // Determine relay configuration based on environment
    let relay_id = env::args().nth(1)
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
                info!("Unknown chain '{}', defaulting to regtest", bitcoin_chain);
            }
            info!("Using regtest configuration");
            RelayConfig::for_network(Network::Regtest, relay_id)
        }
    };
    
    info!("Starting relay {} for {} chain", relay_id, bitcoin_chain);
    info!("Bitcoin RPC: {}", config.bitcoin_rpc_url);
    info!("Strfry URL: {}", config.strfry_url);
    
    // Create and start the relay
    let mut relay = BitcoinNostrRelay::new(config)?;
    relay.start().await?;
    
    Ok(())
}