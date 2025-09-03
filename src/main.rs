use anyhow::Result;
use bitcoin::BlockHash;
use serde_json::json;
use tokio_tungstenite::connect_async;
use tracing::{error, info};
use url::Url;

mod nostr;
mod bitcoin_rpc;

use nostr::*;
use bitcoin_rpc::*;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    info!("Starting TxRelay - Bitcoin to Nostr transaction relay");
    
    let bitcoin_client = BitcoinRpcClient::new(
        "http://127.0.0.1:18443".to_string(),
        "user".to_string(),
        "password".to_string(),
    );
    
    // Connect to strfry relay
    let url = Url::parse("ws://127.0.0.1:7777")?;
    let (ws_stream, _) = connect_async(url).await?;
    let nostr_client = NostrClient::new(ws_stream);
    
    info!("Connected to Bitcoin RPC and Nostr relay");
    
    // Start monitoring for new transactions
    let mut last_block_hash: Option<BlockHash> = None;
    
    loop {
        match bitcoin_client.get_best_block_hash().await {
            Ok(current_hash) => {
                if Some(current_hash) != last_block_hash {
                    info!("New block detected: {}", current_hash);
                    
                    // Get the block and process transactions
                    match bitcoin_client.get_block(&current_hash).await {
                        Ok(block) => {
                            info!("Block {} has {} transactions", current_hash, block.txdata.len());
                            for tx in &block.txdata {
                                // Skip coinbase transactions (first transaction in block)
                                if tx.is_coin_base() {
                                    info!("Skipping coinbase transaction: {}", tx.txid());
                                    continue;
                                }
                                
                                info!("Processing transaction: {}", tx.txid());
                                
                                // Create and send nostr event for this transaction
                                let content = create_tx_content(tx, &current_hash)?;
                                if let Err(e) = nostr_client.send_tx_event(&content, &current_hash.to_string()).await {
                                    error!("Failed to send nostr event: {}", e);
                                }
                            }
                        }
                        Err(e) => error!("Failed to get block {}: {}", current_hash, e),
                    }
                    
                    last_block_hash = Some(current_hash);
                }
            }
            Err(e) => {
                error!("Failed to get best block hash: {}", e);
            }
        }
        
        // Poll every 5 seconds
        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
    }
}

fn create_tx_content(tx: &bitcoin::Transaction, block_hash: &BlockHash) -> Result<String> {
    let content = json!({
        "txid": tx.txid().to_string(),
        "block_hash": block_hash.to_string(),
        "inputs": tx.input.iter().map(|input| {
            let script_bytes = input.script_sig.to_bytes();
            let script_hex = if script_bytes.is_empty() {
                "00".to_string()  // Use "00" for empty script instead of ""
            } else {
                hex::encode(&script_bytes)
            };
            json!({
                "previous_output": input.previous_output.to_string(),
                "script_sig": script_hex,
                "script_sig_len": script_bytes.len(),
            })
        }).collect::<Vec<_>>(),
        "outputs": tx.output.iter().enumerate().map(|(i, output)| json!({
            "value": output.value,
            "script_pubkey": hex::encode(&output.script_pubkey.to_bytes()),
            "vout": i,
        })).collect::<Vec<_>>(),
        "version": tx.version,
        "lock_time": tx.lock_time.to_consensus_u32(),
    });
    
    Ok(content.to_string())
}