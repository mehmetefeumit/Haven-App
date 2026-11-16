//! The inbox seed against the dated record of which public relays serve
//! kind-1059 reads to a client that does not authenticate
//! (`fixtures/relay_read_gating_2026-11-16.json`).
//!
//! An inviter delivers a Welcome to the invitee's inbox relays; Haven never
//! answers NIP-42 (Security Rule 16), so a seeded inbox relay that takes the
//! gift wrap but gates reading it back strands every invitation sent there.
//! CI must not dial public relays, so this holds the RECORD and the CONSTANTS
//! together: re-seeding with an unprobed relay, or one the record shows
//! gating gift-wrap reads, is a red test. No network.

use haven_core::circle::{PRODUCTION_DEFAULT_RELAYS, PRODUCTION_INBOX_RELAYS};
use serde_json::Value;

const RECORD: &str = include_str!("fixtures/relay_read_gating_2026-11-16.json");

/// Every kind the inbox seed and the account seed depend on a relay serving.
const KINDS: [&str; 5] = ["1059", "4", "30443", "10002", "10050"];

fn record() -> Vec<Value> {
    let record: Value = serde_json::from_str(RECORD).expect("the record is JSON");
    assert_eq!(record["probed_on"], "2026-11-16");
    assert!(
        record["method"].as_str().is_some_and(|m| !m.is_empty()),
        "the record says how it was taken"
    );
    record["relays"]
        .as_array()
        .expect("the record lists relays")
        .clone()
}

/// The observation of `url`, or `None` when the record never probed it.
fn observation<'a>(record: &'a [Value], url: &str) -> Option<&'a Value> {
    record.iter().find(|relay| relay["url"] == url)
}

fn result<'a>(relay: &'a Value, kind: &str) -> &'a str {
    relay["kinds"][kind]
        .as_str()
        .unwrap_or_else(|| panic!("kind {kind} was not recorded for {}", relay["url"]))
}

#[test]
fn every_observation_records_every_kind_as_served_or_gated() {
    let record = record();
    assert!(!record.is_empty(), "non-vacuity: the record holds relays");
    for relay in &record {
        assert!(relay["software"].is_string() && relay["version"].is_string());
        for kind in KINDS {
            let seen = result(relay, kind);
            assert!(
                seen == "served" || seen == "gated",
                "{} kind {kind}: unknown result {seen}",
                relay["url"]
            );
        }
    }
}

#[test]
fn every_inbox_seed_relay_was_probed_and_serves_gift_wrap_reads() {
    let record = record();
    assert!(!PRODUCTION_INBOX_RELAYS.is_empty(), "non-vacuity");
    for url in PRODUCTION_INBOX_RELAYS {
        let relay = observation(&record, url)
            .unwrap_or_else(|| panic!("inbox seed relay {url} has no recorded probe"));
        assert_eq!(
            result(relay, "1059"),
            "served",
            "inbox seed relay {url} gates kind-1059 reads: Welcomes sent there are never read"
        );
        assert_eq!(result(relay, "10050"), "served", "{url} kind 10050");
    }
}

/// One relay implementation's default config must not be able to gate every
/// seeded inbox at once: strfry's current default gates kind-1059 reads.
#[test]
fn the_inbox_seed_spans_more_than_one_relay_implementation() {
    let record = record();
    let software: std::collections::BTreeSet<&str> = PRODUCTION_INBOX_RELAYS
        .iter()
        .map(|url| {
            observation(&record, url)
                .and_then(|relay| relay["software"].as_str())
                .unwrap_or_else(|| panic!("inbox seed relay {url} has no recorded software"))
        })
        .collect();
    assert!(
        software.len() >= 2,
        "every inbox seed relay runs the same software: {software:?}"
    );
}

#[test]
fn every_account_seed_relay_was_probed_and_serves_the_account_plane() {
    let record = record();
    for url in PRODUCTION_DEFAULT_RELAYS {
        let relay = observation(&record, url)
            .unwrap_or_else(|| panic!("account seed relay {url} has no recorded probe"));
        for kind in ["30443", "10002", "10050"] {
            assert_eq!(result(relay, kind), "served", "{url} kind {kind}");
        }
    }
}

/// The record cannot be emptied, or the gated relay quietly re-marked, to let
/// a gated relay back into the inbox seed: the observation that justified the
/// exclusion is pinned, and every relay the record shows gating is out of the
/// inbox seed.
#[test]
fn the_record_still_shows_the_relay_the_inbox_seed_excludes_gating_gift_wrap_reads() {
    let record = record();
    let damus = observation(&record, "wss://relay.damus.io")
        .expect("the probe that excluded relay.damus.io is kept");
    assert_eq!(result(damus, "1059"), "gated");
    assert_eq!(result(damus, "4"), "gated");
    assert_eq!(
        damus["closed_message"], "ERROR: auth-required: requested filter requires authentication",
        "the relay's exact refusal, as a client sees it"
    );

    let gated: Vec<&str> = record
        .iter()
        .filter(|relay| result(relay, "1059") == "gated")
        .map(|relay| relay["url"].as_str().expect("a relay has a URL"))
        .collect();
    assert!(!gated.is_empty(), "non-vacuity: the record shows a gate");
    for url in gated {
        assert!(
            !PRODUCTION_INBOX_RELAYS.contains(&url),
            "{url} gates gift-wrap reads and must not be an inbox seed relay"
        );
    }
}
