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
use super::types::{PublishResult, RelayConnectionStatus, RelayEventCheck, RelayStatus};
use crate::circle::types::DEFAULT_RELAYS;

/// Default timeout for relay operations.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

/// Timeout for waiting for relay WebSocket connections to establish.
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

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

    /// Adds relays and connects only to the specified ones.
    ///
    /// Uses `try_connect_relay` per URL to avoid reconnecting to every
    /// previously-added relay in the pool, which would leak connection
    /// metadata to unrelated relay operators.
    async fn add_relays_and_connect(&self, relay_urls: &[RelayUrl]) {
        // Register relays sequentially (cheap metadata operation)
        for url in relay_urls {
            let added = self.client.add_relay(url.as_str()).await;
            log::debug!("[RelayManager] add_relay({url}): {added:?}");
        }

        // Connect to all relays in parallel (each has CONNECTION_TIMEOUT)
        let connect_futures = relay_urls.iter().map(|url| async move {
            match self
                .client
                .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                .await
            {
                Ok(()) => {
                    log::debug!("[RelayManager] connected to {url}");
                }
                Err(e) => {
                    log::debug!("[RelayManager] failed to connect to {url}: {e}");
                }
            }
        });

        futures::future::join_all(connect_futures).await;
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

        // Add relays, connect, and wait for WebSocket handshakes
        self.add_relays_and_connect(&relay_urls).await;

        // Publish the event with timeout
        let event_id = event.id;
        log::debug!(
            "[RelayManager] publish_event: sending kind {} event {} to {} relays...",
            event.kind.as_u16(),
            event_id,
            relay_urls.len()
        );
        let send_result = tokio::time::timeout(
            DEFAULT_TIMEOUT,
            self.client
                .send_event_to(relay_urls.iter().map(RelayUrl::as_str), event),
        )
        .await
        .map_err(|_| {
            log::warn!(
                "[RelayManager] publish_event: timed out after {}s",
                DEFAULT_TIMEOUT.as_secs()
            );
            RelayError::Timeout("Event publish timed out".to_string())
        })?
        .map_err(|e| {
            log::debug!("[RelayManager] publish_event: send_event error: {e}");
            RelayError::Publish(e.to_string())
        })?;
        log::debug!(
            "[RelayManager] publish_event: success={}, failed={}",
            send_result.success.len(),
            send_result.failed.len()
        );
        for (url, err) in &send_result.failed {
            log::debug!("[RelayManager] publish_event: relay {url} failed: {err}");
        }

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

    /// Publishes an event in the background without waiting for relay acknowledgment.
    ///
    /// Spawns a `tokio::spawn` task to perform the publish. Failures are
    /// logged but not returned to the caller. Suitable for location updates
    /// and key package re-publishes where the periodic timer ensures retries.
    ///
    /// # Errors
    ///
    /// Returns an error only if relay URL validation fails (before spawning).
    pub fn publish_event_background(&self, event: Event, relays: &[String]) -> RelayResult<()> {
        let relay_urls = Self::validate_relay_urls(relays)?;
        let client = self.client.clone();

        tokio::spawn(async move {
            // Register and connect
            for url in &relay_urls {
                let _ = client.add_relay(url.as_str()).await;
            }
            let connect_futures = relay_urls.iter().map(|url| async {
                let _ = client
                    .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                    .await;
            });
            futures::future::join_all(connect_futures).await;

            // Publish with timeout
            match tokio::time::timeout(
                DEFAULT_TIMEOUT,
                client.send_event_to(relay_urls.iter().map(RelayUrl::as_str), &event),
            )
            .await
            {
                Ok(Ok(result)) => {
                    log::debug!(
                        "[RelayManager] background publish: {} accepted, {} failed",
                        result.success.len(),
                        result.failed.len()
                    );
                }
                Ok(Err(e)) => {
                    log::debug!("[RelayManager] background publish error: {e}");
                }
                Err(_) => {
                    log::debug!("[RelayManager] background publish timed out");
                }
            }
        });

        Ok(())
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

        // Add relays, connect, and wait for WebSocket handshakes
        self.add_relays_and_connect(&relay_urls).await;

        // Create a channel for events
        let (tx, rx) = tokio::sync::mpsc::channel(100);

        // Subscribe to each filter individually
        for filter in filters {
            let subscription_output = self
                .client
                .subscribe_to(relay_urls.iter().map(RelayUrl::as_str), filter, None)
                .await
                .map_err(|e| {
                    log::debug!("[RelayManager] subscribe_to error: {e}");
                    RelayError::Subscription(e.to_string())
                })?;

            // Spawn event handling task for this subscription
            let client_clone = self.client.clone();
            let tx_clone = tx.clone();
            let subscription_id = subscription_output.val;

            tokio::spawn(async move {
                let _ = client_clone
                    .handle_notifications(|notification| async {
                        if let RelayPoolNotification::Event {
                            subscription_id: sid,
                            event,
                            ..
                        } = notification
                        {
                            if sid == subscription_id
                                && tx_clone.send((*event).clone()).await.is_err()
                            {
                                // Receiver dropped — exit to trigger unsubscribe
                                return Ok(true);
                            }
                        }
                        Ok(false)
                    })
                    .await;

                // Sends NIP-01 CLOSE to relays when receiver is dropped
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

        // Add relays, connect, and wait for WebSocket handshakes
        self.add_relays_and_connect(&relay_urls).await;

        // Fetch events with timeout
        let timeout_duration = timeout.unwrap_or(DEFAULT_TIMEOUT);

        let fetch_result = self
            .client
            .fetch_events_from(
                relay_urls.iter().map(RelayUrl::as_str),
                filter,
                timeout_duration,
            )
            .await
            .map_err(|e| {
                log::debug!("[RelayManager] fetch_events error: {e}");
                RelayError::Fetch(e.to_string())
            })?;

        Ok(fetch_result.into_iter().collect())
    }

    /// Extracts `wss://` relay URLs from `"relay"` tags.
    ///
    /// Used for kind 10050 (inbox) and kind 10051 (`KeyPackage`) events,
    /// which both use `["relay", "<url>"]` tag format.
    fn extract_relay_tag_urls(tags: &nostr::Tags) -> Vec<String> {
        tags.iter()
            .filter_map(|tag| {
                let values = tag.as_slice();
                if values.len() >= 2
                    && values[0] == "relay"
                    && values[1].starts_with("wss://")
                {
                    Some(values[1].clone())
                } else {
                    None
                }
            })
            .collect()
    }

    /// Fetches a user's relay list for the given event kind.
    ///
    /// Queries default relays for the user's replaceable relay list event
    /// and extracts `wss://` URLs from `"relay"` tags. Works for both
    /// kind 10050 (inbox) and kind 10051 (`KeyPackage`) events.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    async fn fetch_relay_list(&self, pubkey: &str, kind: Kind) -> RelayResult<Vec<String>> {
        let pk = PublicKey::parse(pubkey)
            .map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new().kind(kind).author(pk).limit(1);
        let default_relays: Vec<String> = DEFAULT_RELAYS.iter().map(|r| (*r).to_string()).collect();
        let events = self.fetch_events(filter, &default_relays, None).await?;

        if events.is_empty() {
            return Ok(Vec::new());
        }

        Ok(Self::extract_relay_tag_urls(&events[0].tags))
    }

    /// Fetches a user's inbox relay list (kind 10050).
    ///
    /// Returns the relay URLs where the user receives gift-wrapped messages
    /// (NIP-17 / NIP-59). Used as the first tier in the Welcome delivery
    /// cascade per the Marmot Protocol reference implementation.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_inbox_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        self.fetch_relay_list(pubkey, Kind::InboxRelays).await
    }

    /// Fetches a user's `KeyPackage` relay list (kind 10051).
    ///
    /// Returns the relay URLs where the user publishes MLS `KeyPackages`.
    /// Used for `KeyPackage` discovery, not for Welcome delivery.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        self.fetch_relay_list(pubkey, Kind::MlsKeyPackageRelays).await
    }

    /// Extracts read-capable relay URLs from NIP-65 "r" tags.
    ///
    /// Filters for relays the recipient reads from:
    /// - No marker (both read+write) → include
    /// - "read" → include (recipient fetches here)
    /// - "write" only → exclude (recipient doesn't read here)
    ///
    /// Also filters to `wss://` scheme only for security.
    fn extract_nip65_read_relays(tags: &nostr::Tags) -> Vec<String> {
        tags.iter()
            .filter_map(|tag| {
                let values = tag.as_slice();
                if values.len() >= 2 && values[0] == "r" {
                    // Exclude write-only relays
                    if values.len() >= 3 && values[2] == "write" {
                        return None;
                    }
                    let url = &values[1];
                    // Only accept wss:// URLs
                    if url.starts_with("wss://") {
                        Some(url.clone())
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .collect()
    }

    /// Fetches a user's NIP-65 relay list (kind 10002).
    ///
    /// Returns read-capable relay URLs from the user's general-purpose relay
    /// list. Used as the second tier in the Welcome delivery cascade when
    /// inbox relays (kind 10050) are unavailable.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_nip65_relays(&self, pubkey: &str) -> RelayResult<Vec<String>> {
        let pk = PublicKey::parse(pubkey)
            .map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new()
            .kind(Kind::RelayList)
            .author(pk)
            .limit(1);

        let default_relays: Vec<String> = DEFAULT_RELAYS.iter().map(|r| (*r).to_string()).collect();
        let events = self.fetch_events(filter, &default_relays, None).await?;

        if events.is_empty() {
            return Ok(Vec::new());
        }

        let relays = Self::extract_nip65_read_relays(&events[0].tags);

        Ok(relays)
    }

    /// Fetches a user's key package (kind 30443 or legacy kind 443).
    ///
    /// Performs a three-tier discovery cascade:
    /// 1. Kind 10051 relays (`KeyPackage` relay list) — preferred, purpose-built.
    /// 2. Kind 10002 relays (NIP-65) — general-purpose fallback.
    /// 3. `DEFAULT_RELAYS` — last resort.
    ///
    /// Each tier is tried in order; the cascade stops as soon as a `KeyPackage`
    /// is found. Empty tiers are skipped without issuing a redundant query.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    ///
    /// # Returns
    ///
    /// The most recent valid `KeyPackage` event, or `None` if no tier returned
    /// an event.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage(&self, pubkey: &str) -> RelayResult<Option<Event>> {
        // Fetch both relay lists once, then delegate to the shared cascade.
        // Either fetch may fail transiently; treat a failed list as empty so
        // the cascade can fall through to the next tier instead of aborting.
        let kp_relays = self
            .fetch_keypackage_relays(pubkey)
            .await
            .unwrap_or_default();
        let nip65_relays = self.fetch_nip65_relays(pubkey).await.unwrap_or_default();

        self.fetch_keypackage_with_cascade(pubkey, &kp_relays, &nip65_relays)
            .await
    }

    /// Runs the `KeyPackage` discovery cascade with pre-fetched relay lists.
    ///
    /// Tiers, in order: `keypackage_relays` (kind 10051) → `nip65_relays`
    /// (kind 10002) → `DEFAULT_RELAYS`. Empty tiers are skipped. The cascade
    /// stops as soon as a `KeyPackage` is found.
    ///
    /// Callers that have already resolved the user's relay lists (e.g., the
    /// FFI layer, which fetches 10051 and 10002 concurrently alongside 10050)
    /// can use this directly to avoid re-fetching.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or any tier's fetch fails.
    pub async fn fetch_keypackage_with_cascade(
        &self,
        pubkey: &str,
        keypackage_relays: &[String],
        nip65_relays: &[String],
    ) -> RelayResult<Option<Event>> {
        if !keypackage_relays.is_empty() {
            let result = self
                .fetch_keypackage_from_relays(pubkey, keypackage_relays)
                .await?;
            if result.is_some() {
                return Ok(result);
            }
        }

        if !nip65_relays.is_empty() {
            let result = self
                .fetch_keypackage_from_relays(pubkey, nip65_relays)
                .await?;
            if result.is_some() {
                return Ok(result);
            }
        }

        // Final fallback: fetch_keypackage_from_relays uses DEFAULT_RELAYS
        // internally when given an empty slice.
        self.fetch_keypackage_from_relays(pubkey, &[]).await
    }

    /// Fetches a user's key package (kind 30443 or legacy kind 443) from the
    /// given relay list.
    ///
    /// Queries for addressable kind 30443 first, falling back to legacy kind
    /// 443 for backwards compatibility. Uses the provided relay list directly,
    /// falling back to default relays if the list is empty.
    ///
    /// # Arguments
    ///
    /// * `pubkey` - The user's public key (hex or npub)
    /// * `keypackage_relays` - Pre-fetched relay list (kind 10051 result)
    ///
    /// # Returns
    ///
    /// The most recent valid key package event, or `None` if not found.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    pub async fn fetch_keypackage_from_relays(
        &self,
        pubkey: &str,
        keypackage_relays: &[String],
    ) -> RelayResult<Option<Event>> {
        let pk = PublicKey::parse(pubkey)
            .map_err(|_| RelayError::InvalidPubkey)?;

        // If no relay list, try default relays
        let default_relays: Vec<String>;
        let relays = if keypackage_relays.is_empty() {
            default_relays = DEFAULT_RELAYS.iter().map(|r| (*r).to_string()).collect();
            &default_relays
        } else {
            keypackage_relays
        };

        // Prefer addressable kind 30443 key packages, fall back to legacy kind 443.
        let filter_30443 = Filter::new().kind(Kind::Custom(30443)).author(pk).limit(5);
        let events = self.fetch_events(filter_30443, relays, None).await?;

        if !events.is_empty() {
            return Ok(events.into_iter().max_by_key(|e| e.created_at));
        }

        // Fallback: legacy kind 443
        let filter_443 = Filter::new().kind(Kind::MlsKeyPackage).author(pk).limit(5);
        let events = self.fetch_events(filter_443, relays, None).await?;

        Ok(events.into_iter().max_by_key(|e| e.created_at))
    }

    /// Checks whether events matching a filter exist on a specific relay.
    ///
    /// Queries a single relay for events matching the given filter and returns
    /// a summary of what was found.
    ///
    /// # Errors
    ///
    /// Returns an error if the relay URL is invalid or the fetch fails.
    pub async fn check_event_on_relay(
        &self,
        relay_url: &str,
        filter: Filter,
    ) -> RelayResult<RelayEventCheck> {
        let relay_urls = Self::validate_relay_urls(&[relay_url.to_string()])?;

        // Add relay, connect, and wait for WebSocket handshake
        self.add_relays_and_connect(&relay_urls).await;

        // Fetch events from this specific relay
        let events = self
            .client
            .fetch_events_from(
                relay_urls.iter().map(nostr::RelayUrl::as_str),
                filter,
                DEFAULT_TIMEOUT,
            )
            .await
            .map_err(|e| {
                log::debug!("[RelayManager] check_event_on_relay error: {e}");
                RelayError::Fetch(e.to_string())
            })?;

        let event_count = events.len();
        let newest_timestamp = events
            .iter()
            .map(|e| e.created_at.as_secs().cast_signed())
            .max();

        Ok(RelayEventCheck {
            relay_url: relay_url.to_string(),
            found: event_count > 0,
            event_count,
            newest_timestamp,
        })
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

    #[tokio::test]
    async fn check_event_on_relay_rejects_plaintext() {
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::Custom(443)).limit(1);
        let result = manager
            .check_event_on_relay("ws://insecure.relay.com", filter)
            .await;
        assert!(result.is_err());
        if let Err(RelayError::InvalidUrl(msg)) = result {
            assert!(msg.contains("Plaintext ws://"));
        }
    }

    #[tokio::test]
    async fn check_event_on_relay_rejects_invalid_url() {
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::Custom(443)).limit(1);
        let result = manager.check_event_on_relay("not-a-url", filter).await;
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

    // ------------------------------------------------------------------
    // NIP-65 relay tag parsing tests
    // ------------------------------------------------------------------

    /// Helper to build a `Tags` from a vec of parsed tags.
    fn make_tags(tag_data: Vec<Vec<&str>>) -> nostr::Tags {
        let tags: Vec<nostr::Tag> = tag_data
            .into_iter()
            .map(|t| nostr::Tag::parse(t).expect("should parse tag"))
            .collect();
        nostr::Tags::from_list(tags)
    }

    #[test]
    fn nip65_includes_unmarked_relay() {
        let tags = make_tags(vec![vec!["r", "wss://relay.example.com"]]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://relay.example.com"]);
    }

    #[test]
    fn nip65_includes_read_marked_relay() {
        let tags = make_tags(vec![vec!["r", "wss://read.example.com", "read"]]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://read.example.com"]);
    }

    #[test]
    fn nip65_excludes_write_only_relay() {
        let tags = make_tags(vec![vec!["r", "wss://write.example.com", "write"]]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert!(relays.is_empty(), "Write-only relays must be excluded");
    }

    #[test]
    fn nip65_mixed_markers_filters_correctly() {
        let tags = make_tags(vec![
            vec!["r", "wss://both.example.com"],
            vec!["r", "wss://read.example.com", "read"],
            vec!["r", "wss://write.example.com", "write"],
        ]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(
            relays,
            vec!["wss://both.example.com", "wss://read.example.com"]
        );
    }

    #[test]
    fn nip65_excludes_non_wss_urls() {
        let tags = make_tags(vec![
            vec!["r", "ws://insecure.example.com"],
            vec!["r", "http://web.example.com"],
            vec!["r", "wss://secure.example.com"],
        ]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://secure.example.com"]);
    }

    #[test]
    fn nip65_empty_tags_returns_empty() {
        let tags = nostr::Tags::from_list(vec![]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert!(relays.is_empty());
    }

    #[test]
    fn nip65_ignores_non_r_tags() {
        let tags = make_tags(vec![
            vec!["p", "wss://not-a-relay.example.com"],
            vec!["e", "wss://also-not.example.com"],
            vec!["r", "wss://real-relay.example.com"],
        ]);
        let relays = RelayManager::extract_nip65_read_relays(&tags);
        assert_eq!(relays, vec!["wss://real-relay.example.com"]);
    }

    // ------------------------------------------------------------------
    // "relay" tag parsing tests (kind 10050 / 10051)
    // ------------------------------------------------------------------

    #[test]
    fn relay_tag_extracts_wss_url() {
        let tags = make_tags(vec![vec!["relay", "wss://inbox.example.com"]]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://inbox.example.com"]);
    }

    #[test]
    fn relay_tag_excludes_non_wss() {
        let tags = make_tags(vec![
            vec!["relay", "ws://insecure.example.com"],
            vec!["relay", "http://web.example.com"],
            vec!["relay", "wss://secure.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://secure.example.com"]);
    }

    #[test]
    fn relay_tag_ignores_r_tags() {
        let tags = make_tags(vec![
            vec!["r", "wss://nip65.example.com"],
            vec!["relay", "wss://inbox.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://inbox.example.com"]);
    }

    #[test]
    fn relay_tag_multiple_urls() {
        let tags = make_tags(vec![
            vec!["relay", "wss://inbox1.example.com"],
            vec!["relay", "wss://inbox2.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(
            relays,
            vec!["wss://inbox1.example.com", "wss://inbox2.example.com"]
        );
    }

    #[test]
    fn relay_tag_empty_returns_empty() {
        let tags = nostr::Tags::from_list(vec![]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert!(relays.is_empty());
    }

    #[test]
    fn relay_tag_malformed_single_element_ignored() {
        let tags = make_tags(vec![
            vec!["relay"],
            vec!["relay", "wss://valid.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://valid.example.com"]);
    }

    #[test]
    fn relay_tag_extra_element_still_accepted() {
        let tags = make_tags(vec![vec!["relay", "wss://relay.example.com", "extra"]]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://relay.example.com"]);
    }

    #[test]
    fn relay_tag_empty_url_excluded() {
        let tags = make_tags(vec![
            vec!["relay", ""],
            vec!["relay", "wss://valid.example.com"],
        ]);
        let relays = RelayManager::extract_relay_tag_urls(&tags);
        assert_eq!(relays, vec!["wss://valid.example.com"]);
    }
}
