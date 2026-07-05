//! Relay manager for Nostr event publishing and subscription.
//!
//! This module provides a relay manager that handles all communication
//! with Nostr relays via direct WSS connections.
//!
//! # Security Model
//!
//! - **WSS Only**: Plaintext ws:// connections are rejected

#[cfg(debug_assertions)]
use std::sync::OnceLock;
use std::time::Duration;

#[cfg(debug_assertions)]
use nostr::Url;
use nostr::{Event, Filter, Kind, PublicKey, RelayUrl};
use nostr_sdk::{Client, RelayPoolNotification};

use super::discovery::discovery_relays;
use super::error::{RelayError, RelayResult};
use super::types::{
    PublishResult, RelayConnectionStatus, RelayEventCheck, RelayFetchOutcome, RelayStatus,
};
use crate::nostr::mls::redact_hex_sequences;

/// Default timeout for relay operations.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

/// Process-static opt-in for plaintext `ws://` URLs targeting loopback /
/// emulator-host aliases. Set once via [`allow_ws_loopback_for_test`] in
/// debug builds and never observable in release (the sibling stub returns
/// `Err`).
///
/// `OnceLock<()>` gives install-once semantics — a second call returns an
/// error rather than silently re-arming the flag — and atomic reads with no
/// extra synchronisation in the validator hot path.
/// Gated behind `#[cfg(debug_assertions)]` so the static itself is not
/// emitted into release binaries — the release [`allow_ws_loopback_for_test`]
/// stub never touches it, and the release [`is_allowed_ws_loopback`] stub
/// returns `false` unconditionally without reading it.
#[cfg(debug_assertions)]
static ALLOW_WS_LOOPBACK_FOR_TEST: OnceLock<()> = OnceLock::new();

/// Hosts considered safe for plaintext `ws://` when the
/// [`ALLOW_WS_LOOPBACK_FOR_TEST`] flag is installed.
///
/// * `localhost` / `127.0.0.1` / `::1` — IPv4/IPv6 loopback.
/// * `10.0.2.2` — Android emulator's alias for the host's `127.0.0.1`. The
///   AVD cannot reach external networks via this address, so it is
///   semantically loopback even though it is not in `127.0.0.0/8`.
///
/// Any other host (including `0.0.0.0`, private LAN ranges, public FQDNs)
/// is rejected even with the test flag installed. Keeping this list short
/// and explicit guards against a misconfigured
/// `--dart-define=HAVEN_E2E_RELAY=ws://relay.example/` leaking events to a
/// real relay.
///
/// Gated behind `#[cfg(debug_assertions)]` so the literal hostnames
/// (notably `10.0.2.2`, the Android-emulator host-loopback alias) do not
/// end up in the release binary's `.rodata`. Their presence would be a
/// fingerprintable test-mode artifact in shipping `.so`s. Release builds
/// don't need this list — the sibling [`is_allowed_ws_loopback`] release
/// stub always returns `false`.
#[cfg(debug_assertions)]
const TEST_LOOPBACK_HOSTS: &[&str] = &["localhost", "127.0.0.1", "::1", "10.0.2.2"];

/// Timeout for waiting for relay WebSocket connections to establish.
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

/// Maximum number of attempts (initial try + retries) for [`RelayManager::publish_event`].
///
/// The first publish after a cold start — e.g. the app foregrounds and the
/// previous WebSocket was closed on background — races the 5 s connection
/// handshake against the per-event `OK` acknowledgement. When the handshake
/// loses that race the relay never acknowledges in time, `accepted_by` comes
/// back empty, and the event (a location, MLS commit, or welcome) is silently
/// dropped. Retrying re-drives [`RelayManager::add_relays_and_connect`] — a
/// fast no-op once the socket is warm — and republishes the **same** event id,
/// which relays dedupe by id, so the retry is idempotent and lands on the
/// now-established connection.
///
/// Worst case (a genuinely unreachable relay): ~3 × (`CONNECTION_TIMEOUT` +
/// `DEFAULT_TIMEOUT`) + 2 × `PUBLISH_RETRY_BACKOFF` ≈ 49 s before
/// `AllRelaysFailed` surfaces. That stays under the 72 s background publish
/// cadence and is guarded against overlap by the caller (`_inFlightPublish` in
/// the background isolate; `kLocationPublishOverlapGuard` in the foreground).
const MAX_PUBLISH_ATTEMPTS: u32 = 3;

/// Backoff between [`RelayManager::publish_event`] attempts.
///
/// Short enough to keep worst-case publish latency bounded for foreground
/// location ticks, long enough to let an in-flight WebSocket handshake finish
/// before the next attempt sends into it.
const PUBLISH_RETRY_BACKOFF: Duration = Duration::from_secs(2);

/// Runs an idempotent publish `attempt` up to `max_attempts` times,
/// returning the first result for which [`PublishResult::is_success`] holds.
///
/// Retries on BOTH a transport error (`Err`) and a "relays reached but none
/// acknowledged" outcome (`Ok` with empty `accepted_by`), because a cold
/// connection surfaces as the latter. Sleeps `backoff` between attempts (never
/// after the last). When every attempt fails the most recent error is
/// returned, defaulting to [`RelayError::AllRelaysFailed`] when the last
/// attempt produced a non-accepting `Ok` — preserving the historical contract
/// that a fully-unacknowledged publish is an `AllRelaysFailed` error.
///
/// The send logic is injected as a closure (receiving the zero-based attempt
/// index) so the retry policy is unit tested without a live relay.
async fn publish_with_retry<F, Fut>(
    max_attempts: u32,
    backoff: Duration,
    mut attempt: F,
) -> RelayResult<PublishResult>
where
    F: FnMut(u32) -> Fut,
    Fut: std::future::Future<Output = RelayResult<PublishResult>>,
{
    let attempts = max_attempts.max(1);
    let mut last_err = RelayError::AllRelaysFailed;
    for i in 0..attempts {
        match attempt(i).await {
            Ok(result) if result.is_success() => return Ok(result),
            // Relays reached but none acknowledged in time — retry on a
            // (hopefully warm) connection. Collapse to AllRelaysFailed so a
            // final miss matches the historical error contract.
            Ok(_) => last_err = RelayError::AllRelaysFailed,
            Err(e) => last_err = e,
        }
        if i + 1 < attempts {
            tokio::time::sleep(backoff).await;
        }
    }
    Err(last_err)
}

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
    ///
    /// Takes the [`Client`] by reference (rather than `&self`) so the
    /// publish retry path can drive it from a closure that owns a cheap
    /// `Client` clone without borrowing the manager across `await` points.
    async fn add_relays_and_connect(client: &Client, relay_urls: &[RelayUrl]) {
        // Register relays sequentially (cheap metadata operation)
        for url in relay_urls {
            match client.add_relay(url.as_str()).await {
                Ok(newly_added) => {
                    log::debug!("[RelayManager] add_relay({url}): newly_added={newly_added}");
                }
                Err(e) => {
                    log::debug!(
                        "[RelayManager] add_relay({url}) failed: {}",
                        redact_hex_sequences(&e.to_string())
                    );
                }
            }
        }

        // Connect to all relays in parallel (each has CONNECTION_TIMEOUT)
        let connect_futures = relay_urls.iter().map(|url| async move {
            match client
                .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                .await
            {
                Ok(()) => {
                    log::debug!("[RelayManager] connected to {url}");
                }
                Err(e) => {
                    log::debug!(
                        "[RelayManager] failed to connect to {url}: {}",
                        redact_hex_sequences(&e.to_string())
                    );
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

        log::debug!(
            "[RelayManager] publish_event: sending kind {} to {} relays",
            event.kind.as_u16(),
            relay_urls.len()
        );

        // Retry the connect+send a bounded number of times so the first
        // publish after a cold start (foreground resume / fresh process)
        // is not silently dropped when the WebSocket handshake loses the
        // race against the per-event OK ack. Each attempt owns cheap clones
        // (the `Client` is internally `Arc`-backed) so the retry closure
        // does not borrow `self` across `await` points. Republishing the
        // same event id is idempotent — relays dedupe by id.
        let client = self.client.clone();
        publish_with_retry(
            MAX_PUBLISH_ATTEMPTS,
            PUBLISH_RETRY_BACKOFF,
            move |attempt| {
                let client = client.clone();
                let relay_urls = relay_urls.clone();
                let event = event.clone();
                async move {
                    if attempt > 0 {
                        log::debug!("[RelayManager] publish_event: retry attempt {attempt}");
                    }
                    Self::try_publish_once(&client, &relay_urls, &event).await
                }
            },
        )
        .await
    }

    /// Performs a single connect-and-publish attempt.
    ///
    /// Returns `Ok` with a [`PublishResult`] that may be unsuccessful
    /// (empty `accepted_by`) when the relays were reached but none
    /// acknowledged in time; the caller's retry loop treats that the same
    /// as a transport error. Returns `Err` on a publish timeout or a
    /// transport-level send error.
    async fn try_publish_once(
        client: &Client,
        relay_urls: &[RelayUrl],
        event: &Event,
    ) -> RelayResult<PublishResult> {
        // Add relays, connect, and wait for WebSocket handshakes.
        Self::add_relays_and_connect(client, relay_urls).await;

        let send_result = tokio::time::timeout(
            DEFAULT_TIMEOUT,
            client.send_event_to(relay_urls.iter().map(RelayUrl::as_str), event),
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
            log::debug!(
                "[RelayManager] publish_event: send_event error: {}",
                redact_hex_sequences(&e.to_string())
            );
            RelayError::Publish(e.to_string())
        })?;
        log::debug!(
            "[RelayManager] publish_event: success={}, failed={}",
            send_result.success.len(),
            send_result.failed.len()
        );
        for (url, err) in &send_result.failed {
            log::debug!(
                "[RelayManager] publish_event: relay {url} failed: {}",
                redact_hex_sequences(err)
            );
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

        Ok(PublishResult {
            event_id: event.id,
            accepted_by,
            rejected_by,
            failed: Vec::new(),
        })
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
                    log::debug!(
                        "[RelayManager] background publish error: {}",
                        redact_hex_sequences(&e.to_string())
                    );
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
        Self::add_relays_and_connect(&self.client, &relay_urls).await;

        // Create a channel for events
        let (tx, rx) = tokio::sync::mpsc::channel(100);

        // Subscribe to each filter individually
        for filter in filters {
            let subscription_output = self
                .client
                .subscribe_to(relay_urls.iter().map(RelayUrl::as_str), filter, None)
                .await
                .map_err(|e| {
                    log::debug!(
                        "[RelayManager] subscribe_to error: {}",
                        redact_hex_sequences(&e.to_string())
                    );
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
        Self::add_relays_and_connect(&self.client, &relay_urls).await;

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
                log::debug!(
                    "[RelayManager] fetch_events error: {}",
                    redact_hex_sequences(&e.to_string())
                );
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
                if values.len() >= 2 && values[0] == "relay" && values[1].starts_with("wss://") {
                    Some(values[1].clone())
                } else {
                    None
                }
            })
            .collect()
    }

    /// Fetches a user's relay list for the given event kind.
    ///
    /// Queries the read-only discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) for
    /// the user's replaceable relay list event and extracts `wss://` URLs
    /// from `"relay"` tags. Works for both kind 10050 (inbox) and kind 10051
    /// (`KeyPackage`) events. This resolves *another* user's relays by bare
    /// pubkey without ever publishing the local user's own list.
    ///
    /// # Errors
    ///
    /// Returns an error if the pubkey is invalid or fetching fails.
    async fn fetch_relay_list(&self, pubkey: &str, kind: Kind) -> RelayResult<Vec<String>> {
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new().kind(kind).author(pk).limit(1);
        let discovery = discovery_relays();
        let events = self.fetch_events(filter, &discovery, None).await?;

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
        self.fetch_relay_list(pubkey, Kind::MlsKeyPackageRelays)
            .await
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
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        let filter = Filter::new().kind(Kind::RelayList).author(pk).limit(1);

        let discovery = discovery_relays();
        let events = self.fetch_events(filter, &discovery, None).await?;

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
    /// 3. [`discovery_relays`][crate::relay::discovery::discovery_relays] —
    ///    last resort (read-only discovery plane).
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
    /// (kind 10002) →
    /// [`discovery_relays`][crate::relay::discovery::discovery_relays].
    /// Empty tiers are skipped. The cascade stops as soon as a
    /// `KeyPackage` is found.
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

        // Final fallback: fetch_keypackage_from_relays queries the read-only
        // discovery plane internally when given an empty slice.
        self.fetch_keypackage_from_relays(pubkey, &[]).await
    }

    /// Fetches a user's key package (kind 30443 or legacy kind 443) from the
    /// given relay list.
    ///
    /// Issues a **single** REQ for both kinds (`kinds([30443, 443])`) — this
    /// matches the reference implementation in `whitenoise-rs`
    /// (`fetch_user_key_package_lookup`) and saves a round-trip versus the
    /// previous two-filter approach. From the returned events, we prefer the
    /// most recent valid kind 30443, falling back to the most recent kind 443
    /// twin if no canonical event was returned.
    ///
    /// Uses the provided relay list directly, falling back to the read-only
    /// discovery plane
    /// ([`discovery_relays`][crate::relay::discovery::discovery_relays]) if the
    /// list is empty.
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
        let pk = PublicKey::parse(pubkey).map_err(|_| RelayError::InvalidPubkey)?;

        // If no relay list, fall back to the read-only discovery plane.
        let discovery: Vec<String>;
        let relays = if keypackage_relays.is_empty() {
            discovery = discovery_relays();
            &discovery
        } else {
            keypackage_relays
        };

        // Single REQ for both kinds. `limit(10)` lets the relay return up to
        // 10 events covering both the canonical and legacy variants — well
        // above any reasonable account's published count.
        let filter = Filter::new()
            .kinds([Kind::Custom(30443), Kind::MlsKeyPackage])
            .author(pk)
            .limit(10);
        let events = self.fetch_events(filter, relays, None).await?;

        Ok(Self::pick_keypackage_from_events(events))
    }

    /// Selects the best key package event from a combined-kind result set.
    ///
    /// Prefers the most recent kind 30443 (addressable) event and falls back
    /// to the most recent kind 443 (legacy) event only when no 30443 event
    /// is present. Returns `None` if neither kind appears.
    ///
    /// Kept separate from [`Self::fetch_keypackage_from_relays`] so the
    /// selection logic can be unit-tested without a relay round-trip.
    fn pick_keypackage_from_events(events: Vec<Event>) -> Option<Event> {
        if events.is_empty() {
            return None;
        }

        if let Some(canonical) = events
            .iter()
            .filter(|e| e.kind == Kind::Custom(30443))
            .max_by_key(|e| e.created_at)
            .cloned()
        {
            return Some(canonical);
        }

        events
            .into_iter()
            .filter(|e| e.kind == Kind::MlsKeyPackage)
            .max_by_key(|e| e.created_at)
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
        Self::add_relays_and_connect(&self.client, &relay_urls).await;

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
                log::debug!(
                    "[RelayManager] check_event_on_relay error: {}",
                    redact_hex_sequences(&e.to_string())
                );
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

    /// Fetches events matching `filter` from each relay independently,
    /// reporting per-relay reachability.
    ///
    /// For every relay this attempts the WebSocket handshake (bounded by
    /// [`CONNECTION_TIMEOUT`]); on success it runs a one-shot fetch (bounded by
    /// [`DEFAULT_TIMEOUT`]) and records the events, marking the relay
    /// `responded`. A relay whose handshake fails is marked not responded and
    /// is not queried. Relays are processed concurrently.
    ///
    /// Unlike [`fetch_events`](Self::fetch_events), one unreachable relay never
    /// fails the whole call: each relay's outcome is independent. This is what
    /// lets a caller report an accurate answered/unanswered tally (e.g. the
    /// Invitations refresh feedback) instead of a single merged result that
    /// hides which relays were reached. A relay that answers with zero events
    /// is `responded == true` with an empty `events` list — distinct from an
    /// unreachable relay (`responded == false`).
    ///
    /// A **malformed / non-`wss://` URL is fault-isolated too**: it yields one
    /// `responded == false` outcome (structurally excluded from any
    /// responders-only republish target, consistent with the fail-closed
    /// maintenance design) instead of collapsing the whole probe. A single bad
    /// entry in a user's stored relay list therefore never disables the probe
    /// for their other, valid relays. The bad URL is validated PER relay via
    /// [`validate_single_relay_url`](Self::validate_single_relay_url); the
    /// original string is preserved verbatim in the outcome so a caller's
    /// `relay_url == configured_entry` matching still works.
    ///
    /// # Errors
    ///
    /// This call never returns a top-level error: both URL validation and
    /// per-relay connection/fetch failures are captured in the returned
    /// outcomes (as non-responders). The `Result` is retained for signature
    /// stability with the other fetch primitives and for forward-compatibility.
    pub async fn fetch_events_per_relay(
        &self,
        filter: Filter,
        relays: &[String],
    ) -> RelayResult<Vec<RelayFetchOutcome>> {
        let client = &self.client;

        let fetch_futures = relays.iter().map(|relay| {
            let filter = filter.clone();
            async move {
                // Validate PER relay: a malformed / non-`wss://` URL becomes a
                // single non-responder outcome, not a whole-probe abort. The
                // raw string is echoed back verbatim so URL-equality matching
                // in the caller is unaffected.
                let Ok(url) = Self::validate_single_relay_url(relay) else {
                    // Presence-only log: no URL string at debug/error level
                    // (it may be sensitive); only that one entry was invalid.
                    log::debug!(
                        "[RelayManager] per-relay: skipping one invalid relay url (non-responder)"
                    );
                    return RelayFetchOutcome {
                        relay_url: relay.clone(),
                        responded: false,
                        events: Vec::new(),
                    };
                };
                let relay_url = url.as_str().to_string();

                // Register the relay (cheap) then attempt a bounded handshake.
                // `try_connect_relay` returns Ok if the socket is (or becomes)
                // connected within CONNECTION_TIMEOUT — the transport-level
                // equivalent of the relay answering our knock.
                let _ = client.add_relay(url.as_str()).await;
                let responded = client
                    .try_connect_relay(url.as_str(), CONNECTION_TIMEOUT)
                    .await
                    .is_ok();

                if !responded {
                    // Presence-only: never log the own-relay URL (may be
                    // sensitive), matching the invalid-URL branch above.
                    log::debug!("[RelayManager] per-relay: one own relay did not respond");
                    return RelayFetchOutcome {
                        relay_url,
                        responded: false,
                        events: Vec::new(),
                    };
                }

                // Connected: one-shot fetch from just this relay. A fetch error
                // after a successful handshake still counts as responded (the
                // relay answered); we simply record no events for it.
                let events = match client
                    .fetch_events_from(std::iter::once(url.as_str()), filter, DEFAULT_TIMEOUT)
                    .await
                {
                    Ok(evs) => evs.into_iter().collect(),
                    Err(e) => {
                        // Presence-only: no own-relay URL at debug (may be
                        // sensitive), matching the not-responded branch above.
                        log::debug!(
                            "[RelayManager] per-relay fetch error (one own relay): {}",
                            redact_hex_sequences(&e.to_string())
                        );
                        Vec::new()
                    }
                };

                RelayFetchOutcome {
                    relay_url,
                    responded: true,
                    events,
                }
            }
        });

        Ok(futures::future::join_all(fetch_futures).await)
    }

    /// Validates relay URLs and ensures they use wss://.
    ///
    /// Plaintext `ws://` is rejected unless the debug-only
    /// [`allow_ws_loopback_for_test`] opt-in has been installed AND the URL
    /// targets a host in [`TEST_LOOPBACK_HOSTS`]. Release builds physically
    /// cannot install the opt-in, so the loopback branch is unreachable
    /// outside of debug-built test binaries.
    fn validate_relay_urls(relays: &[String]) -> RelayResult<Vec<RelayUrl>> {
        let mut urls = Vec::with_capacity(relays.len());

        for relay in relays {
            urls.push(Self::validate_single_relay_url(relay)?);
        }

        Ok(urls)
    }

    /// Validates ONE relay URL, enforcing the `wss://`-only policy (with the
    /// debug-only loopback opt-in).
    ///
    /// This is the per-URL primitive behind [`validate_relay_urls`]. It exists
    /// so a caller that must be per-relay fault-isolated
    /// ([`fetch_events_per_relay`](Self::fetch_events_per_relay)) can validate
    /// each URL independently — one malformed / non-`wss://` entry becomes one
    /// per-relay failure instead of collapsing the whole batch — while the
    /// batch validator keeps its fail-fast semantics for the write paths that
    /// want it.
    ///
    /// # Errors
    ///
    /// Returns [`RelayError::InvalidUrl`] for a plaintext `ws://` URL (outside
    /// the debug loopback opt-in) or an unparseable URL.
    fn validate_single_relay_url(relay: &str) -> RelayResult<RelayUrl> {
        if relay.starts_with("ws://") && !Self::is_allowed_ws_loopback(relay) {
            return Err(RelayError::InvalidUrl(format!(
                "Plaintext ws:// not allowed for security: {relay}"
            )));
        }

        RelayUrl::parse(relay).map_err(|e| RelayError::InvalidUrl(format!("{relay}: {e}")))
    }

    /// Returns `true` iff `relay` is a `ws://` URL targeting a known
    /// loopback / emulator-host alias AND the debug-only test opt-in has
    /// been installed via [`allow_ws_loopback_for_test`].
    ///
    /// The two conditions are AND-ed deliberately: the opt-in alone does
    /// not relax the policy for arbitrary hosts, and the host list alone
    /// does not relax it for production callers.
    #[cfg(debug_assertions)]
    fn is_allowed_ws_loopback(relay: &str) -> bool {
        if ALLOW_WS_LOOPBACK_FOR_TEST.get().is_none() {
            return false;
        }
        // Parse via `Url` so we get robust host extraction even when the
        // URL includes a port, path, or IPv6-bracketed authority.
        let Ok(parsed) = Url::parse(relay) else {
            return false;
        };
        let Some(host) = parsed.host_str() else {
            return false;
        };
        // Strip the brackets the url crate keeps around IPv6 literals so
        // `[::1]` compares equal to the bare `::1` in `TEST_LOOPBACK_HOSTS`.
        let normalised = host
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .unwrap_or(host);
        TEST_LOOPBACK_HOSTS
            .iter()
            .any(|allowed| normalised.eq_ignore_ascii_case(allowed))
    }

    /// Release-build stub: `ws://` URLs are never allowed in production.
    ///
    /// The release [`allow_ws_loopback_for_test`] stub can never install
    /// `ALLOW_WS_LOOPBACK_FOR_TEST`, so the only honest answer is `false`.
    /// Declared `const fn` so LLVM constant-folds the call site in
    /// [`validate_relay_urls`] into an unconditional rejection branch for
    /// `ws://`, with no host-list lookup compiled in and no
    /// `TEST_LOOPBACK_HOSTS` literals in `.rodata`.
    #[cfg(not(debug_assertions))]
    const fn is_allowed_ws_loopback(_relay: &str) -> bool {
        false
    }

    /// Disconnects from all relays.
    pub async fn shutdown(&self) {
        self.client.disconnect().await;
    }

    /// Removes a relay from the connection pool and tears down its WebSocket.
    ///
    /// Used by the user-configurable relay flow when the user explicitly
    /// removes a relay from their preferences. Without this call, the
    /// `nostr_sdk::Client` keeps an idle WebSocket open to the user-removed
    /// relay until process exit, leaking metadata.
    ///
    /// The URL is rejected if it is not `wss://`. Relays the client never
    /// connected to are silently ignored.
    ///
    /// # Errors
    ///
    /// Returns [`RelayError::InvalidUrl`] for non-`wss://` input. Other
    /// failures from `nostr_sdk` are logged but not returned, since the
    /// caller's intent ("stop talking to this relay") is satisfied by best
    /// effort: even an error path leaves the relay disconnected on next
    /// publish (because the storage no longer references it).
    pub async fn remove_relay(&self, url: &str) -> RelayResult<()> {
        // Defense in depth: validate before passing to nostr-sdk so that
        // operators reading logs cannot see surprising URL strings.
        let _ = Self::validate_relay_urls(&[url.to_string()])?;
        if let Err(e) = self.client.remove_relay(url).await {
            log::debug!(
                "[RelayManager] remove_relay({url}) failed: {}",
                redact_hex_sequences(&e.to_string())
            );
        } else {
            log::debug!("[RelayManager] remove_relay({url}) ok");
        }
        Ok(())
    }
}

impl Default for RelayManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Opt in to plaintext `ws://` URLs targeting loopback / emulator-host
/// aliases for hermetic E2E tests.
///
/// Intended exclusively for harnesses that need to point [`RelayManager`]
/// — and every other call site that goes through [`validate_relay_urls`]
/// — at a local strfry on `ws://10.0.2.2:7777` (Android emulator host
/// loopback) or `ws://localhost:7777` (direct host). Without this opt-in
/// the validator hard-rejects every `ws://` URL.
///
/// Even with the opt-in, only the hosts in [`TEST_LOOPBACK_HOSTS`] are
/// accepted. Any other host (LAN address, public FQDN) continues to be
/// rejected. The two checks are AND-ed, so a misconfigured
/// `--dart-define=HAVEN_E2E_RELAY=ws://relay.example/` cannot leak through.
///
/// # Errors
///
/// * Returns `Err` if called more than once in the same process — the
///   opt-in is install-once via [`OnceLock`].
///
/// In release builds the opt-in is unreachable; the sibling stub returns
/// an error so callers fail loudly.
#[cfg(debug_assertions)]
pub fn allow_ws_loopback_for_test() -> Result<(), String> {
    ALLOW_WS_LOOPBACK_FOR_TEST
        .set(())
        .map_err(|_existing| "allow_ws_loopback_for_test already installed".to_string())
}

/// Release-build stub for [`allow_ws_loopback_for_test`].
///
/// Always returns an error so release callers fail closed — the opt-in
/// path is physically unreachable here.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn allow_ws_loopback_for_test() -> Result<(), String> {
    Err("allow_ws_loopback_for_test is disabled in release builds".to_string())
}

/// Test-only predicate: `true` iff `relay` is a `ws://` loopback /
/// emulator-host URL **and** the [`allow_ws_loopback_for_test`] opt-in is
/// installed.
///
/// This re-exposes [`RelayManager::is_allowed_ws_loopback`] so that
/// storage-layer validators — specifically
/// [`crate::circle::storage_relay_prefs::normalize_url`] — can honor the
/// **same** install-once opt-in and the **same** [`TEST_LOOPBACK_HOSTS`]
/// allowlist already used at publish/connect time by
/// [`RelayManager::validate_relay_urls`]. There is exactly one flag and one
/// host list in the codebase; the storage `add_user_relay` path and the
/// publish path relax `ws://` together, never independently.
///
/// Behaviour is byte-for-byte identical to today in production: the release
/// sibling is a `const fn` returning `false`, so any `ws://`-gating caller
/// constant-folds back to an unconditional rejection and no host literals
/// are emitted into the shipping binary.
#[cfg(debug_assertions)]
#[must_use]
pub fn ws_loopback_allowed_for_test(relay: &str) -> bool {
    RelayManager::is_allowed_ws_loopback(relay)
}

/// Release-build stub for [`ws_loopback_allowed_for_test`].
///
/// `const fn` returning `false` so callers (e.g. `normalize_url`'s `ws://`
/// branch) constant-fold to an unconditional rejection — preserving the
/// production invariant that no plaintext `ws://` relay can ever be stored,
/// published to, or connected to.
#[cfg(not(debug_assertions))]
#[must_use]
pub const fn ws_loopback_allowed_for_test(_relay: &str) -> bool {
    false
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
            "wss://relay.primal.net".to_string(),
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

    // ----------------------------------------------------------------------
    // ws:// loopback test opt-in (debug-only)
    //
    // Install-once OnceLock semantics mean the flag pollutes any test that
    // runs in the same binary. Cargo's default per-binary process isolation
    // does NOT extend to inter-test isolation within a binary, so each
    // negative-path test below explicitly avoids depending on the flag's
    // pre-state. The positive-path test runs last (alphabetically last
    // among its file's tests via the `_z_` prefix would be unreliable
    // because cargo doesn't guarantee ordering), so we instead encode the
    // host-rejection check as a unit assertion on `is_allowed_ws_loopback`
    // directly — it only reads the flag, so the positive and negative
    // sub-cases compose without ordering hazard.
    // ----------------------------------------------------------------------

    #[test]
    fn is_allowed_ws_loopback_rejects_when_flag_unset() {
        // Without the flag, every ws:// URL must be rejected even for
        // loopback. Note: this assertion is robust to flag state set by
        // another test in the same binary, because if the flag IS set,
        // the host-list still gates the result.
        if ALLOW_WS_LOOPBACK_FOR_TEST.get().is_none() {
            assert!(!RelayManager::is_allowed_ws_loopback("ws://localhost:7777"));
        }
    }

    #[test]
    fn is_allowed_ws_loopback_rejects_nonloopback_hosts() {
        // Set the flag (idempotent for repeat runs within a binary).
        let _ = allow_ws_loopback_for_test();
        // Public + LAN + bogus + 0.0.0.0 must all stay rejected.
        for host in [
            "ws://relay.damus.io",
            "ws://192.168.1.10:7777",
            "ws://10.0.0.5:7777",  // similar prefix but NOT 10.0.2.2
            "ws://0.0.0.0:7777",   // wildcard, not loopback
            "ws://relay.example/", // FQDN
        ] {
            assert!(
                !RelayManager::is_allowed_ws_loopback(host),
                "expected {host} to be rejected even with the opt-in installed",
            );
        }
    }

    #[test]
    fn is_allowed_ws_loopback_accepts_loopback_hosts_when_optin_installed() {
        let _ = allow_ws_loopback_for_test();
        for host in [
            "ws://localhost:7777",
            "ws://127.0.0.1:7777",
            "ws://[::1]:7777",
            "ws://10.0.2.2:7777",
        ] {
            assert!(
                RelayManager::is_allowed_ws_loopback(host),
                "expected {host} to be accepted once the opt-in is installed",
            );
        }
    }

    #[test]
    fn validate_relay_urls_accepts_ws_loopback_with_optin() {
        let _ = allow_ws_loopback_for_test();
        // strfry-style URL the e2e harness uses.
        let relays = vec!["ws://10.0.2.2:7777".to_string()];
        let result = RelayManager::validate_relay_urls(&relays);
        assert!(
            result.is_ok(),
            "ws:// loopback must round-trip the validator with the opt-in installed"
        );
    }

    #[test]
    fn allow_ws_loopback_for_test_install_once() {
        // First install may or may not be the first call in this binary,
        // but a subsequent install MUST always error.
        let _ = allow_ws_loopback_for_test();
        let err =
            allow_ws_loopback_for_test().expect_err("second install must report already-installed");
        assert!(err.contains("already installed"), "got: {err}");
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

    #[tokio::test]
    async fn fetch_events_per_relay_plaintext_is_a_non_responder_not_a_whole_probe_error() {
        // A plaintext ws:// URL is fault-isolated PER relay: it yields one
        // `responded == false` outcome instead of collapsing the whole probe.
        // This is what stops a single bad own-relay entry from disabling
        // maintenance for the user's other, valid relays. The outcome is never
        // a responder (fail-closed: never a republish target, never "healthy").
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);
        let result = manager
            .fetch_events_per_relay(filter, &["ws://insecure.relay.com".to_string()])
            .await
            .expect("a bad url must not fail the whole probe");
        assert_eq!(result.len(), 1, "one input url ⇒ one per-relay outcome");
        assert!(
            !result[0].responded,
            "a plaintext ws:// url is a non-responder (never a republish target)"
        );
        assert!(result[0].events.is_empty());
    }

    #[tokio::test]
    async fn fetch_events_per_relay_invalid_url_is_a_non_responder_not_a_whole_probe_error() {
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);
        let result = manager
            .fetch_events_per_relay(filter, &["not-a-url".to_string()])
            .await
            .expect("a malformed url must not fail the whole probe");
        assert_eq!(result.len(), 1, "one input url ⇒ one per-relay outcome");
        assert!(
            !result[0].responded,
            "a malformed url is a non-responder (never a republish target)"
        );
        assert!(result[0].events.is_empty());
    }

    #[tokio::test]
    async fn fetch_events_per_relay_empty_returns_empty() {
        // No relays => no connections attempted => an empty outcome list,
        // never an error. The Invitations refresh relies on this to render
        // its zero-relays state without pinging anything.
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);
        let result = manager.fetch_events_per_relay(filter, &[]).await;
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[tokio::test]
    async fn fetch_events_per_relay_one_bad_url_does_not_collapse_the_probe() {
        // HEADLINE robustness fix: a single malformed URL in the relay set must
        // NOT collapse the whole probe. Before the fix, `validate_relay_urls`
        // ran up-front with `?`, so ONE bad entry returned a top-level Err and
        // NONE of the (valid) relays were probed at all — silently disabling
        // maintenance for every good relay.
        //
        // After the fix the probe validates PER relay: the malformed entry
        // becomes one non-responder outcome while the well-formed relays are
        // each attempted independently. We use a well-formed `wss://` URL to an
        // unreachable host as the "valid" relay: it is a non-responder too
        // (handshake fails), but crucially it is STILL PRESENT in the per-relay
        // outcome list, proving the bad URL did not abort the batch. (Live
        // responder behaviour is covered by the MockRelay integration test.)
        let manager = RelayManager::new();
        let filter = Filter::new().kind(Kind::GiftWrap).limit(1);

        let bad = "not-a-url".to_string();
        // Documentation-reserved TLD; well-formed wss:// that resolves nowhere.
        let good_but_unreachable = "wss://relay.invalid.example".to_string();
        let relays = vec![bad.clone(), good_but_unreachable.clone()];

        let outcomes = manager
            .fetch_events_per_relay(filter, &relays)
            .await
            .expect("one bad url must not fail the whole probe");

        // Both inputs yield a per-relay outcome — the malformed one did NOT
        // short-circuit the valid one out of the batch (the mutation this test
        // kills: revert to `validate_relay_urls(relays)?` ⇒ this call is Err ⇒
        // `.expect` panics / zero probed relays).
        assert_eq!(outcomes.len(), 2, "each input url ⇒ one per-relay outcome");

        // The malformed URL is echoed back verbatim and is a non-responder
        // (fail-closed: never a republish target, never healthy).
        let bad_outcome = outcomes
            .iter()
            .find(|o| o.relay_url == bad)
            .expect("the malformed url must appear as its own outcome");
        assert!(
            !bad_outcome.responded,
            "a malformed url is structurally a non-responder"
        );
        assert!(bad_outcome.events.is_empty());

        // The well-formed relay was independently attempted (present in the
        // outcomes under its canonical url) rather than skipped.
        assert!(
            outcomes.iter().any(|o| o.relay_url == good_but_unreachable),
            "the well-formed relay must be probed independently of the bad one"
        );
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

    // ----------------------------------------------------------------------
    // publish_with_retry — bounded, idempotent retry policy
    //
    // The send logic is injected as a closure, so these cover the retry
    // policy end-to-end without a live relay. `Duration::ZERO` backoff keeps
    // them instant.
    // ----------------------------------------------------------------------

    fn dummy_publish_result(accepted: bool) -> PublishResult {
        PublishResult {
            event_id: nostr::EventId::from_slice(&[0u8; 32]).expect("32-byte id"),
            accepted_by: if accepted {
                vec!["wss://relay.example.com".to_string()]
            } else {
                vec![]
            },
            rejected_by: vec![],
            failed: vec![],
        }
    }

    #[tokio::test]
    async fn publish_with_retry_returns_on_first_success() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(3, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(true)) }
        })
        .await;
        assert!(result.expect("success").is_success());
        assert_eq!(calls.get(), 1, "must not retry after the first acceptance");
    }

    #[tokio::test]
    async fn publish_with_retry_recovers_from_cold_connection() {
        // First two attempts reach the relays but get no OK (empty
        // accepted_by) — the cold-connect race — then the third lands.
        let result = publish_with_retry(3, Duration::ZERO, |attempt| async move {
            if attempt < 2 {
                Ok(dummy_publish_result(false))
            } else {
                Ok(dummy_publish_result(true))
            }
        })
        .await;
        assert!(result.expect("eventual success").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_recovers_from_transport_error() {
        let result = publish_with_retry(3, Duration::ZERO, |attempt| async move {
            if attempt == 0 {
                Err(RelayError::Timeout("cold socket".to_string()))
            } else {
                Ok(dummy_publish_result(true))
            }
        })
        .await;
        assert!(result.expect("recovered").is_success());
    }

    #[tokio::test]
    async fn publish_with_retry_exhausts_then_returns_all_relays_failed() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(3, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(false)) }
        })
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
        assert_eq!(calls.get(), 3, "must use the full attempt budget");
    }

    #[tokio::test]
    async fn publish_with_retry_surfaces_last_transport_error() {
        let result = publish_with_retry(2, Duration::ZERO, |_| async {
            Err(RelayError::Timeout("still cold".to_string()))
        })
        .await;
        assert!(matches!(result, Err(RelayError::Timeout(_))));
    }

    #[tokio::test]
    async fn publish_with_retry_honours_single_attempt() {
        let calls = std::cell::Cell::new(0u32);
        let result = publish_with_retry(1, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(false)) }
        })
        .await;
        assert!(matches!(result, Err(RelayError::AllRelaysFailed)));
        assert_eq!(calls.get(), 1, "max_attempts=1 must not retry");
    }

    #[tokio::test]
    async fn publish_with_retry_clamps_zero_attempts_to_one() {
        let calls = std::cell::Cell::new(0u32);
        let _ = publish_with_retry(0, Duration::ZERO, |_| {
            calls.set(calls.get() + 1);
            async { Ok(dummy_publish_result(false)) }
        })
        .await;
        assert_eq!(calls.get(), 1, "zero attempts clamps to a single try");
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

    // ------------------------------------------------------------------
    // KeyPackage selection tests (combined-kind fetch result handling)
    // ------------------------------------------------------------------

    /// Builds a signed key package event of the given kind and `created_at`,
    /// using `keys` so the returned events share a single author. Used by
    /// the `pick_keypackage_from_events` tests below.
    fn make_kp_event(keys: &nostr::Keys, kind: Kind, created_at_secs: u64) -> Event {
        let timestamp = nostr::Timestamp::from_secs(created_at_secs);
        nostr::EventBuilder::new(kind, "")
            .custom_created_at(timestamp)
            .sign_with_keys(keys)
            .expect("event signing must succeed for tests")
    }

    #[test]
    fn pick_keypackage_returns_none_for_empty_input() {
        assert!(RelayManager::pick_keypackage_from_events(vec![]).is_none());
    }

    #[test]
    fn pick_keypackage_prefers_30443_over_443_even_when_443_is_newer() {
        let keys = nostr::Keys::generate();
        let canonical_old = make_kp_event(&keys, Kind::Custom(30443), 1_000);
        let legacy_new = make_kp_event(&keys, Kind::MlsKeyPackage, 9_000);

        let picked = RelayManager::pick_keypackage_from_events(vec![
            legacy_new.clone(),
            canonical_old.clone(),
        ])
        .expect("should pick a key package");

        assert_eq!(
            picked.kind,
            Kind::Custom(30443),
            "must prefer canonical 30443 over legacy 443 even when 443 is newer"
        );
        assert_eq!(picked.id, canonical_old.id);
    }

    #[test]
    fn pick_keypackage_picks_newest_30443_when_multiple_present() {
        let keys = nostr::Keys::generate();
        let old_canonical = make_kp_event(&keys, Kind::Custom(30443), 1_000);
        let new_canonical = make_kp_event(&keys, Kind::Custom(30443), 5_000);

        let picked = RelayManager::pick_keypackage_from_events(vec![
            old_canonical.clone(),
            new_canonical.clone(),
        ])
        .expect("should pick a key package");

        assert_eq!(picked.id, new_canonical.id);
    }

    #[test]
    fn pick_keypackage_falls_back_to_443_when_no_30443_present() {
        let keys = nostr::Keys::generate();
        let legacy = make_kp_event(&keys, Kind::MlsKeyPackage, 1_000);

        let picked = RelayManager::pick_keypackage_from_events(vec![legacy.clone()])
            .expect("should fall back to legacy");

        assert_eq!(picked.kind, Kind::MlsKeyPackage);
        assert_eq!(picked.id, legacy.id);
    }

    #[test]
    fn pick_keypackage_picks_newest_443_when_only_legacy_present() {
        let keys = nostr::Keys::generate();
        let old_legacy = make_kp_event(&keys, Kind::MlsKeyPackage, 1_000);
        let new_legacy = make_kp_event(&keys, Kind::MlsKeyPackage, 7_000);

        let picked =
            RelayManager::pick_keypackage_from_events(vec![old_legacy.clone(), new_legacy.clone()])
                .expect("should pick a key package");

        assert_eq!(picked.id, new_legacy.id);
    }

    #[test]
    fn pick_keypackage_ignores_unrelated_kinds() {
        let keys = nostr::Keys::generate();
        let unrelated = make_kp_event(&keys, Kind::TextNote, 9_000);

        assert!(
            RelayManager::pick_keypackage_from_events(vec![unrelated]).is_none(),
            "unrelated kinds must not be returned"
        );
    }
}
