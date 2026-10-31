//! Opt-in behavioural vetting of the curated location-relay pool.
//!
//! A new circle's relays are three drawn from `PRODUCTION_LOCATION_RELAYS`, and
//! every one of them must do four things no reading of the list can settle:
//!
//! * L1 — serve a signer-less `#h` read. Haven's receive planes hold no signer
//!   and never authenticate (Security Rule 16), so a relay that challenges is
//!   inert for a circle;
//! * L2 — keep a location-shaped kind-445 (`h` + NIP-40 `expiration`) from a
//!   key it has never seen, and serve it back by `#h`: every location is sent
//!   under a fresh key (Security Rule 2);
//! * L3 — keep a commit-shaped kind-445 (`h` only). A relay that kept only
//!   expiring events would pass L2 and silently strand every member who was
//!   offline for a commit;
//! * L4 — answer Haven's own NIP-77 session with the probe event and nothing
//!   else. It is the one way back to a commit buried past a relay's replay
//!   limit, so it gates.
//!
//! L5 is evidence only: whether the relay serves any kind-445 older than 30
//! days.
//!
//! The probe events cannot be taken for a real message: every Haven read names
//! the `#h` of a group it holds, the probe's `h` is 32 fresh `OsRng` bytes, and
//! its content is random bytes that fail authentication under every key. They
//! are built here with `nostr::EventBuilder`, never through the peeler or MDK.
//!
//! # Why this never runs in CI
//!
//! It dials eight servers Haven does not operate and writes to them: red on
//! someone else's outage, and a beacon of Haven's build cadence to those
//! operators. So it is `#[ignore]`d AND gated on an env flag; a maintainer runs
//! it deliberately and checks the dated result in at
//! `docs/LOCATION_RELAY_VETTING.md`. The self-tests below run on every
//! `cargo test` against in-process relays and print no relay address.
//!
//! # Running it
//!
//! ```bash
//! HAVEN_PROBE_LOCATION_RELAYS=1 \
//!   cargo test --test location_relay_vetting -- --ignored --nocapture
//! ```
//!
//! Read `docs/LOCATION_RELAY_VETTING.md` FIRST — the run discloses the
//! operator's IP to all eight hosts and may leave a random kind-445 on each.

mod vetting;

#[allow(dead_code)]
#[path = "helpers/neg_wire.rs"]
mod neg_wire;

use std::collections::BTreeMap;
use std::fmt::Write as _;

use base64::Engine as _;
use haven_core::circle::production_location_relays;
use haven_core::location::LOCATION_MESSAGE_RETENTION_SECS;
use haven_core::relay::scripted_relay::ScriptedRelay;
use haven_core::relay::{allow_ws_loopback_for_test, NegProbe, RelayManager};
use nostr::nips::nip09::EventDeletionRequest;
use nostr::{
    Alphabet, Event, EventBuilder, EventId, Filter, Keys, Kind, SingleLetterTag, Tag, TagKind,
    Timestamp,
};
use nostr_relay_builder::builder::{RelayBuilder, RelayBuilderNip42, RelayBuilderNip42Mode};
use nostr_sdk::Client;
use rand::rngs::OsRng;
use rand::RngCore;
use vetting::{
    connect, local_relay, probe_read_without_auth, publish, read_back, RefuseEveryWrite, Verdict,
    READBACK_TIMEOUT,
};

use neg_wire::{NegPolicy, NegWire};

const GROUP_EVENT_KIND: Kind = Kind::Custom(445);

/// The content's length: a 12-byte nonce and a ciphertext of the order of a
/// sealed location, so a relay's size limits judge what Haven really sends.
const SEALED_LOCATION_BYTES: usize = 12 + 420;

/// How old a kind-445 must be for L5 to count it.
const RETENTION_EVIDENCE_SECS: u64 = 30 * 24 * 60 * 60;

/// Every verdict for one relay.
#[derive(Debug)]
struct Findings {
    /// L1: a signer-less `#h` read is served.
    read: Verdict,
    /// L2: a location-shaped kind-445 is kept and served back.
    location: Verdict,
    /// L3: a commit-shaped kind-445 is kept and served back.
    commit: Verdict,
    /// L4: Haven's NIP-77 session reports the probe event alone.
    nip77: Verdict,
    /// L5 (informational): a kind-445 older than 30 days is served.
    retention: Verdict,
}

impl Findings {
    fn unreachable(why: &str) -> Self {
        let unknown = || Verdict::Unknown(why.to_string());
        Self {
            read: unknown(),
            location: unknown(),
            commit: unknown(),
            nip77: unknown(),
            retention: unknown(),
        }
    }

    /// L1–L4: what a pool entry must pass. L5 is evidence, not a gate.
    const fn gating(&self) -> [&Verdict; 4] {
        [&self.read, &self.location, &self.commit, &self.nip77]
    }
}

fn random_h() -> [u8; 32] {
    let mut h = [0u8; 32];
    OsRng.fill_bytes(&mut h);
    h
}

fn h_filter(h: &[u8; 32]) -> Filter {
    Filter::new()
        .kind(GROUP_EVENT_KIND)
        .custom_tags(SingleLetterTag::lowercase(Alphabet::H), [hex::encode(h)])
}

/// A kind-445 in the shape Haven sends: `h` only (a commit), or `h` and an
/// `expiration` [`LOCATION_MESSAGE_RETENTION_SECS`] after `created_at` (a
/// location). Signed by `keys`, which the caller makes fresh per event.
fn probe_event(keys: &Keys, h: &[u8; 32], location_shaped: bool) -> Event {
    let mut content = vec![0u8; SEALED_LOCATION_BYTES];
    OsRng.fill_bytes(&mut content);
    let created_at = Timestamp::now();
    let mut tags = vec![Tag::custom(
        TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::H)),
        [hex::encode(h)],
    )];
    if location_shaped {
        tags.push(Tag::expiration(Timestamp::from(
            created_at.as_secs() + LOCATION_MESSAGE_RETENTION_SECS,
        )));
    }
    EventBuilder::new(
        GROUP_EVENT_KIND,
        base64::engine::general_purpose::STANDARD.encode(content),
    )
    .tags(tags)
    .custom_created_at(created_at)
    .sign_with_keys(keys)
    .expect("sign a probe event")
}

/// L4: Haven's own NIP-77 session over `h`'s window at `kept`'s second, which
/// must report `kept` and nothing else.
async fn probe_nip77(url: &str, h: &[u8; 32], kept: &Event) -> Verdict {
    let manager = RelayManager::new();
    let at = kept.created_at.as_secs();
    let verdict = match manager.neg_probe_ids(url, h, at, at).await {
        NegProbe::Ids(ids) if ids.len() == 1 && ids.contains(&kept.id) => Verdict::Pass,
        NegProbe::Ids(ids) if !ids.contains(&kept.id) => {
            Verdict::Fail("relay answered NIP-77 without the probe event".to_string())
        }
        NegProbe::Ids(_) => {
            Verdict::Fail("relay's NIP-77 answer is not the probe event alone".to_string())
        }
        NegProbe::Unsupported => Verdict::Fail("relay refused NIP-77".to_string()),
        NegProbe::NoAnswer => {
            Verdict::Unknown("no NIP-77 answer within Haven's session budget".to_string())
        }
    };
    manager.shutdown().await;
    verdict
}

/// L5: whether the relay serves any kind-445 older than 30 days. Absence is
/// not proof of a short retention, so it is never a failure.
async fn probe_retention(client: &Client, url: &str) -> Verdict {
    let until = Timestamp::from(
        Timestamp::now()
            .as_secs()
            .saturating_sub(RETENTION_EVIDENCE_SECS),
    );
    let filter = Filter::new().kind(GROUP_EVENT_KIND).until(until).limit(1);
    match client
        .fetch_events_from([url], filter, READBACK_TIMEOUT)
        .await
    {
        Ok(events) if events.iter().any(|event| event.created_at <= until) => Verdict::Pass,
        Ok(_) => Verdict::Unknown("served no kind-445 older than 30 days".to_string()),
        Err(e) => Verdict::Unknown(format!(
            "read failed: {}",
            vetting::relay_text(&e.to_string())
        )),
    }
}

/// Runs L1–L5 against one relay.
async fn probe_location_relay(url: &str) -> Findings {
    let client = match connect(url).await {
        Ok(client) => client,
        Err(why) => return Findings::unreachable(&why),
    };

    let read = probe_read_without_auth(&client, url, h_filter(&random_h()).limit(1)).await;

    let location_h = random_h();
    let location = probe_event(&Keys::generate(), &location_h, true);
    let location_verdict = match publish(&client, url, &location).await {
        Ok(()) => read_back(&client, url, &location, h_filter(&location_h)).await,
        Err(verdict) => verdict,
    };

    let commit_keys = Keys::generate();
    let commit_h = random_h();
    let commit = probe_event(&commit_keys, &commit_h, false);
    let commit_published = publish(&client, url, &commit).await;
    let commit_verdict = match &commit_published {
        Ok(()) => read_back(&client, url, &commit, h_filter(&commit_h)).await,
        Err(verdict) => verdict.clone(),
    };

    let nip77 = if commit_verdict.is_pass() {
        probe_nip77(url, &commit_h, &commit).await
    } else if location_verdict.is_pass() {
        probe_nip77(url, &location_h, &location).await
    } else {
        Verdict::Unknown("no probe event was kept to reconcile against".to_string())
    };

    // Best effort, after L4 needed the event: a relay may ignore NIP-09 and
    // keep the commit-shaped event for good, which the vetting doc discloses.
    if !matches!(commit_published, Err(Verdict::Fail(_))) {
        if let Ok(deletion) = EventBuilder::delete(EventDeletionRequest::new().id(commit.id))
            .sign_with_keys(&commit_keys)
        {
            let _ = client.send_event_to([url], &deletion).await;
        }
    }

    let retention = probe_retention(&client, url).await;
    client.shutdown().await;

    Findings {
        read,
        location: location_verdict,
        commit: commit_verdict,
        nip77,
        retention,
    }
}

/// Renders the findings as the Markdown table `docs/LOCATION_RELAY_VETTING.md`
/// carries. Operator and terminator are hand-recorded: no probe can see them.
fn findings_table(findings: &BTreeMap<String, Findings>) -> String {
    let mut out = String::from(
        "| relay | serves #h reads without AUTH | keeps a location-shaped 445 | \
         keeps a commit-shaped 445 | NIP-77 | retention ≥30d | operator | terminator |\n\
         |---|---|---|---|---|---|---|---|\n",
    );
    for (relay, f) in findings {
        let _ = writeln!(
            out,
            "| `{relay}` | {} | {} | {} | {} | {} | fill in | fill in |",
            f.read.cell(),
            f.location.cell(),
            f.commit.cell(),
            f.nip77.cell(),
            f.retention.cell(),
        );
    }
    out
}

// ===========================================================================
// Hermetic self-tests: the probe's own verdict logic, over in-process relays.
//
// The live probe never runs in CI, so nothing else would notice it degrading
// into something that always says "pass". These dial only loopback, run in
// every `cargo test`, and print no relay address.
// ===========================================================================

fn assert_fails_saying(verdict: &Verdict, reason: &str) {
    match verdict {
        Verdict::Fail(why) => assert!(why.contains(reason), "wrong reason: {why}"),
        other => panic!("expected a failure saying {reason:?}, got {other:?}"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn location_probe_passes_a_relay_that_serves_445_reads_and_keeps_both_shapes() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = local_relay(RelayBuilder::default()).await;
    // An old kind-445 on the relay, so L5 can be seen to say yes.
    let seeder = connect(&url).await.expect("loopback relay connects");
    let old = EventBuilder::new(GROUP_EVENT_KIND, "b2xk")
        .custom_created_at(Timestamp::from(
            Timestamp::now().as_secs() - RETENTION_EVIDENCE_SECS - 86_400,
        ))
        .sign_with_keys(&Keys::generate())
        .expect("sign");
    publish(&seeder, &url, &old)
        .await
        .expect("the relay keeps an old kind-445");
    seeder.shutdown().await;

    let findings = probe_location_relay(&url).await;

    assert_eq!(findings.read, Verdict::Pass);
    // Each write passes only on an ack AND a read-back by `#h`.
    assert_eq!(findings.location, Verdict::Pass);
    assert_eq!(findings.commit, Verdict::Pass);
    assert_eq!(findings.nip77, Verdict::Pass);
    assert_eq!(findings.retention, Verdict::Pass);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn location_probe_fails_a_relay_that_refuses_445_writes() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = local_relay(RelayBuilder::default().write_policy(RefuseEveryWrite)).await;

    let findings = probe_location_relay(&url).await;

    // Reads are unaffected, so the failure is attributed to the writes alone.
    assert_eq!(findings.read, Verdict::Pass);
    assert_fails_saying(&findings.location, "restricted");
    assert_fails_saying(&findings.commit, "restricted");
    assert!(
        !findings.nip77.is_pass(),
        "nothing was kept, so NIP-77 cannot have passed"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn location_probe_fails_a_relay_that_acks_445_and_serves_nothing() {
    // Acks every EVENT and answers every REQ with a bare EOSE: the silent drop
    // the read-backs exist for.
    let relay = ScriptedRelay::start();

    let findings = probe_location_relay(relay.url()).await;

    assert_eq!(findings.read, Verdict::Pass);
    assert_fails_saying(&findings.location, "silent drop");
    assert_fails_saying(&findings.commit, "silent drop");
    assert!(!findings.nip77.is_pass());
    let kept: Vec<Event> = relay
        .published()
        .into_iter()
        .filter(|event| event.kind == GROUP_EVENT_KIND)
        .collect();
    assert_eq!(kept.len(), 2, "both shapes reached the relay");
    let expiring = kept
        .iter()
        .filter(|event| event.tags.expiration().is_some())
        .count();
    assert_eq!(expiring, 1, "exactly one shape carries an expiration");
    assert_ne!(
        kept[0].pubkey, kept[1].pubkey,
        "each probe event is signed by a fresh key"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn location_probe_fails_a_relay_that_demands_nip42_auth_on_read() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = local_relay(RelayBuilder::default().nip42(RelayBuilderNip42 {
        mode: RelayBuilderNip42Mode::Read,
    }))
    .await;

    let findings = probe_location_relay(&url).await;

    // Such a relay sends an AUTH challenge AND a CLOSED; the reason has to name
    // AUTH, or the probe stopped recognising the challenge at all.
    assert_fails_saying(&findings.read, "AUTH");
    assert!(findings.gating().iter().any(|verdict| verdict.is_fail()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn location_probe_reports_nip77_support_of_each_kind() {
    let _ = allow_ws_loopback_for_test();
    let (_relay, url) = local_relay(RelayBuilder::default()).await;
    let client = connect(&url).await.expect("loopback relay connects");
    let h = random_h();
    let kept = probe_event(&Keys::generate(), &h, false);
    publish(&client, &url, &kept).await.expect("kept");
    client.shutdown().await;
    let stranger = EventId::all_zeros().to_bytes();

    assert_eq!(probe_nip77(&url, &h, &kept).await, Verdict::Pass);

    let declining = NegWire::in_front_of(
        &url,
        NegPolicy::Notice("ERROR: bad msg: unknown cmd".into()),
    )
    .await;
    assert_fails_saying(&probe_nip77(&declining.url, &h, &kept).await, "refused");

    let silent = NegWire::in_front_of(&url, NegPolicy::Silent).await;
    assert!(matches!(
        probe_nip77(&silent.url, &h, &kept).await,
        Verdict::Unknown(_)
    ));

    let missing = NegWire::in_front_of(&url, NegPolicy::Answer(vec![stranger])).await;
    assert_fails_saying(
        &probe_nip77(&missing.url, &h, &kept).await,
        "without the probe event",
    );

    let padded =
        NegWire::in_front_of(&url, NegPolicy::Answer(vec![kept.id.to_bytes(), stranger])).await;
    assert_fails_saying(
        &probe_nip77(&padded.url, &h, &kept).await,
        "not the probe event alone",
    );
}

#[tokio::test]
#[ignore = "dials the curated location pool (HAVEN_PROBE_LOCATION_RELAYS=1)"]
async fn curated_location_relays_serve_445_reads_keep_both_shapes_and_speak_nip77() {
    if std::env::var("HAVEN_PROBE_LOCATION_RELAYS").is_err() {
        eprintln!(
            "skipping: set HAVEN_PROBE_LOCATION_RELAYS=1 to dial the curated pool. \
             Read docs/LOCATION_RELAY_VETTING.md first."
        );
        return;
    }

    let pool = production_location_relays();
    assert!(!pool.is_empty(), "non-vacuity: the curated pool is empty");

    let mut findings: BTreeMap<String, Findings> = BTreeMap::new();
    for url in &pool {
        eprintln!("probing {url} ...");
        findings.insert(url.clone(), probe_location_relay(url).await);
    }

    let table = findings_table(&findings);
    eprintln!("\n{table}");

    // Report every relay before failing. `unknown` is not a pass: an entry
    // ships only on a pass in all four gating columns.
    let failures: Vec<&String> = findings
        .iter()
        .filter(|(_, f)| f.gating().iter().any(|verdict| !verdict.is_pass()))
        .map(|(relay, _)| relay)
        .collect();
    assert!(
        failures.is_empty(),
        "these curated location relays did not pass every gating criterion and must be \
         re-probed or replaced in PRODUCTION_LOCATION_RELAYS: {failures:?}\n\n{table}",
    );
}
