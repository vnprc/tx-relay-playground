use anyhow::Result;
use serde_json::{json, Value};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ValidationError {
    #[error("Empty transaction")]
    EmptyTransaction,
    #[error("Invalid hex format")]
    InvalidHex,
    #[error("Invalid transaction size: {0} bytes")]
    InvalidSize(usize),
    #[error("Bitcoin Core rejection: {0}")]
    BitcoinCoreRejection(String),
    #[error("RPC error: {0}")]
    RpcError(#[from] reqwest::Error),
    #[error("JSON parsing error: {0}")]
    JsonError(#[from] serde_json::Error),
}

#[derive(Debug, Clone)]
pub struct ValidationConfig {
    pub enable_validation: bool,
    pub enable_precheck: bool,
    pub validation_timeout_ms: u64,
}

impl Default for ValidationConfig {
    fn default() -> Self {
        Self {
            enable_validation: true,
            enable_precheck: true,
            validation_timeout_ms: 5000,
        }
    }
}

pub struct TransactionValidator {
    config: ValidationConfig,
    bitcoin_client: reqwest::Client,
    bitcoin_rpc_url: String,
}

impl TransactionValidator {
    pub fn new(config: ValidationConfig, bitcoin_port: u16) -> Self {
        let bitcoin_rpc_url = format!("http://127.0.0.1:{}", bitcoin_port);
        
        Self {
            config,
            bitcoin_client: reqwest::Client::new(),
            bitcoin_rpc_url,
        }
    }
    
    pub async fn validate(&self, tx_hex: &str) -> Result<(), ValidationError> {
        if !self.config.enable_validation {
            return Ok(());
        }
        
        // Phase 2: Quick pre-checks
        if self.config.enable_precheck {
            self.quick_validation_checks(tx_hex)?;
        }
        
        // Phase 1: Use Bitcoin Core validation
        self.validate_with_bitcoin_core(tx_hex).await
    }
    
    fn quick_validation_checks(&self, tx_hex: &str) -> Result<(), ValidationError> {
        if tx_hex.is_empty() {
            return Err(ValidationError::EmptyTransaction);
        }
        
        if !tx_hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(ValidationError::InvalidHex);
        }
        
        let byte_len = tx_hex.len() / 2;
        if byte_len < 60 || byte_len > 400_000 {
            return Err(ValidationError::InvalidSize(byte_len));
        }
        
        Ok(())
    }
    
    async fn validate_with_bitcoin_core(&self, tx_hex: &str) -> Result<(), ValidationError> {
        let request = json!({
            "jsonrpc": "2.0",
            "method": "testmempoolaccept",
            "params": [[tx_hex]],
            "id": "validation"
        });
        
        let response: Value = self.bitcoin_client
            .post(&self.bitcoin_rpc_url)
            .basic_auth("user", Some("password"))
            .timeout(std::time::Duration::from_millis(self.config.validation_timeout_ms))
            .json(&request)
            .send()
            .await?
            .json()
            .await?;
        
        // Check for RPC error
        if let Some(error) = response.get("error") {
            if !error.is_null() {
                return Err(ValidationError::BitcoinCoreRejection(format!("RPC error: {}", error)));
            }
        }
        
        // Get the result array (testmempoolaccept returns array of results)
        let results = response["result"]
            .as_array()
            .ok_or_else(|| ValidationError::BitcoinCoreRejection("Invalid response format".to_string()))?;
        
        if results.is_empty() {
            return Err(ValidationError::BitcoinCoreRejection("Empty response".to_string()));
        }
        
        let result = &results[0];
        
        if result["allowed"].as_bool() == Some(true) {
            Ok(())
        } else {
            let reason = result["reject-reason"]
                .as_str()
                .unwrap_or("unknown reason");
            Err(ValidationError::BitcoinCoreRejection(reason.to_string()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_validation_disabled() {
        let mut config = ValidationConfig::default();
        config.enable_validation = false;
        
        let validator = TransactionValidator::new(config, 18332);
        
        // Should pass validation even with invalid hex when validation is disabled
        let result = validator.validate("invalid_hex").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_precheck_disabled() {
        let mut config = ValidationConfig::default();
        config.enable_precheck = false;
        
        let validator = TransactionValidator::new(config, 18332);
        
        // Should skip precheck and go straight to Bitcoin Core validation
        // This will fail at Bitcoin Core level, not precheck level
        let result = validator.validate("invalid_hex").await;
        assert!(result.is_err());
        
        // The error should not be a precheck error (like InvalidHex)
        if let Err(e) = result {
            assert!(!matches!(e, ValidationError::InvalidHex));
        }
    }

    #[test]
    fn test_quick_validation_empty_transaction() {
        let config = ValidationConfig::default();
        let validator = TransactionValidator::new(config, 18332);
        
        let result = validator.quick_validation_checks("");
        assert!(matches!(result, Err(ValidationError::EmptyTransaction)));
    }

    #[test]
    fn test_quick_validation_invalid_hex() {
        let config = ValidationConfig::default();
        let validator = TransactionValidator::new(config, 18332);
        
        // Non-hex characters
        let result = validator.quick_validation_checks("hello world");
        assert!(matches!(result, Err(ValidationError::InvalidHex)));
        
        // Mixed case with invalid characters
        let result = validator.quick_validation_checks("abcdefg");  // 'g' is not hex
        assert!(matches!(result, Err(ValidationError::InvalidHex)));
    }

    #[test]
    fn test_quick_validation_invalid_size() {
        let config = ValidationConfig::default();
        let validator = TransactionValidator::new(config, 18332);
        
        // Too small (less than 60 bytes = 120 hex chars)
        let small_tx = "a".repeat(118); // 59 bytes
        let result = validator.quick_validation_checks(&small_tx);
        assert!(matches!(result, Err(ValidationError::InvalidSize(59))));
        
        // Too large (more than 400KB = 800,000 hex chars)
        let large_tx = "a".repeat(800_002); // 400,001 bytes
        let result = validator.quick_validation_checks(&large_tx);
        assert!(matches!(result, Err(ValidationError::InvalidSize(400_001))));
    }

    #[test]
    fn test_quick_validation_valid_hex() {
        let config = ValidationConfig::default();
        let validator = TransactionValidator::new(config, 18332);
        
        // Valid hex string of appropriate length (60 bytes = 120 hex chars)
        let valid_hex = "a".repeat(120);
        let result = validator.quick_validation_checks(&valid_hex);
        assert!(result.is_ok());
        
        // Test with actual hex characters
        let mixed_case_hex = "AbCdEf0123456789".repeat(8); // 128 hex chars = 64 bytes
        let result = validator.quick_validation_checks(&mixed_case_hex);
        assert!(result.is_ok());
    }

    #[test] 
    fn test_validation_config_default() {
        let config = ValidationConfig::default();
        
        assert_eq!(config.enable_validation, true);
        assert_eq!(config.enable_precheck, true);
        assert_eq!(config.validation_timeout_ms, 5000);
    }

    #[test]
    fn test_validation_error_display() {
        let errors = vec![
            ValidationError::EmptyTransaction,
            ValidationError::InvalidHex,
            ValidationError::InvalidSize(100),
            ValidationError::BitcoinCoreRejection("test reason".to_string()),
        ];
        
        for error in errors {
            let error_string = format!("{}", error);
            assert!(!error_string.is_empty());
        }
    }

    // Integration test that requires a running Bitcoin node
    #[tokio::test]
    #[ignore] // Use `cargo test -- --ignored` to run this test
    async fn test_bitcoin_core_integration_valid_transaction() {
        let config = ValidationConfig::default();
        let validator = TransactionValidator::new(config, 18332);
        
        // This is a valid transaction hex from regtest (you'll need to replace with actual valid tx)
        // For now, this test is ignored and would need a real transaction hex
        let valid_tx_hex = "0200000001..."; // Replace with real transaction
        
        let result = validator.validate_with_bitcoin_core(valid_tx_hex).await;
        // This test requires actual Bitcoin Core running and a valid transaction
        // assert!(result.is_ok());
    }

    #[tokio::test]
    #[ignore] // Use `cargo test -- --ignored` to run this test  
    async fn test_bitcoin_core_integration_invalid_transaction() {
        let config = ValidationConfig::default();
        let validator = TransactionValidator::new(config, 18332);
        
        // Invalid transaction hex (too short but valid hex)
        let invalid_tx_hex = "a".repeat(120);
        
        let result = validator.validate_with_bitcoin_core(&invalid_tx_hex).await;
        assert!(result.is_err());
        
        if let Err(ValidationError::BitcoinCoreRejection(reason)) = result {
            assert!(!reason.is_empty());
        } else {
            panic!("Expected BitcoinCoreRejection error");
        }
    }
}