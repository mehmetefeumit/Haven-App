//! Opt-in behavioural vetting of the curated profile-relay pool.
//!
//! Three of the five selection criteria in [`PRODUCTION_PROFILE_RELAYS`]'s doc
//! comment are statements about code (disjointness, `wss://`-only,
//! metadata-specialisation) and are pinned by ordinary tests. Two are
//! statements about how eight third-party hosts BEHAVE, and no amount of
//! reading the list settles them:
//!
//! * criterion 2 — accepts an unauthenticated kind-0 write from an arbitrary
//!   pubkey. A relay that rejects, or silently drops, our publish makes the
//!   user invisible to every peer whose assignment salt lands there;
//! * criterion 3 — serves reads without a NIP-42 AUTH challenge. The profile
//!   fetch path is built with no signer and structurally cannot answer one.
//!
//! # Why this never runs in CI
//!
//! Answering either question requires dialling eight servers Haven does not
//! operate. Wiring that into the normal test pass would make the suite
//! non-hermetic (red on someone else's outage, not on a Haven regression) and
//! would broadcast Haven's build cadence to those eight operators — every push,
//! from a CI egress address, indefinitely. So this is `#[ignore]`d AND gated on
//! an env flag, in the shape `profile_blossom_integration_test.rs` already
//! uses: a maintainer runs it deliberately, and the dated result is checked in
//! at `docs/PROFILE_RELAY_VETTING.md`.
//!
//! # Running it
//!
//! ```bash
//! HAVEN_PROBE_PROFILE_RELAYS=1 \
//!   cargo test --test profile_relay_vetting -- --ignored --nocapture
//! ```
//!
//! Read `docs/PROFILE_RELAY_VETTING.md` FIRST — the run discloses the
//! operator's IP to all eight hosts and leaves a throwaway kind-0 on each.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::net::SocketAddr;
use std::time::Duration;

use haven_core::profile::{
    build_blank_metadata_event, build_metadata_event, production_profile_relays, ProfileMetadata,
};
use nostr::util::BoxedFuture;
use nostr::{Event, Filter, Keys, Kind, Metadata};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_relay_builder::prelude::{PolicyResult, WritePolicy};
use nostr_relay_builder::LocalRelay;
use nostr_sdk::prelude::RelayPoolNotification;
use nostr_sdk::Client;

/// Long enough for a TLS handshake to a distant host, short enough that eight
/// dead relays cannot stall the run past a coffee break.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Budget for one relay to answer a `REQ` with `EOSE`, an `AUTH` challenge or a
/// `CLOSED`. A relay that says nothing at all in this window is reported as
/// `unknown`, never as a pass.
const READ_TIMEOUT: Duration = Duration::from_secs(15);

/// Budget for the read-back that decides whether an `OK`-acked publish was
/// actually stored.
const READBACK_TIMEOUT: Duration = Duration::from_secs(15);

/// What one probe of one criterion concluded.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Verdict {
    /// The criterion holds.
    Pass,
    /// The criterion is violated; the string is the observed reason.
    Fail(String),
    /// Nothing conclusive was observed (timeout, unreachable host). Never
    /// treated as a pass — an unanswered probe is exactly the state this file
    /// exists to stop us from assuming away.
    Unknown(String),
}

impl Verdict {
    /// Renders the verdict for the Markdown findings table.
    fn cell(&self) -> String {
        match self {
            Self::Pass => "pass".to_string(),
            Self::Fail(why) => format!("**FAIL** — {why}"),
            Self::Unknown(why) => format!("unknown — {why}"),
        }
    }

    const fn is_fail(&self) -> bool {
        matches!(self, Self::Fail(_))
    }
}

/// Both behavioural verdicts for one relay.
#[derive(Debug)]
struct Findings {
    /// Criterion 3: reads are served without a NIP-42 challenge.
    read_without_auth: Verdict,
    /// Criterion 2: an unauthenticated kind-0 write is accepted AND retained.
    accepts_kind0_write: Verdict,
}

/// The kind-0 the probe publishes.
///
/// Deliberately transparent rather than camouflaged: writing to someone else's
/// server is more defensible when the record says what it is. If a relay is
/// ever suspected of special-casing the name, re-run with a neutral one — the
/// event is otherwise byte-identical in shape to what a Haven user publishes,
/// because it goes through [`build_metadata_event`], the app's own builder.
///
/// The `about` text must stay true of what the probe actually does: it
/// supersedes this event with a BLANK kind-0, it does not delete it. No kind-5
/// is ever issued, so the relay keeps a signed record of the throwaway key. Say
/// "retracted" here and the overstatement is written into eight third parties'
/// databases, where no later edit can reach it.
fn probe_metadata() -> ProfileMetadata {
    ProfileMetadata::from_metadata(Metadata::new().name("haven-relay-probe").about(
        "Throwaway key used to vet this relay for Haven's profile pool. \
         Overwritten with a blank profile right after; nothing is deleted.",
    ))
}

/// Connects a signer-less client to one relay.
///
/// No signer is the point: `nostr-sdk` cannot auto-answer a NIP-42 challenge
/// without one, so an `AUTH` message reaches the notification stream instead of
/// being transparently satisfied — which would turn criterion 3 into a
/// tautology.
async fn connect(url: &str) -> Result<Client, String> {
    let client = Client::builder().build();
    client
        .add_relay(url)
        .await
        .map_err(|e| format!("add_relay: {e}"))?;
    client
        .try_connect_relay(url, CONNECT_TIMEOUT)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    Ok(client)
}

/// Probes criterion 3 by opening one `REQ` and watching what comes back.
async fn probe_read_without_auth(client: &Client, url: &str) -> Verdict {
    // Subscribe to the notification stream BEFORE the REQ, or a fast relay's
    // reply races the subscription and the probe reports a false `unknown`.
    let mut notifications = client.notifications();
    let filter = Filter::new().kind(Kind::Metadata).limit(1);
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
                        return Verdict::Fail(format!("relay CLOSED the REQ: {message}"));
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

/// Probes criterion 2 by publishing a kind-0 from a fresh key and reading it
/// back.
///
/// The read-back is the whole point. An `OK true` that the relay then drops is
/// precisely the failure the criterion names — the user looks published and is
/// invisible — and only a re-`REQ` distinguishes the two.
async fn probe_kind0_write(client: &Client, url: &str) -> Verdict {
    let keys = Keys::generate();
    let event = match build_metadata_event(&keys, &probe_metadata(), None) {
        Ok(event) => event,
        Err(e) => return Verdict::Unknown(format!("could not build the probe event: {e}")),
    };

    match client.send_event_to([url], &event).await {
        Ok(output) => {
            if let Some((_, reason)) = output.failed.iter().next() {
                return Verdict::Fail(format!("relay rejected the publish: {reason}"));
            }
            if output.success.is_empty() {
                return Verdict::Unknown("relay neither acked nor rejected".to_string());
            }
        }
        Err(e) => return Verdict::Fail(format!("publish failed: {e}")),
    }

    let readback = Filter::new()
        .author(keys.public_key())
        .kind(Kind::Metadata)
        .limit(1);
    let verdict = match client
        .fetch_events_from([url], readback, READBACK_TIMEOUT)
        .await
    {
        Ok(events) if events.is_empty() => Verdict::Fail(
            "relay acked the publish but did not serve the event back (silent drop)".to_string(),
        ),
        Ok(_) => Verdict::Pass,
        Err(e) => Verdict::Unknown(format!("read-back failed: {e}")),
    };

    // Leave the relay holding `{}` rather than an orphan profile. Best-effort:
    // a relay that will not take the retraction has already answered the
    // question this function asks, so a failure here must not change the
    // verdict.
    if let Ok(blank) = build_blank_metadata_event(&keys, Some(event.created_at.as_secs())) {
        let _ = client.send_event_to([url], &blank).await;
    }

    verdict
}

/// Renders the findings as the Markdown table `docs/PROFILE_RELAY_VETTING.md`
/// carries, so a maintainer transcribes nothing by hand.
fn findings_table(findings: &BTreeMap<String, Findings>) -> String {
    let mut out = String::from(
        "| relay | accepts unauthenticated kind-0 write (criterion 2) | \
         no NIP-42 AUTH on read (criterion 3) |\n|---|---|---|\n",
    );
    for (relay, f) in findings {
        let _ = writeln!(
            out,
            "| `{relay}` | {} | {} |",
            f.accepts_kind0_write.cell(),
            f.read_without_auth.cell(),
        );
    }
    out
}

// ===========================================================================
// Hermetic self-tests: the probe's own verdict logic, over in-process relays.
//
// The probe above never runs in CI, so nothing else would notice if it degraded
// into something that always says "pass" — and a vetting tool that cannot fail
// is worse than no vetting tool, because the findings file would then record a
// guarantee nobody holds. These two cases dial only loopback, run in the normal
// `cargo test` pass, and pin both branches of criterion 2.
// ===========================================================================

/// Refuses every event, the way a relay with a paid-write or allowlist policy
/// refuses ours.
#[derive(Debug)]
struct RefuseEveryWrite;

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
async fn local_relay(builder: RelayBuilder) -> (LocalRelay, String) {
    let relay = LocalRelay::new(builder);
    relay.run().await.expect("local relay runs");
    let url = relay.url().await.to_string();
    (relay, url)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn probe_passes_a_relay_that_serves_reads_and_keeps_our_kind0() {
    let (_relay, url) = local_relay(RelayBuilder::default()).await;
    let client = connect(&url).await.expect("loopback relay connects");

    assert_eq!(probe_read_without_auth(&client, &url).await, Verdict::Pass);
    // Pass here requires BOTH halves: the relay acked the publish AND served
    // the event back. A probe that only checked the ack would be green against
    // a silent-drop relay, which is the failure criterion 2 is about.
    assert_eq!(probe_kind0_write(&client, &url).await, Verdict::Pass);

    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn probe_fails_a_relay_that_refuses_our_kind0() {
    let (_relay, url) = local_relay(RelayBuilder::default().write_policy(RefuseEveryWrite)).await;
    let client = connect(&url).await.expect("loopback relay connects");

    // Reads are unaffected — the failure has to be attributed to the write
    // criterion alone, or the findings table would blame the wrong thing.
    assert_eq!(probe_read_without_auth(&client, &url).await, Verdict::Pass);

    let verdict = probe_kind0_write(&client, &url).await;
    match &verdict {
        Verdict::Fail(why) => assert!(
            why.contains("restricted"),
            "the relay's own reason must survive into the findings: {why}"
        ),
        other => panic!("a refusing relay must not pass vetting, got {other:?}"),
    }

    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn probe_fails_a_relay_that_demands_nip42_auth_on_read() {
    // The real criterion-3 failure, not an approximation of it: the relay runs
    // NIP-42 in read mode and challenges. Haven's fetch path holds no signer
    // and structurally cannot answer, so such a relay is inert for the profile
    // plane — and the probe has to say so rather than time out into `unknown`.
    let (_relay, url) = local_relay(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Read,
    }))
    .await;
    let client = connect(&url).await.expect("loopback relay connects");

    // Asserting the REASON, not merely `is_fail()`: such a relay sends both an
    // AUTH challenge and a CLOSED, so a bare "it failed" assertion stays green
    // even if the probe stopped recognising AUTH at all and only noticed the
    // CLOSED. The findings table has to name the right cause — "add a signer"
    // and "pick a different relay" are different remedies.
    match probe_read_without_auth(&client, &url).await {
        Verdict::Fail(why) => assert!(
            why.contains("AUTH"),
            "an AUTH-on-read relay must be reported as one: {why}"
        ),
        other => panic!("an AUTH-on-read relay must not pass vetting, got {other:?}"),
    }

    client.shutdown().await;
}

#[tokio::test]
#[ignore = "dials eight third-party relays (HAVEN_PROBE_PROFILE_RELAYS=1)"]
async fn curated_profile_relays_accept_unauthenticated_kind0_and_serve_reads_without_auth() {
    if std::env::var("HAVEN_PROBE_PROFILE_RELAYS").is_err() {
        eprintln!(
            "skipping: set HAVEN_PROBE_PROFILE_RELAYS=1 to dial the curated pool. \
             Read docs/PROFILE_RELAY_VETTING.md first."
        );
        return;
    }

    let pool = production_profile_relays();
    assert!(!pool.is_empty(), "non-vacuity: the curated pool is empty");

    let mut findings: BTreeMap<String, Findings> = BTreeMap::new();
    for url in &pool {
        eprintln!("probing {url} ...");
        let entry = match connect(url).await {
            Ok(client) => {
                let read_without_auth = probe_read_without_auth(&client, url).await;
                let accepts_kind0_write = probe_kind0_write(&client, url).await;
                client.shutdown().await;
                Findings {
                    read_without_auth,
                    accepts_kind0_write,
                }
            }
            Err(why) => Findings {
                read_without_auth: Verdict::Unknown(why.clone()),
                accepts_kind0_write: Verdict::Unknown(why),
            },
        };
        findings.insert(url.clone(), entry);
    }

    let table = findings_table(&findings);
    eprintln!("\n{table}");

    // Report every relay before failing: a maintainer running this wants the
    // whole picture, not the first bad host.
    let failures: Vec<&String> = findings
        .iter()
        .filter(|(_, f)| f.read_without_auth.is_fail() || f.accepts_kind0_write.is_fail())
        .map(|(relay, _)| relay)
        .collect();
    assert!(
        failures.is_empty(),
        "these curated profile relays violate a selection criterion and must be \
         replaced in PRODUCTION_PROFILE_RELAYS: {failures:?}\n\n{table}",
    );
}
