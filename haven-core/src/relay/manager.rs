//! Relay manager for Nostr event publishing and subscription.
//!
//! This module provides a relay manager that handles all communication
//! with Nostr relays via direct WSS connections.
//!
//! # Security Model
//!
//! - **WSS Only**: Plaintext ws:// connections are rejected

use std::time::Duration;

use nostr::{Event, Filter, Kind, PublicKey, RelayUrl};
use nostr_sdk::{Client, RelayPoolNotification};

use super::error::{RelayError, RelayResult};
use super::types::{PublishResult, RelayConnectionStatus, RelayStatus};

/// Default timeout for relay operations.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Manager for Nostr relay connections.
///
/// The `RelayManager` handles all communication with Nostr relays
/// using direct WSS connections via nostr-sdk.
///
/// # Example
///
/// ```rust,ignore
/// use haven_core::relay::RelayManager;
///
/// let manager = RelayManager::new();
///
/// // Publish an event
/// let result = manager.publish_event(&event, &relays).await?;
/// ```
pub struct RelayManager {
    /// The nostr-sdk client.
    client: Client,
}

impl RelayManager {
    /// Creates a new relay manager.
    #[must_use]
    pub fn new() -> Self {
        Self {
            client: Client::builder().build(),
        }
    }

    /// Publishes an event to the specified relays.
    ///
    /// The event will be published to all specified relays.
    /// Returns a [`PublishResult`] indicating which relays accepted or
    /// rejected the event.
    ///
    /// # Arguments
    ///
    /// * `event` - The signed Nostr event to publish
    /// * `relays` - List of relay URLs (must be wss://)
    ///
    /// # Errors
    ///
    /// Returns an error if all relays reject the event or connection fails.
    pub async fn publish_event(
        &self,
        event: &Event,
        relays: &[String],
    ) -> RelayResult<PublishResult> {
        // Validate relay URLs (must be wss://)
        let relay_urls = Self::validate_relay_urls(relays)?;

        // Add relays to the client
        for url in &relay_urls {
            // Ignore errors when adding relays - they may already be added
            let _: Result<bool, _> = self.client.add_relay(url.as_str()).await;
        }

        // Connect to relays
        self.client.connect().await;

        // Publish the event with timeout
        let event_id = event.id;
        let send_result = tokio::time::timeout(DEFAULT_TIMEOUT, self.client.send_event(event))
            .await
            .map_err(|_| RelayError::Timeout("Event publish timed out".to_string()))?
            .map_err(|e| RelayError::Publish(e.to_string()))?;

        // Build the result from Output<EventId>
        let mut accepted_by = Vec::new();
        let mut rejected_by = Vec::new();

        for url in &send_result.success {
            accepted_by.push(url.to_string());
        }

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
    ///
    /// # Errors
    ///
    /// Returns an error if subscription fails.
    pub async fn subscribe(
        &self,
        filters: Vec<Filter>,
        relays: &[String],
    ) -> RelayResult<tokio::sync::mpsc::Receiver<Event>> {
        let relay_urls = Self::validate_relay_urls(relays)?;

        // Add relays
        for url in &relay_urls {
            let _: Result<bool, _> = self.client.add_relay(url.as_str()).await;
        }

        // Connect
        self.client.connect().await;

        // Create a channel for events
        let (tx, rx) = tokio::sync::mpsc::channel(100);

        // Subscribe to each filter individually
        for filter in filters {
            let subscription_output = self
                .client
                .subscribe(filter, None)
                .await
                .map_err(|e| RelayError::Subscription(e.to_string()))?;

            // Spawn event handling task for this subscription
            let client_clone = self.client.clone();
            let tx_clone = tx.clone();
            let subscription_id = subscription_output.val;

            tokio::spawn(async move {
                let _ = client_clone
                    .handle_notifications(|notification| async {
                        if let RelayPoolNotification::Event { event, .. } = notification {
                            if tx_clone.send((*event).clone()).await.is_err() {
                                return Ok(true);
                            }
                        }
                        Ok(false)
                    })
                    .await;

                client_clone.unsubscribe(&subscription_id).await;
            });
        }

        Ok(rx)
    }

    /// Gets the relay connection status for all connected relays.
    pub async fn get_relay_status(&self) -> Vec<RelayConnectionStatus> {
        let relays = self.client.relays().await;
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
                last_seen: None,
            });
        }

        statuses
    }

    /// Fetches events matching the given filter from relays.
    ///
    /// Performs a one-shot fetch of events matching the filter,
    /// waiting for responses from all relays or until timeout.
    ///
    /// # Arguments
    ///
    /// * `filter` - Nostr filter for the query
    /// * `relays` - List of relay URLs to query
    /// * `timeout` - Optional timeout (defaults to 30 seconds)
    ///
    /// # Errors
    ///
    /// Returns an error if fetching fails.
    pub async fn fetch_events(
        &self,
        filter: Filter,
        relays: &[String],
        timeout: Option<Duration>,
    ) -> RelayResult<Vec<Event>> {
        let relay_urls = Self::validate_relay_urls(relays)?;

        // Add relays to the client
        for url in &relay_urls {
            let _: Result<bool, _> = self.client.add_relay(url.as_str()).await;
        }

        // Connect to relays
        self.client.connect().await;

        // Fetch events with timeout
        let timeout_duration = timeout.unwrap_or(DEFAULT_TIMEOUT);

        let fetch_result = self
            .client
            .fetch_events(filter, timeout_duration)
            .await
            .map_err(|e| RelayError::Fetch(e.to_string()))?;

        Ok(fetch_result.into_iter().collect())
    }

    /// Fetches a user's `KeyPackage` relay list (kind 10051).
    ///
    /// Queries default relays for the user's `KeyPackage` inbox relays.
    /// Returns the list of relay URLs where the user publishes `KeyPackages`.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        let pk = PublicKey::parse(pubkey)
            .map_err(|e| RelayError::InvalidUrl(format!("Invalid pubkey: {e}")))?;

        // Kind 10051 = MLS KeyPackage relay list
        let filter = Filter::new().kind(Kind::Custom(10051)).author(pk).limit(1);

        // Query default relays
        let default_relays = vec![
            "wss://relay.damus.io".to_string(),
            "wss://nos.lol".to_string(),
            "wss://relay.nostr.band".to_string(),
        ];

        let events = self.fetch_events(filter, &default_relays, None).await?;

        if events.is_empty() {
            return Ok(Vec::new());
        }

        // Extract relay URLs from the event's tags
        let event = &events[0];
        let relays: Vec<String> = event
            .tags
            .iter()
            .filter_map(|tag| {
                let values = tag.as_slice();
                if values.len() >= 2 && values[0] == "relay" {
                    Some(values[1].clone())
                } else {
                    None
                }
            })
            .collect();

        Ok(relays)
    }

    /// Fetches a user's `KeyPackage` (kind 443).
    ///
    /// First fetches the user's `KeyPackage` relay list (kind 10051),
    /// then fetches the most recent `KeyPackage` from those relays.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    ///
    /// # Returns
    ///
    /// The most recent valid `KeyPackage` event, or `None` if not found.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage(&self, pubkey: &str) -> RelayResult<Option<Event>> {
        let pk = PublicKey::parse(pubkey)
            .map_err(|e| RelayError::InvalidUrl(format!("Invalid pubkey: {e}")))?;

        // First, get the user's KeyPackage relay list
        let kp_relays = self.fetch_keypackage_relays(pubkey).await?;

        // If no relay list, try default relays
        let relays = if kp_relays.is_empty() {
            vec![
                "wss://relay.damus.io".to_string(),
                "wss://nos.lol".to_string(),
                "wss://relay.nostr.band".to_string(),
            ]
        } else {
            kp_relays
        };

        // Kind 443 = MLS KeyPackage
        let filter = Filter::new().kind(Kind::Custom(443)).author(pk).limit(5);

        let events = self.fetch_events(filter, &relays, None).await?;

        if events.is_empty() {
            return Ok(None);
        }

        let newest = events.into_iter().max_by_key(|e| e.created_at);

        Ok(newest)
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

    /// Disconnects from all relays.
    pub async fn shutdown(&self) {
        self.client.disconnect().await;
    }
}

impl Default for RelayManager {
    fn default() -> Self {
        Self::new()
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

    #[test]
    fn new_creates_manager() {
        let manager = RelayManager::new();
        // Just verify it can be created without panicking
        drop(manager);
    }

    #[test]
    fn default_creates_manager() {
        let manager = RelayManager::default();
        drop(manager);
    }
}
