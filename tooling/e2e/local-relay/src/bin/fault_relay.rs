//! `haven-fault-relay` — the relay-management lane's misbehaving relay. A thin
//! shell over [`haven_local_relay::fault`]; see that module for the modes and
//! the control verbs.
//!
//! Reads its port from `HAVEN_FAULT_PORT` and its mode from `HAVEN_FAULT_MODE`
//! and ignores argv, so the runner's `--haven-fault-relay-instance=<role>`
//! marker (what teardown `pkill -f`s) is inert. Binds loopback only: the
//! emulator reaches it at the host alias `10.0.2.2`.
//!
//! The log is the fixed block below and nothing else: no port, address, frame
//! or count (Security Rule 15). Its seven lines meet the lane's relay line
//! floor (`run-relay-management.sh`, `--floor relay=7`) on their own, and the
//! last of them is the line the runner waits for.

use std::net::{Ipv4Addr, SocketAddr};
use std::process::ExitCode;

use haven_local_relay::fault::{FaultRelay, Mode, ENV_FAULT_MODE, ENV_FAULT_PORT};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> ExitCode {
    let Some(port) = std::env::var(ENV_FAULT_PORT)
        .ok()
        .and_then(|v| v.parse::<u16>().ok())
    else {
        eprintln!("[haven-fault-relay] HAVEN_FAULT_PORT is unset or not a port");
        return ExitCode::from(2);
    };
    let Some(mode) = std::env::var(ENV_FAULT_MODE)
        .ok()
        .and_then(|v| Mode::parse(&v))
    else {
        eprintln!(
            "[haven-fault-relay] HAVEN_FAULT_MODE is unset or not one of store, refuse, drop, stall, blackhole"
        );
        return ExitCode::from(2);
    };
    let Ok(listener) = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await
    else {
        eprintln!("[haven-fault-relay] could not bind its loopback port");
        return ExitCode::from(1);
    };
    let _relay = FaultRelay::start(listener, mode);
    eprintln!("[haven-fault-relay] hermetic fault-injection relay, test harness only");
    eprintln!("[haven-fault-relay] bound to loopback");
    eprintln!("[haven-fault-relay] mode: {}", mode.name());
    eprintln!("[haven-fault-relay] backing store: in memory");
    eprintln!(
        "[haven-fault-relay] control verbs: HAVEN_FAULT_MODE HAVEN_FAULT_WIPE HAVEN_FAULT_OFFERS HAVEN_FAULT_KEPT"
    );
    eprintln!("[haven-fault-relay] this log carries fixed text only, never a frame");
    eprintln!("[haven-fault-relay] listening");
    if tokio::signal::ctrl_c().await.is_err() {
        return ExitCode::from(1);
    }
    eprintln!("[haven-fault-relay] shutting down");
    ExitCode::SUCCESS
}
