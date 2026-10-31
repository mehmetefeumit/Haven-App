//! What the two opt-in relay-pool probes share: the verdict, the signer-less
//! connection, the unauthenticated read, the publish-and-read-back, and the
//! in-process relays their hermetic self-tests run against.
//!
//! Each probe binary uses a subset, so `dead_code` is silenced here.

#![allow(dead_code)]

use std::net::SocketAddr;
use std::time::Duration;

use nostr::util::BoxedFuture;
use nostr::{Event, Filter};
use nostr_relay_builder::builder::RelayBuilder;
use nostr_relay_builder::prelude::{PolicyResult, WritePolicy};
use nostr_relay_builder::LocalRelay;
use nostr_sdk::prelude::RelayPoolNotification;
use nostr_sdk::Client;

/// Long enough for a TLS handshake to a distant host, short enough that eight
/// dead relays cannot stall the run past a coffee break.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Budget for one relay to answer a `REQ` with `EOSE`, an `AUTH` challenge or a
/// `CLOSED`. A relay that says nothing at all in this window is reported as
/// `unknown`, never as a pass.
pub const READ_TIMEOUT: Duration = Duration::from_secs(15);

/// Budget for the read-back that decides whether an `OK`-acked publish was
/// actually stored.
pub const READBACK_TIMEOUT: Duration = Duration::from_secs(15);

/// The most of a relay's own text a finding keeps.
const RELAY_TEXT_MAX_CHARS: usize = 80;

/// What one probe of one criterion concluded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// The criterion holds.
    Pass,
    /// The criterion is violated; the string is the observed reason.
    Fail(String),
    /// Nothing conclusive was observed (timeout, unreachable host). Never
    /// treated as a pass — an unanswered probe is exactly the state the vetting
    /// records exist to stop us from assuming away.
    Unknown(String),
}

impl Verdict {
    /// Renders the verdict for a Markdown findings table.
    pub fn cell(&self) -> String {
        match self {
            Self::Pass => "pass".to_string(),
            Self::Fail(why) => format!("**FAIL** — {why}"),
            Self::Unknown(why) => format!("unknown — {why}"),
        }
    }

    pub const fn is_fail(&self) -> bool {
        matches!(self, Self::Fail(_))
    }

    pub const fn is_pass(&self) -> bool {
        matches!(self, Self::Pass)
    }
}

/// A relay's own text, fit for a findings cell: control characters and the
/// table's own delimiters dropped, cut to [`RELAY_TEXT_MAX_CHARS`]. The text is
/// a third party's, and the table is pasted into a checked-in file.
pub fn relay_text(raw: &str) -> String {
    raw.chars()
        .filter(|c| !c.is_control() && !matches!(c, '|' | '`' | '<' | '>' | '[' | ']'))
        .take(RELAY_TEXT_MAX_CHARS)
        .collect()
}

/// Connects a signer-less client to one relay.
///
/// No signer is the point: `nostr-sdk` cannot auto-answer a NIP-42 challenge
/// without one, so an `AUTH` message reaches the notification stream instead of
/// being transparently satisfied — which would turn "no AUTH on read" into a
/// tautology.
pub async fn connect(url: &str) -> Result<Client, String> {
    let client = Client::builder().build();
    client
        .add_relay(url)
        .await
        .map_err(|e| format!("add_relay: {}", relay_text(&e.to_string())))?;
    client
        .try_connect_relay(url, CONNECT_TIMEOUT)
        .await
        .map_err(|e| format!("connect: {}", relay_text(&e.to_string())))?;
    Ok(client)
}

/// Opens one `REQ` for `filter` and reports whether the relay served it to an
/// unauthenticated client.
pub async fn probe_read_without_auth(client: &Client, url: &str, filter: Filter) -> Verdict {
    // Subscribe to the notification stream BEFORE the REQ, or a fast relay's
    // reply races the subscription and the probe reports a false `unknown`.
    let mut notifications = client.notifications();
    if let Err(e) = client.subscribe_to([url], filter, None).await {
        return Verdict::Unknown(format!("subscribe failed: {e}"));
    }

    let drain = async {
        loop {
            match notifications.recv().await {
                Ok(RelayPoolNotification::Message { message, .. }) => match message {
                    nostr::RelayMessage::Auth { .. } => {
                        return Verdict::Fail("relay issued a NIP-42 AUTH challenge".to_string());
                    }
                    nostr::RelayMessage::Closed { message, .. } => {
                        return Verdict::Fail(format!(
                            "relay CLOSED the REQ: {}",
                            relay_text(&message)
                        ));
                    }
                    // EOSE is the only affirmative answer: the relay served a
                    // stored-events query to an unauthenticated client and said
                    // so. An EVENT alone would too, but EOSE always follows.
                    nostr::RelayMessage::EndOfStoredEvents(_) => return Verdict::Pass,
                    _ => {}
                },
                Ok(_) => {}
                Err(e) => return Verdict::Unknown(format!("notification stream ended: {e}")),
            }
        }
    };

    tokio::time::timeout(READ_TIMEOUT, drain)
        .await
        .unwrap_or_else(|_| {
            Verdict::Unknown("no EOSE, AUTH or CLOSED within the budget".to_string())
        })
}

/// Publishes `event`; `Err` carries the verdict when the relay did not ack it.
pub async fn publish(client: &Client, url: &str, event: &Event) -> Result<(), Verdict> {
    match client.send_event_to([url], event).await {
        Ok(output) => {
            if let Some((_, reason)) = output.failed.iter().next() {
                return Err(Verdict::Fail(format!(
                    "relay rejected the publish: {}",
                    relay_text(reason)
                )));
            }
            if output.success.is_empty() {
                return Err(Verdict::Unknown(
                    "relay neither acked nor rejected".to_string(),
                ));
            }
            Ok(())
        }
        Err(e) => Err(Verdict::Fail(format!("publish failed: {e}"))),
    }
}

/// Reads an acked `event` back by `readback`.
///
/// The read-back is the whole point. An `OK true` that the relay then drops is
/// a write that looks accepted and reaches nobody, and only a re-`REQ`
/// distinguishes the two.
pub async fn read_back(client: &Client, url: &str, event: &Event, readback: Filter) -> Verdict {
    match client
        .fetch_events_from([url], readback, READBACK_TIMEOUT)
        .await
    {
        Ok(events) if events.iter().any(|served| served.id == event.id) => Verdict::Pass,
        Ok(_) => Verdict::Fail(
            "relay acked the publish but did not serve the event back (silent drop)".to_string(),
        ),
        Err(e) => Verdict::Unknown(format!("read-back failed: {e}")),
    }
}

/// Refuses every event, the way a relay with a paid-write or allowlist policy
/// refuses ours.
#[derive(Debug)]
pub struct RefuseEveryWrite;

impl WritePolicy for RefuseEveryWrite {
    fn admit_event<'a>(
        &'a self,
        _event: &'a Event,
        _addr: &'a SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async { PolicyResult::Reject("restricted: not on the allowlist".to_string()) })
    }
}

/// Starts an in-process relay and returns it with its `ws://` URL.
///
/// The caller MUST keep the relay alive for the whole test.
pub async fn local_relay(builder: RelayBuilder) -> (LocalRelay, String) {
    let relay = LocalRelay::new(builder);
    relay.run().await.expect("local relay runs");
    let url = relay.url().await.to_string();
    (relay, url)
}
