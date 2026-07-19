//! Hermetic in-memory Nostr relay for Haven's iOS E2E lane.
//!
//! macOS GitHub runners cannot run the Linux `strfry` Docker container the
//! Android lane uses, so this binary provides an equivalent NIP-01 relay
//! reachable at `ws://127.0.0.1:<port>` (default `7777`). It builds against
//! the same `nostr` 0.44.x line the app uses (patch versions may differ but
//! the wire format is compatible), so there is no wire-format drift between
//! the relay and the system under test. The default in-memory store retains
//! every kind Haven exchanges
//! (0/9/444/445/1059/10002/10050/30443, plus the Dark-Matter-retired
//! 443/10051 that privacy oracles assert stay ABSENT) — none are ephemeral —
//! for the lifetime of the process, which is exactly one CI run.
//!
//! The port can be overridden with `HAVEN_RELAY_PORT`. The process runs until
//! it receives Ctrl-C / SIGTERM (the CI teardown step).

use std::net::{IpAddr, Ipv4Addr};

use nostr_relay_builder::prelude::*;

/// Default listen port. Matches the `ws://localhost:7777` URL the iOS lane
/// injects via `--dart-define=HAVEN_E2E_RELAY`.
const DEFAULT_PORT: u16 = 7777;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port: u16 = std::env::var("HAVEN_RELAY_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    // Bind to loopback only — the relay is reachable from the simulator (which
    // shares the host network namespace) but never exposed off-host.
    let builder = RelayBuilder::default()
        .addr(IpAddr::V4(Ipv4Addr::LOCALHOST))
        .port(port);

    // `run()` binds the listener and spawns the accept loop, then returns;
    // `relay` must stay alive (it owns the serving tasks) until teardown.
    let relay = LocalRelay::new(builder);
    relay.run().await?;

    // stderr (not stdout) so it never pollutes a piped event stream; the CI
    // script greps this line to confirm readiness.
    eprintln!("[haven-local-relay] listening on {}", relay.url().await);

    // Park until the CI teardown signals the process.
    tokio::signal::ctrl_c().await?;
    relay.shutdown();
    eprintln!("[haven-local-relay] shutting down");
    Ok(())
}
