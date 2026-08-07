//! Resolving the proxy's routing table from the environment.
//!
//! Two forms, deliberately:
//!
//! * `HAVEN_WIRE_PROXY_ROUTES` — a comma-separated routing table,
//!   `<listen>=<upstream>`, e.g.
//!   `7788=ws://127.0.0.1:7777,7789=ws://127.0.0.1:7778`. `<listen>` may be a
//!   bare port or a `host:port`.
//! * `HAVEN_WIRE_PROXY_PORT` + `HAVEN_WIRE_PROXY_UPSTREAM` — the single-relay
//!   shorthand every current lane needs.
//!
//! The table form wins when set. Parsing is strict and returns a message
//! naming the offending entry: a lane that mistypes its routing table must
//! fail at startup, not run with a relay silently missing from the journal.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use crate::proxy::{ProxyConfig, Route};
use crate::{DEFAULT_LISTEN_PORT, DEFAULT_UPSTREAM, ENV_LISTEN_PORT, ENV_ROUTES, ENV_UPSTREAM};

/// Reads the routing table from process environment variables.
///
/// # Errors
///
/// Returns a human-readable message when a variable is present but malformed.
pub fn from_env() -> Result<ProxyConfig, String> {
    let table = std::env::var(ENV_ROUTES).ok();
    let port = std::env::var(ENV_LISTEN_PORT).ok();
    let upstream = std::env::var(ENV_UPSTREAM).ok();
    resolve(table.as_deref(), port.as_deref(), upstream.as_deref())
}

/// Pure resolution, so the precedence rules are testable without touching
/// process-global state.
///
/// # Errors
///
/// Returns a human-readable message when an input is present but malformed.
pub fn resolve(
    table: Option<&str>,
    port: Option<&str>,
    upstream: Option<&str>,
) -> Result<ProxyConfig, String> {
    if let Some(table) = table.map(str::trim).filter(|t| !t.is_empty()) {
        return parse_table(table);
    }

    let listen = match port {
        Some(raw) => {
            let trimmed = raw.trim();
            trimmed
                .parse::<u16>()
                .map_err(|_| format!("{ENV_LISTEN_PORT} must be a port number (got '{trimmed}')"))?
        }
        None => DEFAULT_LISTEN_PORT,
    };
    let upstream = upstream
        .map(str::trim)
        .filter(|u| !u.is_empty())
        .unwrap_or(DEFAULT_UPSTREAM);
    validate_upstream(upstream)?;

    Ok(ProxyConfig {
        routes: vec![Route {
            listen: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), listen),
            upstream: upstream.to_owned(),
        }],
    })
}

fn parse_table(table: &str) -> Result<ProxyConfig, String> {
    let mut routes = Vec::new();
    for entry in table.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let (listen_raw, upstream_raw) = entry
            .split_once('=')
            .ok_or_else(|| format!("route '{entry}' is not '<listen>=<upstream>'"))?;
        let listen = parse_listen(listen_raw.trim())
            .ok_or_else(|| format!("route '{entry}' has an unparseable listen address"))?;
        let upstream = upstream_raw.trim();
        validate_upstream(upstream)?;
        routes.push(Route {
            listen,
            upstream: upstream.to_owned(),
        });
    }

    if routes.is_empty() {
        return Err(format!("{ENV_ROUTES} is set but contains no routes"));
    }
    // Two routes on one port would make `listen` ambiguous in the journal and
    // silently drop one relay from the record. Refuse rather than pick.
    for (index, route) in routes.iter().enumerate() {
        if routes[..index].iter().any(|r| r.listen == route.listen) {
            return Err(format!(
                "listen address {} appears in more than one route",
                route.listen
            ));
        }
    }

    Ok(ProxyConfig { routes })
}

fn parse_listen(raw: &str) -> Option<SocketAddr> {
    if let Ok(port) = raw.parse::<u16>() {
        return Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port));
    }
    raw.parse::<SocketAddr>().ok()
}

/// Rejects an upstream that is not a WebSocket URL.
///
/// `wss://` is allowed so the tool is not silently limited, but every lane
/// uses `ws://` loopback; `start-wire-proxy.sh` additionally refuses a
/// non-loopback upstream unless the operator opts in, because a journal
/// mapping traffic to a NAMED REMOTE HOST is a much more sensitive artefact
/// than one mapping it to 127.0.0.1.
fn validate_upstream(upstream: &str) -> Result<(), String> {
    if upstream.starts_with("ws://") || upstream.starts_with("wss://") {
        Ok(())
    } else {
        Err(format!(
            "upstream '{upstream}' must start with ws:// or wss://"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_one_loopback_route() {
        let config = resolve(None, None, None).expect("defaults resolve");
        assert_eq!(config.routes.len(), 1);
        assert_eq!(
            config.routes[0].listen.to_string(),
            format!("127.0.0.1:{DEFAULT_LISTEN_PORT}")
        );
        assert_eq!(config.routes[0].upstream, DEFAULT_UPSTREAM);
        assert_ne!(
            config.routes[0].listen.port(),
            7777,
            "the default listen port must not collide with the relay's, or \
             inserting the proxy would require moving the relay"
        );
    }

    #[test]
    fn single_route_shorthand_is_honoured() {
        let config =
            resolve(None, Some("9000"), Some("ws://127.0.0.1:7779")).expect("shorthand resolves");
        assert_eq!(config.routes.len(), 1);
        assert_eq!(config.routes[0].listen.port(), 9000);
        assert_eq!(config.routes[0].upstream, "ws://127.0.0.1:7779");
    }

    #[test]
    fn a_routing_table_binds_each_relay_to_its_own_port() {
        let config = resolve(
            Some("7788=ws://127.0.0.1:7777, 7789=ws://127.0.0.1:7778"),
            None,
            None,
        )
        .expect("table resolves");
        assert_eq!(config.routes.len(), 2);
        assert_eq!(config.routes[0].listen.port(), 7788);
        assert_eq!(config.routes[0].upstream, "ws://127.0.0.1:7777");
        assert_eq!(config.routes[1].listen.port(), 7789);
        assert_eq!(config.routes[1].upstream, "ws://127.0.0.1:7778");
    }

    #[test]
    fn a_table_wins_over_the_shorthand() {
        let config = resolve(
            Some("1234=ws://127.0.0.1:1"),
            Some("9999"),
            Some("ws://127.0.0.1:2"),
        )
        .expect("table resolves");
        assert_eq!(config.routes.len(), 1);
        assert_eq!(config.routes[0].listen.port(), 1234);
    }

    #[test]
    fn a_host_qualified_listen_address_is_accepted() {
        let config = resolve(Some("127.0.0.1:7788=ws://127.0.0.1:7777"), None, None)
            .expect("host:port resolves");
        assert_eq!(config.routes[0].listen.to_string(), "127.0.0.1:7788");
    }

    // A mistyped routing table must fail at STARTUP. Silently dropping a relay
    // would leave its traffic unrecorded while every oracle still reported
    // green over the relays that did get proxied.
    #[test]
    fn a_malformed_route_is_rejected_by_name() {
        let err = resolve(Some("7788"), None, None).expect_err("missing '=' must fail");
        assert!(err.contains("7788"), "the error must name the entry: {err}");
    }

    #[test]
    fn a_non_websocket_upstream_is_rejected() {
        assert!(resolve(Some("7788=http://127.0.0.1:7777"), None, None).is_err());
        assert!(resolve(None, None, Some("127.0.0.1:7777")).is_err());
    }

    #[test]
    fn a_non_numeric_port_is_rejected() {
        let err = resolve(None, Some("seven"), None).expect_err("bad port must fail");
        assert!(err.contains(ENV_LISTEN_PORT));
    }

    #[test]
    fn a_duplicated_listen_port_is_rejected() {
        let err = resolve(
            Some("7788=ws://127.0.0.1:7777,7788=ws://127.0.0.1:7778"),
            None,
            None,
        )
        .expect_err("duplicate listen must fail");
        assert!(err.contains("more than one route"), "{err}");
    }

    #[test]
    fn an_empty_table_is_rejected_rather_than_falling_back() {
        // A table of only separators is a typo, not a request for defaults —
        // falling back would start a proxy that records the wrong topology.
        assert!(resolve(Some(",,"), None, None).is_err());
    }

    #[test]
    fn a_blank_table_falls_back_to_the_shorthand() {
        let config = resolve(Some("   "), Some("4321"), None).expect("blank table falls back");
        assert_eq!(config.routes[0].listen.port(), 4321);
    }
}
