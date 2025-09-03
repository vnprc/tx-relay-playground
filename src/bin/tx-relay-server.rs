use anyhow::Result;
use bitcoin::{consensus::deserialize, Transaction};
use futures_util::{SinkExt, StreamExt};
use nostr::{Event, EventBuilder, Keys, Kind, Tag};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, RwLock};
use tokio_tungstenite::{accept_async, connect_async, tungstenite::protocol::Message, WebSocketStream};
use tracing::{error, info, warn};
use url::Url;

// Bitcoin RPC client module
mod bitcoin_rpc {
    use anyhow::{anyhow, Result};
    use bitcoin::{Block, BlockHash};
    use reqwest::Client;
    use serde_json::{json, Value};
    use std::str::FromStr;

    #[derive(Clone)]
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
    }
}

type ClientMap = Arc<RwLock<HashMap<String, broadcast::Sender<Event>>>>;

// Transaction relay event kinds
const KIND_SUBMIT_TX: u16 = 20010;
const KIND_TX_RESPONSE: u16 = 20011;  
const KIND_TX_BROADCAST: u16 = 20012;
const KIND_REQUEST_TX: u16 = 20013;
const KIND_TX_DETAILS: u16 = 20014;

pub struct TxRelayServer {
    bitcoin_client: bitcoin_rpc::BitcoinRpcClient,
    clients: ClientMap,
    keys: Keys,
    tx_broadcaster: broadcast::Sender<Event>,
    strfry_sender: mpsc::UnboundedSender<Event>,
    strfry_receiver: Arc<tokio::sync::Mutex<mpsc::UnboundedReceiver<Event>>>,
    relay_id: u16,
    // Track transactions received from remote relays to avoid rebroadcasting
    remote_transactions: Arc<RwLock<HashSet<String>>>,
}

impl TxRelayServer {
    pub fn new(relay_id: u16, bitcoin_port: u16) -> Self {
        let bitcoin_url = format!("http://127.0.0.1:{}", bitcoin_port);
        let bitcoin_client = bitcoin_rpc::BitcoinRpcClient::new(
            bitcoin_url,
            "user".to_string(),
            "password".to_string(),
        );
        
        let (tx_broadcaster, _) = broadcast::channel(1000);
        let (strfry_sender, strfry_receiver) = mpsc::unbounded_channel();
        
        Self {
            bitcoin_client,
            clients: Arc::new(RwLock::new(HashMap::new())),
            keys: Keys::generate(),
            tx_broadcaster,
            strfry_sender,
            strfry_receiver: Arc::new(tokio::sync::Mutex::new(strfry_receiver)),
            relay_id,
            remote_transactions: Arc::new(RwLock::new(HashSet::new())),
        }
    }
    
    pub async fn start(&self, addr: SocketAddr) -> Result<()> {
        let listener = TcpListener::bind(addr).await?;
        info!("Relay-{} Bitcoin Transaction Relay Server listening on {}", self.relay_id, addr);
        
        // Start mempool monitoring task
        let server_clone = Arc::new(self.clone());
        tokio::spawn(async move {
            if let Err(e) = server_clone.monitor_mempool().await {
                error!("Relay-{}: Mempool monitoring error: {}", server_clone.relay_id, e);
            }
        });
        
        // Start strfry client connection task
        let server_clone = Arc::new(self.clone());
        tokio::spawn(async move {
            if let Err(e) = server_clone.connect_to_strfry().await {
                error!("Relay-{}: Strfry connection error: {}", server_clone.relay_id, e);
            }
        });
        
        while let Ok((stream, peer_addr)) = listener.accept().await {
            info!("New client connection from {}", peer_addr);
            let server = Arc::new(self.clone());
            tokio::spawn(async move {
                if let Err(e) = server.handle_connection(stream, peer_addr).await {
                    error!("Error handling connection from {}: {}", peer_addr, e);
                }
            });
        }
        
        Ok(())
    }
    
    async fn handle_connection(&self, stream: TcpStream, peer_addr: SocketAddr) -> Result<()> {
        let ws_stream = accept_async(stream).await?;
        let client_id = peer_addr.to_string();
        
        let (tx_sender, mut tx_receiver) = broadcast::channel(100);
        self.clients.write().await.insert(client_id.clone(), tx_sender);
        
        let (mut ws_sender, mut ws_receiver) = ws_stream.split();
        let server = self.clone();
        let _client_id_clone = client_id.clone();
        
        // Handle outgoing messages to client
        let broadcast_task = tokio::spawn(async move {
            while let Ok(event) = tx_receiver.recv().await {
                let message = json!(["EVENT", "sub_id", event]).to_string();
                if let Err(e) = ws_sender.send(Message::Text(message)).await {
                    error!("Failed to send message to client: {}", e);
                    break;
                }
            }
        });
        
        // Handle incoming messages from client
        while let Some(msg) = ws_receiver.next().await {
            match msg? {
                Message::Text(text) => {
                    if let Err(e) = server.handle_nostr_message(&text, &client_id).await {
                        error!("Error handling nostr message: {}", e);
                    }
                }
                Message::Close(_) => {
                    info!("Client {} disconnected", client_id);
                    break;
                }
                _ => {}
            }
        }
        
        broadcast_task.abort();
        self.clients.write().await.remove(&client_id);
        Ok(())
    }
    
    async fn handle_nostr_message(&self, message: &str, client_id: &str) -> Result<()> {
        let parsed: Value = serde_json::from_str(message)?;
        
        if let Some(arr) = parsed.as_array() {
            if arr.len() >= 2 {
                let msg_type = arr[0].as_str().unwrap_or("");
                
                match msg_type {
                    "EVENT" => {
                        if arr.len() >= 2 {
                            let event: Event = serde_json::from_value(arr[1].clone())?;
                            self.handle_event(event, client_id).await?;
                        }
                    }
                    "REQ" => {
                        // Handle subscription requests
                        info!("Client {} subscribed", client_id);
                    }
                    _ => {}
                }
            }
        }
        
        Ok(())
    }
    
    async fn handle_event(&self, event: Event, client_id: &str) -> Result<()> {
        let kind = event.kind.as_u32();
        match kind {
            k if k == KIND_SUBMIT_TX as u32 => self.handle_submit_tx(event, client_id).await,
            k if k == KIND_REQUEST_TX as u32 => self.handle_request_tx(event, client_id).await,
            _ => {
                warn!("Unhandled event kind: {}", event.kind.as_u32());
                Ok(())
            }
        }
    }
    
    async fn handle_submit_tx(&self, event: Event, client_id: &str) -> Result<()> {
        info!("🌐 Relay-{}: Received transaction via WEBSOCKET from {}", self.relay_id, client_id);
        
        // Extract raw transaction hex from event content
        let tx_hex = event.content.trim();
        
        // Validate hex format
        if tx_hex.is_empty() || tx_hex.len() % 2 != 0 {
            self.send_tx_response(client_id, false, "Invalid transaction hex format", "").await?;
            return Ok(());
        }
        
        // Decode transaction
        match hex::decode(tx_hex) {
            Ok(tx_bytes) => {
                match deserialize::<Transaction>(&tx_bytes) {
                    Ok(tx) => {
                        let txid = tx.txid().to_string();
                        info!("Decoded transaction: {}", txid);
                        
                        // Submit to Bitcoin node
                        match self.submit_to_bitcoin_node(tx_hex).await {
                            Ok(_) => {
                                self.send_tx_response(client_id, true, "Transaction accepted", &txid).await?;
                                // Don't broadcast here - let mempool monitoring handle local transactions
                            }
                            Err(e) => {
                                error!("Failed to submit transaction to Bitcoin node: {}", e);
                                self.send_tx_response(client_id, false, &e.to_string(), &txid).await?;
                            }
                        }
                    }
                    Err(e) => {
                        error!("Failed to deserialize transaction: {}", e);
                        self.send_tx_response(client_id, false, "Invalid transaction format", "").await?;
                    }
                }
            }
            Err(e) => {
                error!("Failed to decode transaction hex: {}", e);
                self.send_tx_response(client_id, false, "Invalid hex encoding", "").await?;
            }
        }
        
        Ok(())
    }
    
    async fn submit_to_bitcoin_node(&self, tx_hex: &str) -> Result<String> {
        // Use sendrawtransaction RPC call
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sendrawtransaction",
            "params": [tx_hex]
        });
        
        let client = reqwest::Client::new();
        let rpc_url = format!("http://127.0.0.1:{}", 18443 + (self.relay_id - 1));
        let response = client
            .post(&rpc_url)
            .basic_auth("user", Some("password"))
            .json(&request)
            .send()
            .await?
            .json::<Value>()
            .await?;
        
        if let Some(error) = response.get("error") {
            if !error.is_null() {
                return Err(anyhow::anyhow!("Bitcoin RPC error: {}", error));
            }
        }
        
        let txid = response["result"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("No txid in response"))?
            .to_string();
        
        Ok(txid)
    }
    
    async fn send_tx_response(&self, client_id: &str, success: bool, message: &str, txid: &str) -> Result<()> {
        let content = json!({
            "success": success,
            "message": message,
            "txid": txid
        });
        
        let event = EventBuilder::new(
            Kind::Ephemeral(KIND_TX_RESPONSE),
            content.to_string(),
            &[]
        ).to_event(&self.keys)?;
        
        if let Some(sender) = self.clients.read().await.get(client_id) {
            let _ = sender.send(event);
        }
        
        Ok(())
    }
    
    async fn broadcast_transaction(&self, tx: &Transaction, txid: &str) -> Result<()> {
        info!("Broadcasting transaction {} to strfry relay", txid);
        
        let content = json!({
            "txid": txid,
            "size": bitcoin::consensus::serialize(tx).len(),
            "version": tx.version,
            "inputs": tx.input.len(),
            "outputs": tx.output.len(),
            "hex": hex::encode(bitcoin::consensus::serialize(tx))
        });
        
        let event = EventBuilder::new(
            Kind::Ephemeral(KIND_TX_BROADCAST), 
            content.to_string(),
            &[
                Tag::Hashtag("bitcoin".to_string()),
                Tag::Hashtag("transaction".to_string()),
                Tag::Generic(
                    nostr::TagKind::Custom("relay_id".to_string()),
                    vec![self.relay_id.to_string()],
                ),
            ]
        ).to_event(&self.keys)?;
        
        // Send to strfry relay
        match self.send_to_strfry(&event).await {
            Ok(_) => info!("Relay-{}: Successfully broadcast transaction {} to strfry", self.relay_id, txid),
            Err(e) => error!("Relay-{}: Failed to broadcast transaction {} to strfry: {}", self.relay_id, txid, e),
        }
        
        // Also broadcast to any direct WebSocket clients
        let clients = self.clients.read().await;
        for sender in clients.values() {
            let _ = sender.send(event.clone());
        }
        
        Ok(())
    }
    
    async fn send_to_strfry(&self, event: &Event) -> Result<()> {
        // Send via the channel to the persistent connection
        if let Err(_) = self.strfry_sender.send(event.clone()) {
            return Err(anyhow::anyhow!("Failed to send event to strfry channel"));
        }
        Ok(())
    }
    
    async fn handle_request_tx(&self, _event: Event, client_id: &str) -> Result<()> {
        // Handle transaction lookup requests
        info!("Transaction request from client {}", client_id);
        // TODO: Implement transaction lookup
        Ok(())
    }
    
    async fn monitor_mempool(&self) -> Result<()> {
        // Initialize known_txids with current mempool state to avoid rebroadcasting existing transactions
        let mut known_txids = match self.get_mempool_txids().await {
            Ok(txids) => {
                info!("Relay-{}: Initialized with {} existing transactions in mempool", self.relay_id, txids.len());
                txids.into_iter().collect()
            }
            Err(e) => {
                warn!("Relay-{}: Failed to get initial mempool state: {}, starting with empty set", self.relay_id, e);
                std::collections::HashSet::new()
            }
        };
        info!("Relay-{}: Starting mempool monitoring", self.relay_id);
        
        loop {
            match self.get_mempool_txids().await {
                Ok(current_txids) => {
                    for txid in &current_txids {
                        if !known_txids.contains(txid) {
                            info!("Relay-{}: New transaction in mempool: {}", self.relay_id, txid);
                            
                            // Check if this transaction was received from a remote relay
                            let is_remote = {
                                let remote_txs = self.remote_transactions.read().await;
                                remote_txs.contains(txid)
                            };
                            
                            if !is_remote {
                                // Get raw transaction and broadcast it (only for local transactions)
                                if let Ok(raw_tx) = self.get_raw_transaction(txid).await {
                                    if let Ok(tx) = bitcoin::consensus::deserialize::<bitcoin::Transaction>(
                                        &hex::decode(&raw_tx)?
                                    ) {
                                        info!("📡 Relay-{}: Found transaction {} in LOCAL mempool", self.relay_id, txid);
                                        if let Err(e) = self.broadcast_transaction(&tx, txid).await {
                                            error!("Relay-{}: Failed to broadcast transaction {}: {}", self.relay_id, txid, e);
                                        }
                                    }
                                }
                            } else {
                                info!("Relay-{}: Skipping broadcast of remote transaction {} (already received via Nostr)", self.relay_id, txid);
                            }
                            
                            known_txids.insert(txid.clone());
                        }
                    }
                    
                    // Remove transactions that are no longer in mempool
                    known_txids.retain(|txid| current_txids.contains(txid));
                }
                Err(e) => {
                    error!("Relay-{}: Failed to get mempool: {}", self.relay_id, e);
                }
            }
            
            // Poll every 2 seconds
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
        }
    }
    
    async fn get_mempool_txids(&self) -> Result<Vec<String>> {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getrawmempool",
            "params": []
        });
        
        let client = reqwest::Client::new();
        let rpc_url = format!("http://127.0.0.1:{}", 18443 + (self.relay_id - 1));
        let response = client
            .post(&rpc_url)
            .basic_auth("user", Some("password"))
            .json(&request)
            .send()
            .await?
            .json::<Value>()
            .await?;
        
        if let Some(error) = response.get("error") {
            if !error.is_null() {
                return Err(anyhow::anyhow!("Bitcoin RPC error: {}", error));
            }
        }
        
        let txids: Vec<String> = response["result"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .map(|v| v.as_str().unwrap_or("").to_string())
            .collect();
            
        Ok(txids)
    }
    
    async fn get_raw_transaction(&self, txid: &str) -> Result<String> {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getrawtransaction",
            "params": [txid]
        });
        
        let client = reqwest::Client::new();
        let rpc_url = format!("http://127.0.0.1:{}", 18443 + (self.relay_id - 1));
        let response = client
            .post(&rpc_url)
            .basic_auth("user", Some("password"))
            .json(&request)
            .send()
            .await?
            .json::<Value>()
            .await?;
        
        if let Some(error) = response.get("error") {
            if !error.is_null() {
                return Err(anyhow::anyhow!("Bitcoin RPC error: {}", error));
            }
        }
        
        Ok(response["result"].as_str().unwrap_or("").to_string())
    }
    
    async fn connect_to_strfry(&self) -> Result<()> {
        info!("Relay-{}: Connecting to strfry relay at ws://127.0.0.1:7777", self.relay_id);
        
        loop {
            match self.try_connect_to_strfry().await {
                Ok(_) => {
                    info!("Relay-{}: Strfry connection closed, reconnecting in 5 seconds", self.relay_id);
                }
                Err(e) => {
                    error!("Relay-{}: Failed to connect to strfry: {}, retrying in 5 seconds", self.relay_id, e);
                }
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
        }
    }
    
    async fn try_connect_to_strfry(&self) -> Result<()> {
        let url = Url::parse("ws://127.0.0.1:7777")?;
        let (ws_stream, _) = connect_async(url).await?;
        info!("Relay-{}: Connected to strfry relay", self.relay_id);
        
        let (mut ws_sender, mut ws_receiver) = ws_stream.split();
        
        // Subscribe to transaction broadcasts from other relays (only future events)
        let current_timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
            
        let subscription = json!([
            "REQ",
            format!("tx_relay_{}", self.relay_id),
            {
                "kinds": [KIND_TX_BROADCAST as u64],
                "#t": ["bitcoin", "transaction"],
                "since": current_timestamp
            }
        ]);
        
        ws_sender.send(Message::Text(subscription.to_string())).await?;
        info!("Relay-{}: Subscribed to transaction broadcasts", self.relay_id);
        
        // Get the receiver for outgoing events
        let strfry_receiver = Arc::clone(&self.strfry_receiver);
        let mut strfry_receiver = strfry_receiver.lock().await;
        
        loop {
            tokio::select! {
                // Handle incoming messages from strfry
                msg = ws_receiver.next() => {
                    match msg {
                        Some(Ok(Message::Text(text))) => {
                            if let Err(e) = self.handle_strfry_message(&text).await {
                                error!("Relay-{}: Error handling strfry message: {}", self.relay_id, e);
                            }
                        }
                        Some(Ok(Message::Close(_))) => {
                            info!("Relay-{}: Strfry connection closed", self.relay_id);
                            break;
                        }
                        Some(Err(e)) => {
                            error!("Relay-{}: WebSocket error: {}", self.relay_id, e);
                            break;
                        }
                        None => break,
                        _ => {}
                    }
                }
                // Handle outgoing events to strfry
                event = strfry_receiver.recv() => {
                    if let Some(event) = event {
                        let message = json!(["EVENT", event]);
                        if let Err(e) = ws_sender.send(Message::Text(message.to_string())).await {
                            error!("Relay-{}: Failed to send event to strfry: {}", self.relay_id, e);
                            break;
                        }
                    } else {
                        break;
                    }
                }
            }
        }
        
        Ok(())
    }
    
    async fn handle_strfry_message(&self, message: &str) -> Result<()> {
        let parsed: Value = serde_json::from_str(message)?;
        
        if let Some(arr) = parsed.as_array() {
            if arr.len() >= 3 && arr[0].as_str() == Some("EVENT") {
                let event: Event = serde_json::from_value(arr[2].clone())?;
                
                if event.kind.as_u32() == KIND_TX_BROADCAST as u32 {
                    self.handle_remote_transaction(event).await?;
                }
            }
        }
        
        Ok(())
    }
    
    async fn handle_remote_transaction(&self, event: Event) -> Result<()> {
        // Check if this event came from our own relay to avoid feedback loop
        for tag in &event.tags {
            if let nostr::Tag::Generic(kind, values) = tag {
                if *kind == nostr::TagKind::Custom("relay_id".to_string()) && !values.is_empty() {
                    if let Ok(sender_relay_id) = values[0].parse::<u16>() {
                        if sender_relay_id == self.relay_id {
                            // This is our own event, ignore it
                            return Ok(());
                        }
                    }
                }
            }
        }
        
        // Parse transaction details from the event content
        let tx_data: Value = serde_json::from_str(&event.content)?;
        
        if let Some(tx_hex) = tx_data.get("hex").and_then(|h| h.as_str()) {
            if let Some(txid) = tx_data.get("txid").and_then(|t| t.as_str()) {
                info!("🌐 Relay-{}: Received transaction {} via NOSTR from another relay", self.relay_id, txid);
                
                // Track this transaction as received from remote BEFORE submitting to avoid rebroadcasting
                {
                    let mut remote_txs = self.remote_transactions.write().await;
                    remote_txs.insert(txid.to_string());
                }
                
                // Submit the transaction to our local Bitcoin node
                match self.submit_to_bitcoin_node(tx_hex).await {
                    Ok(_) => {
                        info!("Relay-{}: Successfully submitted remote transaction {} to local Bitcoin node", self.relay_id, txid);
                    }
                    Err(e) => {
                        // Don't log as error if transaction already exists
                        if e.to_string().contains("already in mempool") || e.to_string().contains("already exists") {
                            info!("Relay-{}: Transaction {} already in local mempool", self.relay_id, txid);
                        } else {
                            warn!("Relay-{}: Failed to submit remote transaction {} to local Bitcoin node: {}", self.relay_id, txid, e);
                        }
                    }
                }
            }
        }
        
        Ok(())
    }
}

impl Clone for TxRelayServer {
    fn clone(&self) -> Self {
        Self {
            bitcoin_client: self.bitcoin_client.clone(),
            clients: Arc::clone(&self.clients),
            keys: self.keys.clone(),
            tx_broadcaster: self.tx_broadcaster.clone(),
            strfry_sender: self.strfry_sender.clone(),
            strfry_receiver: Arc::clone(&self.strfry_receiver),
            relay_id: self.relay_id,
            remote_transactions: Arc::clone(&self.remote_transactions),
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    let args: Vec<String> = std::env::args().collect();
    let relay_id: u16 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(1);
    let port: u16 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(7779 + relay_id - 1);
    let bitcoin_port: u16 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(18443);
    
    info!("Starting Bitcoin Transaction Relay Server");
    
    let server = TxRelayServer::new(relay_id, bitcoin_port);
    let addr = format!("127.0.0.1:{}", port).parse()?;
    
    server.start(addr).await?;
    
    Ok(())
}