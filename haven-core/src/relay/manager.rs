//! Relay manager for Nostr event publishing and subscription.
//!
//! This module provides a relay manager that handles all communication
//! with Nostr relays through Tor for privacy protection. All connections
//! are routed through the embedded Tor client to prevent IP leakage.
//!
//! # Security Model
//!
//! - **Mandatory Tor**: All relay connections go through embedded Tor
//! - **No Fallback**: If Tor fails, connections fail (fail-closed)
//! - **WSS Only**: Plaintext ws:// connections are rejected
//! - **Circuit Isolation**: Different operation types use separate circuits

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use nostr::{Event, Filter, RelayUrl};
use nostr_sdk::client::options::{ClientOptions, Connection, ConnectionTarget};
use nostr_sdk::{Client, RelayPoolNotification};
use tokio::sync::RwLock;

use super::error::{RelayError, RelayResult};
use super::types::{CircuitPurpose, PublishResult, RelayConnectionStatus, RelayStatus, TorStatus};

/// Default timeout for relay operations.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Timeout for Tor bootstrap verification.
const BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(120);

/// Well-known relay used to verify Tor connectivity.
const BOOTSTRAP_PROBE_RELAY: &str = "wss://relay.damus.io";

/// Manager for Nostr relay connections with mandatory Tor routing.
///
/// The `RelayManager` handles all communication with Nostr relays,
/// ensuring all traffic is routed through the embedded Tor network.
/// This prevents relay operators from learning user IP addresses.
///
/// # Circuit Isolation
///
/// To prevent correlation attacks, different operation types use
/// separate Tor circuits:
///
/// - **Identity operations** (`KeyPackage` publishing): Shared circuit
/// - **Group messages**: Separate circuit per group
///
/// # Example
///
/// ```rust,ignore
/// use haven_core::relay::RelayManager;
/// use std::path::Path;
///
/// // Initialize the relay manager (bootstraps Tor)
/// let manager = RelayManager::new(Path::new("/data/tor")).await?;
///
/// // Wait for Tor to be ready
/// while !manager.is_ready().await {
///     let status = manager.tor_status().await;
///     println!("Tor bootstrap: {}%", status.progress);
///     tokio::time::sleep(Duration::from_millis(500)).await;
/// }
///
/// // Publish an event
/// let result = manager.publish_event(&event, &relays).await?;
/// ```
pub struct RelayManager {
    /// The nostr-sdk client with embedded Tor.
    client: Arc<RwLock<Option<Client>>>,

    /// Current Tor status.
    tor_status: Arc<RwLock<TorStatus>>,

    /// Data directory for Tor state.
    #[allow(dead_code)]
    data_dir: std::path::PathBuf,

    /// Per-group clients for circuit isolation.
    /// Key: `nostr_group_id` (32 bytes)
    group_clients: Arc<RwLock<HashMap<[u8; 32], Client>>>,
}

impl RelayManager {
    /// Creates a new relay manager and begins Tor bootstrap.
    ///
    /// The manager will start bootstrapping the embedded Tor client
    /// in the background. Use [`is_ready`](Self::is_ready) or
    /// [`tor_status`](Self::tor_status) to check bootstrap progress.
    ///
    /// # Arguments
    ///
    /// * `data_dir` - Directory for Tor state and cache files
    ///
    /// # Errors
    ///
    /// Returns an error if Tor initialization fails.
    pub async fn new(data_dir: &Path) -> RelayResult<Self> {
        let manager = Self {
            client: Arc::new(RwLock::new(None)),
            tor_status: Arc::new(RwLock::new(TorStatus::initializing())),
            data_dir: data_dir.to_path_buf(),
            group_clients: Arc::new(RwLock::new(HashMap::new())),
        };

        // Start Tor bootstrap in background
        manager.bootstrap_tor().await?;

        Ok(manager)
    }

    /// Bootstraps the embedded Tor client.
    ///
    /// This creates the client but does NOT mark Tor as ready. The actual
    /// Tor bootstrap happens lazily on first connection. Use [`wait_for_ready`]
    /// to verify Tor connectivity.
    async fn bootstrap_tor(&self) -> RelayResult<()> {
        // Update status to bootstrapping
        {
            let mut status = self.tor_status.write().await;
            *status = TorStatus {
                progress: 10,
                is_ready: false,
                phase: "Creating Tor client".to_string(),
            };
        }

        // Create connection with embedded Tor
        // Route ALL connections through Tor (not just .onion)
        let connection = Connection::new()
            .embedded_tor_with_path(&self.data_dir)
            .target(ConnectionTarget::All);

        let opts = ClientOptions::new().connection(connection);

        // Create client without a signer (we'll sign events externally)
        let client = Client::builder().opts(opts).build();

        // Store the client
        {
            let mut client_guard = self.client.write().await;
            *client_guard = Some(client);
        }

        // Update status - client created but not yet connected
        // Tor will bootstrap on first connect() call
        {
            let mut status = self.tor_status.write().await;
            *status = TorStatus {
                progress: 30,
                is_ready: false,
                phase: "Tor client created, awaiting connection".to_string(),
            };
        }

        Ok(())
    }

    /// Waits for Tor to be ready by attempting to connect to a relay.
    ///
    /// This method blocks until Tor has successfully bootstrapped and
    /// connected to a relay, or returns an error on timeout.
    ///
    /// # Errors
    ///
    /// Returns an error if Tor fails to bootstrap within the timeout period.
    pub async fn wait_for_ready(&self) -> RelayResult<()> {
        if self.is_ready().await {
            return Ok(());
        }

        // Update status
        {
            let mut status = self.tor_status.write().await;
            *status = TorStatus {
                progress: 50,
                is_ready: false,
                phase: "Bootstrapping Tor network".to_string(),
            };
        }

        let client = {
            let client_guard = self.client.read().await;
            client_guard.clone().ok_or(RelayError::NotInitialized)?
        };

        // Add the probe relay
        let probe_url = RelayUrl::parse(BOOTSTRAP_PROBE_RELAY)
            .map_err(|e| RelayError::InvalidUrl(format!("{BOOTSTRAP_PROBE_RELAY}: {e}")))?;

        let _ = client.add_relay(probe_url.as_str()).await;

        // Attempt to connect with timeout
        // This triggers the actual Tor bootstrap
        let connect_result = tokio::time::timeout(BOOTSTRAP_TIMEOUT, client.connect()).await;

        match connect_result {
            Ok(()) => {
                // Verify we actually connected
                let relays = client.relays().await;
                let connected = relays.values().any(nostr_sdk::Relay::is_connected);

                if connected {
                    {
                        let mut status = self.tor_status.write().await;
                        *status = TorStatus::ready();
                    }
                    Ok(())
                } else {
                    Err(RelayError::TorBootstrap(
                        "Failed to establish relay connection through Tor".to_string(),
                    ))
                }
            }
            Err(_) => Err(RelayError::TorBootstrap(
                "Tor bootstrap timed out".to_string(),
            )),
        }
    }

    /// Returns the current Tor bootstrap status.
    pub async fn tor_status(&self) -> TorStatus {
        self.tor_status.read().await.clone()
    }

    /// Returns whether Tor is fully bootstrapped and ready.
    pub async fn is_ready(&self) -> bool {
        self.tor_status.read().await.is_ready
    }

    /// Publishes an event to the specified relays.
    ///
    /// The event will be published through Tor to all specified relays.
    /// Returns a [`PublishResult`] indicating which relays accepted or
    /// rejected the event.
    ///
    /// # Arguments
    ///
    /// * `event` - The signed Nostr event to publish
    /// * `relays` - List of relay URLs (must be wss://)
    /// * `purpose` - Circuit purpose for isolation
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - Tor is not ready
    /// - All relays reject the event
    /// - Connection fails
    pub async fn publish_event(
        &self,
        event: &Event,
        relays: &[String],
        purpose: CircuitPurpose,
    ) -> RelayResult<PublishResult> {
        if !self.is_ready().await {
            return Err(RelayError::NotInitialized);
        }

        // Validate relay URLs (must be wss://)
        let relay_urls = Self::validate_relay_urls(relays)?;

        // Get the appropriate client based on purpose
        let client = self.get_client_for_purpose(&purpose).await?;

        // Add relays to the client
        for url in &relay_urls {
            // Ignore errors when adding relays - they may already be added
            let _: Result<bool, _> = client.add_relay(url.as_str()).await;
        }

        // Connect to relays
        client.connect().await;

        // Publish the event with timeout
        let event_id = event.id;
        let send_result = tokio::time::timeout(DEFAULT_TIMEOUT, client.send_event(event))
            .await
            .map_err(|_| RelayError::Timeout("Event publish timed out".to_string()))?
            .map_err(|e| RelayError::Publish(e.to_string()))?;

        // Build the result from Output<EventId>
        let mut accepted_by = Vec::new();
        let mut rejected_by = Vec::new();

        // success is a HashSet<RelayUrl>
        for url in &send_result.success {
            accepted_by.push(url.to_string());
        }

        // failed is a HashMap<RelayUrl, String>
        for (url, error) in &send_result.failed {
            rejected_by.push((url.to_string(), error.clone()));
        }

        let result = PublishResult {
            event_id,
            accepted_by,
            rejected_by,
            failed: Vec::new(),
        };

        if result.is_success() {
            Ok(result)
        } else {
            Err(RelayError::AllRelaysFailed)
        }
    }

    /// Subscribes to events matching the given filters.
    ///
    /// Returns a receiver that will yield events as they arrive.
    ///
    /// # Arguments
    ///
    /// * `filters` - Nostr filters for the subscription
    /// * `relays` - List of relay URLs to subscribe to
    /// * `purpose` - Circuit purpose for isolation
    ///
    /// # Errors
    ///
    /// Returns an error if Tor is not ready or subscription fails.
    pub async fn subscribe(
        &self,
        filters: Vec<Filter>,
        relays: &[String],
        purpose: CircuitPurpose,
    ) -> RelayResult<tokio::sync::mpsc::Receiver<Event>> {
        if !self.is_ready().await {
            return Err(RelayError::NotInitialized);
        }

        let relay_urls = Self::validate_relay_urls(relays)?;
        let client = self.get_client_for_purpose(&purpose).await?;

        // Add relays
        for url in &relay_urls {
            let _: Result<bool, _> = client.add_relay(url.as_str()).await;
        }

        // Connect
        client.connect().await;

        // Create a channel for events
        let (tx, rx) = tokio::sync::mpsc::channel(100);

        // Subscribe to each filter individually
        // nostr-sdk 0.43 takes a single Filter, not Vec<Filter>
        for filter in filters {
            let subscription_output = client
                .subscribe(filter, None)
                .await
                .map_err(|e| RelayError::Subscription(e.to_string()))?;

            // Spawn event handling task for this subscription
            let client_clone = client.clone();
            let tx_clone = tx.clone();
            let subscription_id = subscription_output.val;

            tokio::spawn(async move {
                // Handle notifications from the client
                let _ = client_clone
                    .handle_notifications(|notification| async {
                        if let RelayPoolNotification::Event { event, .. } = notification {
                            if tx_clone.send((*event).clone()).await.is_err() {
                                // Receiver dropped, stop handling
                                return Ok(true);
                            }
                        }
                        Ok(false)
                    })
                    .await;

                // Clean up subscription when done
                client_clone.unsubscribe(&subscription_id).await;
            });
        }

        Ok(rx)
    }

    /// Gets the relay connection status for all connected relays.
    pub async fn get_relay_status(&self) -> Vec<RelayConnectionStatus> {
        let client = {
            let client_guard = self.client.read().await;
            match client_guard.as_ref() {
                Some(c) => c.clone(),
                None => return Vec::new(),
            }
        };

        let relays = client.relays().await;
        let mut statuses = Vec::new();

        for (url, relay) in relays {
            let status = if relay.is_connected() {
                RelayStatus::Connected
            } else {
                RelayStatus::Disconnected
            };

            statuses.push(RelayConnectionStatus {
                url: url.to_string(),
                status,
                last_seen: None, // TODO: Track last seen time
            });
        }

        statuses
    }

    /// Gets or creates a client for the given circuit purpose.
    async fn get_client_for_purpose(&self, purpose: &CircuitPurpose) -> RelayResult<Client> {
        match purpose {
            CircuitPurpose::Identity => {
                // Use the main client for identity operations
                let client_guard = self.client.read().await;
                client_guard.clone().ok_or(RelayError::NotInitialized)
            }
            CircuitPurpose::GroupMessage { nostr_group_id } => {
                // Check if we already have a client for this group
                {
                    let group_clients = self.group_clients.read().await;
                    if let Some(client) = group_clients.get(nostr_group_id) {
                        return Ok(client.clone());
                    }
                }

                // Create a new client with embedded Tor for this group
                // Each group gets its own Tor data directory to ensure circuit isolation
                // This prevents relay-level correlation of group membership
                let group_id_hex = hex::encode(nostr_group_id);
                let group_tor_dir = self.data_dir.join("group_circuits").join(&group_id_hex);

                // Create the directory if it doesn't exist
                std::fs::create_dir_all(&group_tor_dir).map_err(|e| {
                    RelayError::Initialization(format!("Failed to create group Tor directory: {e}"))
                })?;

                let connection = Connection::new()
                    .embedded_tor_with_path(&group_tor_dir)
                    .target(ConnectionTarget::All);

                let opts = ClientOptions::new().connection(connection);
                let client = Client::builder().opts(opts).build();

                // Store and return the client
                let mut group_clients = self.group_clients.write().await;
                group_clients.insert(*nostr_group_id, client.clone());
                drop(group_clients);
                Ok(client)
            }
        }
    }

    /// Validates relay URLs and ensures they use wss://.
    fn validate_relay_urls(relays: &[String]) -> RelayResult<Vec<RelayUrl>> {
        let mut urls = Vec::with_capacity(relays.len());

        for relay in relays {
            // Reject plaintext ws:// URLs
            if relay.starts_with("ws://") {
                return Err(RelayError::InvalidUrl(format!(
                    "Plaintext ws:// not allowed for security: {relay}"
                )));
            }

            let url = RelayUrl::parse(relay)
                .map_err(|e| RelayError::InvalidUrl(format!("{relay}: {e}")))?;

            urls.push(url);
        }

        Ok(urls)
    }

    /// Disconnects from all relays and shuts down Tor.
    pub async fn shutdown(&self) {
        // Disconnect main client
        let main_client = self.client.write().await.take();
        if let Some(client) = main_client {
            client.disconnect().await;
        }

        // Disconnect group clients
        let clients_to_disconnect: Vec<Client> = {
            let mut group_clients = self.group_clients.write().await;
            group_clients.drain().map(|(_, c)| c).collect()
        };

        for client in clients_to_disconnect {
            client.disconnect().await;
        }

        // Update status
        let mut status = self.tor_status.write().await;
        *status = TorStatus::initializing();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_relay_urls_rejects_plaintext() {
        let relays = vec!["ws://insecure.relay.com".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_err());
        if let Err(RelayError::InvalidUrl(msg)) = result {
            assert!(msg.contains("Plaintext ws://"));
        }
    }

    #[test]
    fn validate_relay_urls_accepts_wss() {
        let relays = vec!["wss://relay.damus.io".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn tor_status_starts_initializing() {
        let manager = RelayManager {
            client: Arc::new(RwLock::new(None)),
            tor_status: Arc::new(RwLock::new(TorStatus::initializing())),
            data_dir: std::path::PathBuf::new(),
            group_clients: Arc::new(RwLock::new(HashMap::new())),
        };

        let status = manager.tor_status().await;
        assert!(!status.is_ready);
        assert_eq!(status.progress, 0);
    }

    #[tokio::test]
    async fn is_ready_returns_false_initially() {
        let manager = RelayManager {
            client: Arc::new(RwLock::new(None)),
            tor_status: Arc::new(RwLock::new(TorStatus::initializing())),
            data_dir: std::path::PathBuf::new(),
            group_clients: Arc::new(RwLock::new(HashMap::new())),
        };

        assert!(!manager.is_ready().await);
    }

    #[tokio::test]
    async fn wait_for_ready_fails_without_client() {
        let manager = RelayManager {
            client: Arc::new(RwLock::new(None)),
            tor_status: Arc::new(RwLock::new(TorStatus::initializing())),
            data_dir: std::path::PathBuf::new(),
            group_clients: Arc::new(RwLock::new(HashMap::new())),
        };

        let result = manager.wait_for_ready().await;
        assert!(matches!(result, Err(RelayError::NotInitialized)));
    }

    #[test]
    fn validate_relay_urls_rejects_multiple_plaintext() {
        let relays = vec![
            "wss://good.relay.com".to_string(),
            "ws://bad.relay.com".to_string(),
        ];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_err());
    }

    #[test]
    fn validate_relay_urls_accepts_multiple_wss() {
        let relays = vec![
            "wss://relay.damus.io".to_string(),
            "wss://relay.nostr.wine".to_string(),
            "wss://nos.lol".to_string(),
        ];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 3);
    }

    #[test]
    fn validate_relay_urls_empty_list() {
        let relays: Vec<String> = vec![];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn validate_relay_urls_invalid_url_format() {
        let relays = vec!["not-a-url".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);

        assert!(matches!(result, Err(RelayError::InvalidUrl(_))));
    }
}
