//! Acquiring loopback addresses, without the probe-then-bind race.
//!
//! # The defect this exists to remove
//!
//! A probe — bind `:0`, read `local_addr().port()`, DROP the listener — hands
//! back a port it does not hold. The port is unowned from the moment the number
//! is returned, so a caller that treats the number as a reservation is wrong
//! rather than unlucky; all that varies is how often something else gets there
//! first. `cargo test` runs the lib target and every integration target as
//! separate multi-threaded processes drawing on one ephemeral range, and when
//! one of them wins, the relay dies with `AddrInUse`.
//!
//! [`LocalRelay::run`] binds its own socket, so a caller cannot hand it a
//! listener it already holds (the pattern `start_echo_upstream` uses, which
//! cannot race) and has nothing to pass but a number.
//!
//! Omitting the port is worse, not better: `nostr-relay-builder`'s fallback
//! (`local/util.rs::find_available_port`) is the same bind-drop-report probe
//! over a random scan of `1024..=65535`, so it relocates the race into a
//! dependency and adds the registered ports to the pool it may pick.
//!
//! # Why a bounded re-acquisition is a fix and not a papered-over flake
//!
//! The window cannot be closed from here, so what is left is to make losing
//! harmless. [`start_local_relay`] takes a port, and if the bind loses it,
//! takes a DIFFERENT one. Nothing a test asserted is re-run — no test has
//! started — so this is acquisition of a contended external resource, not a
//! retry hiding a defect in the code under test. It stays honest by being
//! bounded, by returning every non-contention error (a permission failure, an
//! address that does not exist) untouched on the FIRST attempt, and by failing
//! with a message naming every port that was taken when the bound runs out.

use std::io;
use std::net::{Ipv4Addr, SocketAddr};

// Named imports, not `prelude::*`: the prelude glob-re-exports both
// `nostr::prelude::*` and `crate::*`, and each carries a DIFFERENT `Error`.
// Under a glob the two are ambiguous (a hard error since the
// `ambiguous_glob_imports` future-incompat lint became deny-by-default), and
// the one that wins is not the relay-builder error this matches on.
use nostr_relay_builder::error::Error as RelayBuilderError;
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use tokio::net::TcpSocket;

/// How many ports [`start_local_relay`] will take before giving up.
///
/// Losing one is ordinary under load; losing eight in a row is a host whose
/// ephemeral range is being consumed faster than it can be used, and that is a
/// finding to report rather than to keep spinning on.
const MAX_ACQUISITION_ATTEMPTS: usize = 8;

/// Starts a [`LocalRelay`] on a loopback port, returning it and its `ws://` URL.
///
/// The returned relay owns its serving tasks and stops when dropped.
///
/// # Errors
///
/// Returns the underlying [`io::Error`] unchanged when the bind fails for any
/// reason other than contention, and an `AddrInUse` error naming every
/// contended port when [`MAX_ACQUISITION_ATTEMPTS`] are exhausted.
pub async fn start_local_relay() -> io::Result<(LocalRelay, String)> {
    start_local_relay_at(probe_loopback_addr).await
}

/// [`start_local_relay`], with the address source injected so the lost-port
/// interleaving can be constructed instead of waited for.
async fn start_local_relay_at<F>(mut next_addr: F) -> io::Result<(LocalRelay, String)>
where
    F: FnMut() -> io::Result<SocketAddr>,
{
    let mut taken = Vec::new();
    for _ in 0..MAX_ACQUISITION_ATTEMPTS {
        let addr = next_addr()?;
        // A fresh builder per attempt: `InnerLocalRelay` memoizes its address in
        // a `OnceCell`, so re-running the relay that just lost a port would go
        // straight back to the port it lost.
        let relay = LocalRelay::new(RelayBuilder::default().addr(addr.ip()).port(addr.port()));
        match relay.run().await {
            Ok(()) => {
                let url = relay.url().await.to_string();
                return Ok((relay, url));
            }
            Err(RelayBuilderError::IO(err)) if err.kind() == io::ErrorKind::AddrInUse => {
                taken.push(addr.port());
            }
            Err(RelayBuilderError::IO(err)) => return Err(err),
            Err(other) => return Err(io::Error::other(format!("local relay: {other}"))),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AddrInUse,
        format!(
            "no loopback port survived from probe to bind in {MAX_ACQUISITION_ATTEMPTS} \
             attempts; every one of {taken:?} was taken in between. This host is \
             consuming ephemeral ports faster than they can be used — the relay is \
             not at fault and neither is the test that reported it."
        ),
    ))
}

/// Asks the OS for a free loopback address and releases it.
///
/// The returned address is NOT reserved — only the bind that follows can
/// establish ownership, which is why every caller of this goes through
/// [`start_local_relay_at`] rather than using the number directly.
fn probe_loopback_addr() -> io::Result<SocketAddr> {
    let probe = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))?;
    probe.local_addr()
}

/// A loopback address that REFUSES connections for as long as this value lives.
///
/// A probed-and-released port is the wrong fixture for "nothing is listening
/// here": it is not reserved, so a competitor can take it and answer the
/// connection the test needs refused. This holds a socket that is bound but
/// never listening, which keeps the port out of everyone else's reach while a
/// connection to it is refused by the kernel.
#[derive(Debug)]
pub struct RefusedAddr {
    addr: SocketAddr,
    /// Held, never used: dropping it releases the reservation.
    _socket: TcpSocket,
}

impl RefusedAddr {
    /// Reserves a loopback address.
    ///
    /// # Errors
    ///
    /// Returns the underlying [`io::Error`] if no socket can be created or
    /// bound.
    pub fn reserve() -> io::Result<Self> {
        let socket = TcpSocket::new_v4()?;
        socket.bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))?;
        let addr = socket.local_addr()?;
        Ok(Self {
            addr,
            _socket: socket,
        })
    }

    /// The reserved address.
    #[must_use]
    pub const fn addr(&self) -> SocketAddr {
        self.addr
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The interleaving that reddened CI, constructed rather than waited for:
    /// probe, let the probe release its port, and take it before the relay can.
    fn probe_then_lose_it() -> (SocketAddr, std::net::TcpListener) {
        let addr = probe_loopback_addr().expect("probe");
        let competitor = std::net::TcpListener::bind(addr)
            .expect("a probed port is free the instant the probe returns — that IS the hazard");
        (addr, competitor)
    }

    /// THE MECHANISM, stated as the invariant it breaks: a probe hands back a
    /// port it does not hold. Nothing here is timing-dependent — the port is
    /// unowned from the instant the probe returns, so a competitor takes it
    /// every single time, which is why a caller that treats the number as a
    /// reservation is wrong rather than unlucky.
    #[test]
    fn a_probed_port_carries_no_reservation() {
        let probed = probe_loopback_addr().expect("probe");

        let competitor = std::net::TcpListener::bind(probed)
            .expect("a probed port must be assumed taken, because anyone can take it");
        assert_eq!(
            competitor.local_addr().expect("competitor addr").port(),
            probed.port(),
            "the competitor took the very port the probe reported"
        );

        // The contrast, and the pattern `start_echo_upstream` already uses: a
        // listener that is KEPT owns its port, and its address is therefore
        // safe to hand around.
        let held = std::net::TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
            .expect("bind :0");
        let owned = held.local_addr().expect("held addr");
        assert_eq!(
            std::net::TcpListener::bind(owned)
                .expect_err("a held port must not be takeable")
                .kind(),
            io::ErrorKind::AddrInUse,
        );
    }

    fn port_of(url: &str) -> u16 {
        url.trim_end_matches('/')
            .rsplit(':')
            .next()
            .and_then(|port| port.parse().ok())
            .expect("the relay url ends in a port")
    }

    /// THE regression. Under the forced interleaving the naive pattern dies
    /// with `AddrInUse` — both halves are asserted, because a fix proved
    /// against a hazard that no longer exists on this host proves nothing.
    #[tokio::test]
    async fn a_port_taken_between_probe_and_bind_is_re_acquired() {
        let (lost, _competitor) = probe_then_lose_it();

        let naive = std::net::TcpListener::bind(lost)
            .expect_err("the fixture must actually deny the port to the next binder");
        assert_eq!(
            naive.kind(),
            io::ErrorKind::AddrInUse,
            "the fixture is not reproducing the failure it exists to reproduce"
        );

        let mut first = Some(lost);
        let (relay, url) =
            start_local_relay_at(move || first.take().map_or_else(probe_loopback_addr, Ok))
                .await
                .expect("losing one port must not fail the acquisition");

        assert_ne!(
            port_of(&url),
            lost.port(),
            "the relay reported the port it lost, so its URL is a lie"
        );
        // Reported AND serving: a URL is only worth anything if something
        // answers on it.
        let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port_of(&url)));
        std::net::TcpStream::connect(addr).expect("the relay must be listening on the URL it gave");
        drop(relay);
    }

    /// Bounded, and loud when the bound runs out. An unbounded loop would turn
    /// a host with no free ports into a hang, which is the one failure mode
    /// worse than a red test.
    #[tokio::test]
    async fn an_exhausted_acquisition_fails_by_name_instead_of_spinning() {
        let (lost, _competitor) = probe_then_lose_it();

        let mut attempts = 0usize;
        let err = start_local_relay_at(|| {
            attempts += 1;
            Ok(lost)
        })
        .await
        .expect_err("a port that is never free must not be reported as a running relay");

        assert_eq!(
            attempts, MAX_ACQUISITION_ATTEMPTS,
            "the re-acquisition must stop at its bound"
        );
        assert_eq!(err.kind(), io::ErrorKind::AddrInUse);
        let message = err.to_string();
        assert!(
            message.contains(&lost.port().to_string()),
            "the failure must name the contended port(s): {message}"
        );
        assert!(
            message.contains(&MAX_ACQUISITION_ATTEMPTS.to_string()),
            "...and how hard it tried, or it reads like a one-off: {message}"
        );
    }

    /// A bind that fails for a REAL reason must surface on the first attempt,
    /// with its kind intact. Retrying it would spend the bound turning a
    /// permanent failure into a slow one and then report it as contention.
    #[tokio::test]
    async fn a_bind_failure_that_is_not_contention_is_reported_at_once() {
        // TEST-NET-1 (RFC 5737) is reserved for documentation and is never
        // assigned to an interface, so binding it fails with AddrNotAvailable.
        let unassigned: SocketAddr = "192.0.2.1:0".parse().expect("literal address");

        let mut attempts = 0usize;
        let err = start_local_relay_at(|| {
            attempts += 1;
            Ok(unassigned)
        })
        .await
        .expect_err("an address that does not exist must not yield a relay");

        assert_eq!(attempts, 1, "a real bind failure must not be re-acquired");
        assert_eq!(
            err.kind(),
            io::ErrorKind::AddrNotAvailable,
            "the error kind must reach the caller unchanged, or a permission or \
             configuration failure reads as port contention: {err}"
        );
    }

    /// The dead-upstream fixture: refused, and reserved so it stays refused.
    #[tokio::test]
    async fn a_reserved_address_refuses_connections_and_cannot_be_taken_over() {
        let dead = RefusedAddr::reserve().expect("reserve a loopback address");

        let refused = std::net::TcpStream::connect(dead.addr())
            .expect_err("a reserved address must refuse connections");
        assert_eq!(refused.kind(), io::ErrorKind::ConnectionRefused);

        let taken = std::net::TcpListener::bind(dead.addr())
            .expect_err("a reserved address must not be listenable by anyone else");
        assert_eq!(
            taken.kind(),
            io::ErrorKind::AddrInUse,
            "the reservation is not holding the port, so a competitor could \
             start answering the connection a test needs refused"
        );
    }
}
