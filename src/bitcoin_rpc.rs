use anyhow::{anyhow, Result};
use bitcoin::{Block, BlockHash};
use reqwest::Client;
use serde_json::{json, Value};
use std::str::FromStr;

pub struct BitcoinRpcClient {
    client: Client,
    url: String,
    username: String,
    password: String,
}

impl BitcoinRpcClient {
    pub fn new(url: String, username: String, password: String) -> Self {
        Self {
            client: Client::new(),
            url,
            username,
            password,
        }
    }
    
    async fn rpc_call(&self, method: &str, params: &Value) -> Result<Value> {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        });
        
        let response = self
            .client
            .post(&self.url)
            .basic_auth(&self.username, Some(&self.password))
            .json(&request)
            .send()
            .await?
            .json::<Value>()
            .await?;
        
        if let Some(error) = response.get("error") {
            if !error.is_null() {
                return Err(anyhow!("RPC error: {}", error));
            }
        }
        
        response
            .get("result")
            .cloned()
            .ok_or_else(|| anyhow!("No result in RPC response"))
    }
    
    pub async fn get_best_block_hash(&self) -> Result<BlockHash> {
        let result = self.rpc_call("getbestblockhash", &json!([])).await?;
        let hash_str = result
            .as_str()
            .ok_or_else(|| anyhow!("Invalid block hash format"))?;
        BlockHash::from_str(hash_str).map_err(|e| anyhow!("Failed to parse block hash: {}", e))
    }
    
    pub async fn get_block(&self, block_hash: &BlockHash) -> Result<Block> {
        let result = self
            .rpc_call("getblock", &json!([block_hash.to_string(), 0]))
            .await?;
        let block_hex = result
            .as_str()
            .ok_or_else(|| anyhow!("Invalid block hex format"))?;
        let block_bytes = hex::decode(block_hex)?;
        bitcoin::consensus::deserialize(&block_bytes)
            .map_err(|e| anyhow!("Failed to deserialize block: {}", e))
    }
}