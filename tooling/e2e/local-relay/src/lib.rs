//! Recording WebSocket proxy for Haven's E2E lanes (Workstream C).
//!
//! # What this is
//!
//! A transparent WebSocket proxy that sits between the app under test and the
//! hermetic Nostr relay (`strfry` on the Android lane, `haven-local-relay` on
//! the iOS lane) and writes an NDJSON **wire journal**: one line per WebSocket
//! message, in both directions, with a globally monotonic `wire_seq`.
//!
//! # Why a proxy and not in-relay hooks
//!
//! In-relay hooks see only what the relay chose to accept and act on — EVENT
//! and REQ — and `strfry` and `LocalRelay` expose different things. The proxy
//! records what was **sent**, which is also why it is immune to NIP-40
//! eviction: an event a relay later drops for expiry was still transmitted,
//! and the transmission is the privacy-relevant fact. (The existing oracle in
//! `e2e_combined.dart` reads events back off the relay late in a 720 s
//! scenario, so application kind-445s — which carry `expiration = created_at +
//! 228` — are routinely gone by the time it looks.)
//!
//! # Fail-open producer, fail-closed oracle
//!
//! The proxy **fails open**: if the journal cannot be opened, cannot be
//! written, or the recorder panics, traffic still flows and the scenario still
//! runs. A privacy instrument that can break the product is worse than no
//! instrument. Every failure latches a "degraded" flag that is reported on
//! stderr once and in the shutdown summary — so a run that recorded nothing
//! says so loudly, and the oracle (which fails CLOSED on an absent, empty or
//! truncated journal) turns that into a red.
//!
//! # This is a privacy hazard — treat it as one
//!
//! The journal contains full event JSON (ciphertext, ephemeral pubkeys, event
//! ids, signatures) and, on the REQ side, filters carrying long-term identity
//! pubkeys. It is TEST-HARNESS ONLY and must never be reachable from
//! `haven/lib` or a release build; `scripts/ci/check_wire_proxy_test_only.sh`
//! enforces that boundary, and also enforces that no workflow uploads the raw
//! journal as an artifact. Use [`summarize`] to produce the redacted,
//! upload-safe transcript instead.

pub mod config;
pub mod frame;
pub mod journal;
pub mod proxy;
pub mod selftest;
pub mod summarize;

/// Default TCP port the proxy listens on.
///
/// Deliberately NOT 7777: the relay keeps that port, so inserting the proxy is
/// a one-line change to a lane's `HAVEN_E2E_RELAY` and nothing about relay
/// startup/teardown moves.
pub const DEFAULT_LISTEN_PORT: u16 = 7788;

/// Default upstream relay the proxy forwards to.
pub const DEFAULT_UPSTREAM: &str = "ws://127.0.0.1:7777";

/// Default journal path.
pub const DEFAULT_JOURNAL_PATH: &str = "/tmp/haven-wire-journal.ndjson";

/// Environment variable naming the listen port.
pub const ENV_LISTEN_PORT: &str = "HAVEN_WIRE_PROXY_PORT";

/// Environment variable naming the upstream relay URL.
pub const ENV_UPSTREAM: &str = "HAVEN_WIRE_PROXY_UPSTREAM";

/// Environment variable naming the journal path.
pub const ENV_JOURNAL: &str = "HAVEN_WIRE_JOURNAL";

/// Environment variable naming a multi-relay routing table
/// (`<listen>=<upstream>,...`). Wins over [`ENV_LISTEN_PORT`] /
/// [`ENV_UPSTREAM`] when set.
pub const ENV_ROUTES: &str = "HAVEN_WIRE_PROXY_ROUTES";
