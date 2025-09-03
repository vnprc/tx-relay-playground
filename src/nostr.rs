use anyhow::Result;
use futures_util::{SinkExt, StreamExt};
use nostr::{Event, EventBuilder, Keys, Kind, Tag};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_tungstenite::{tungstenite::protocol::Message, WebSocketStream, MaybeTlsStream};
use tracing::{info, warn};

pub struct NostrClient {
    ws_stream: Arc<Mutex<WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>>>,
    keys: Keys,
}

impl NostrClient {
    pub fn new(ws_stream: WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>) -> Self {
        // Generate random keys for demonstration - in production, use persistent keys
        let keys = Keys::generate();
        
        Self {
            ws_stream: Arc::new(Mutex::new(ws_stream)),
            keys,
        }
    }
    
    pub async fn send_tx_event(&self, content: &str, block_hash: &str) -> Result<()> {
        // Create bitcoin transaction event (ephemeral)
        let event = EventBuilder::new(
            Kind::Ephemeral(20001), // Bitcoin transaction kind
            content,
            &[
                Tag::Hashtag("bitcoin".to_string()),
                Tag::Hashtag("transaction".to_string()),
                Tag::Generic(
                    nostr::TagKind::Custom("block".to_string()),
                    vec![block_hash.to_string()]
                ),
            ]
        )
        .to_event(&self.keys)?;
        
        self.send_event(event).await
    }
    
    pub async fn send_event(&self, event: Event) -> Result<()> {
        let message = serde_json::to_string(&serde_json::json!(["EVENT", event]))?;
        info!("Sending nostr event: {}", event.id);
        
        let mut ws = self.ws_stream.lock().await;
        ws.send(Message::Text(message)).await?;
        
        // Try to read response (non-blocking)
        if let Some(msg) = ws.next().await {
            match msg? {
                Message::Text(text) => {
                    info!("Nostr relay response: {}", text);
                }
                Message::Binary(_) => {
                    warn!("Received binary message from nostr relay");
                }
                Message::Close(_) => {
                    warn!("Nostr relay closed connection");
                }
                _ => {}
            }
        }
        
        Ok(())
    }
}