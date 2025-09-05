use anyhow::Result;
use bitcoin_nostr_relay::{BitcoinNostrRelay, RelayConfig};
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
    
    // Create configuration based on chain type
    let config = match bitcoin_chain.as_str() {
        "testnet4" => RelayConfig::testnet4(relay_id),
        _ => RelayConfig::regtest(relay_id),
    };
    
    info!("Starting relay {} for {} chain", relay_id, bitcoin_chain);
    info!("Bitcoin RPC: {}", config.bitcoin_rpc_url);
    info!("Strfry port: {}", config.strfry_port);
    
    // Create and start the relay
    let mut relay = BitcoinNostrRelay::new(config)?;
    relay.start().await?;
    
    Ok(())
}