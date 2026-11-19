//! The bounds the rig writes as literals, re-derived from the constants they
//! cite.
//!
//! `pool_reconnect`, `withheld_publish_ladder`, `location_publish_window`,
//! `profile_offer` and `key_package_round_trip` are literals because the
//! constants behind them are private to `nostr-relay-pool` and to haven-core's
//! relay manager. Here those constants are read as VALUES from the sources
//! this root builds — the relay pool from the graph cargo resolved for this
//! root, on its pin — and each bound is computed from them, so a constant that
//! moves, or vanishes, fails here instead of leaving a liveness bound wrong.

use std::path::{Path, PathBuf};
use std::time::Duration;

use haven_soak::oracle::bounds;

/// The value `name` has in `scripts/ci/mdk_pins.env`, read by sourcing it.
fn pin(name: &str) -> String {
    let pins = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/ci/mdk_pins.env");
    let out = std::process::Command::new("bash")
        .args(["-c", r#"set -eu; . "$0"; printf '%s' "${!1}""#])
        .arg(&pins)
        .arg(name)
        .output()
        .expect("run bash");
    assert!(out.status.success(), "mdk_pins.env lacks the pin");
    String::from_utf8(out.stdout).expect("the pin is UTF-8")
}

/// The source directory of the one `package` this root's graph holds, which
/// must resolve from `source`. Read for the host alone: the whole graph also
/// needs every other platform's crates, which a cache filled by building for
/// the host lacks.
fn package_dir(package: &str, source: &str) -> PathBuf {
    let version = std::process::Command::new(env!("CARGO"))
        .arg("-vV")
        .output()
        .expect("run cargo -vV");
    let version = String::from_utf8(version.stdout).expect("cargo -vV is UTF-8");
    let host = version
        .lines()
        .find_map(|line| line.strip_prefix("host: "))
        .expect("cargo names its host");
    let out = std::process::Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--offline"])
        .args(["--filter-platform", host])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("run cargo metadata");
    assert!(out.status.success(), "cargo metadata failed");
    let metadata: serde_json::Value = serde_json::from_slice(&out.stdout).expect("metadata JSON");
    let named: Vec<&serde_json::Value> = metadata["packages"]
        .as_array()
        .expect("packages")
        .iter()
        .filter(|candidate| candidate["name"] == package)
        .collect();
    let [found] = named.as_slice() else {
        panic!("not exactly one package of the name in this root's graph");
    };
    assert_eq!(
        found["source"].as_str(),
        Some(source),
        "the package is off its pin"
    );
    Path::new(found["manifest_path"].as_str().expect("a manifest path"))
        .parent()
        .expect("the package directory")
        .to_path_buf()
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).expect("read a source file")
}

/// The text after `const NAME: TYPE = ` up to its `;`, for the one
/// declaration of `name`, at any visibility. A failure points at the caller's
/// line, which names the constant.
#[track_caller]
fn constant<'a>(source: &'a str, name: &str, ty: &str) -> &'a str {
    let needle = format!("const {name}: {ty} = ");
    let found: Vec<&str> = source
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            let rest = line
                .strip_prefix("pub(super) ")
                .or_else(|| line.strip_prefix("pub(crate) "))
                .or_else(|| line.strip_prefix("pub "))
                .unwrap_or(line);
            rest.strip_prefix(&needle)
        })
        .collect();
    let [value] = found.as_slice() else {
        panic!("not exactly one declaration of the constant");
    };
    value
        .strip_suffix(';')
        .expect("the declaration ends on its line")
}

#[track_caller]
fn secs(source: &str, name: &str) -> Duration {
    let value = constant(source, name, "Duration");
    let digits = value
        .strip_prefix("Duration::from_secs(")
        .and_then(|rest| rest.strip_suffix(')'))
        .expect("the constant is whole seconds");
    Duration::from_secs(digits.replace('_', "").parse().expect("seconds"))
}

#[track_caller]
fn number(source: &str, name: &str) -> u32 {
    constant(source, name, "u32")
        .replace('_', "")
        .parse()
        .expect("a whole number")
}

#[test]
fn the_pool_reconnect_bound_is_the_relay_pools_own_constants() {
    let pool = read(
        &package_dir("nostr-relay-pool", &pin("HAVEN_NOSTR_SOURCE")).join("src/relay/constants.rs"),
    );
    let jitter = constant(&pool, "JITTER_RANGE", "RangeInclusive<i8>");
    let (_, high) = jitter
        .split_once("..=")
        .expect("JITTER_RANGE is an inclusive range");
    let high: u64 = high.parse().expect("the jitter's upper end");
    assert_eq!(
        bounds::pool_reconnect(),
        secs(&pool, "MAX_RETRY_INTERVAL")
            + Duration::from_secs(high)
            + secs(&pool, "DEFAULT_CONNECTION_TIMEOUT"),
        "MAX_RETRY_INTERVAL + max(JITTER_RANGE) + DEFAULT_CONNECTION_TIMEOUT"
    );
}

#[test]
fn the_publish_bounds_are_the_relay_managers_own_constants() {
    let manager =
        read(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../haven-core/src/relay/manager.rs"));
    let attempts = number(&manager, "MAX_PUBLISH_ATTEMPTS");
    let timeout = secs(&manager, "DEFAULT_TIMEOUT");
    let backoff = secs(&manager, "PUBLISH_RETRY_BACKOFF");
    let connect = secs(&manager, "CONNECTION_TIMEOUT");
    assert_eq!(
        bounds::withheld_publish_ladder(),
        timeout * attempts + backoff * (attempts - 1)
    );
    assert_eq!(
        bounds::location_publish_window(),
        secs(&manager, "LOCATION_ACK_WINDOW") * number(&manager, "LOCATION_PUBLISH_ATTEMPTS")
    );
    assert_eq!(
        bounds::profile_offer(),
        connect + secs(&manager, "PROFILE_PUBLISH_ACK_TIMEOUT")
    );
    assert_eq!(
        bounds::key_package_round_trip(),
        (connect + timeout) * attempts + backoff * (attempts - 1) + connect + timeout
    );
}
