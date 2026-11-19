//! A dependency's source, read from the checkout cargo resolved for this crate
//! and only from the one its pin in `scripts/ci/mdk_pins.env` names: a stale
//! copy, or a second crate of the name in the graph, fails here instead of
//! being read. Every extraction is of exactly one match, so a moved anchor
//! fails rather than reading another place.
//!
//! The including binary declares `mod cargo_graph;`; each uses a subset.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

/// The crates.io source, for a registry crate Haven pins no source for.
const CRATES_IO: &str = "registry+https://github.com/rust-lang/crates.io-index";

/// The rust-nostr crate the relay pool lives in.
const RELAY_POOL_PACKAGE: &str = "nostr-relay-pool";

/// Shorter than any source file a test reads: an empty or truncated read fails.
const MIN_FILE_BYTES: usize = 256;

/// The value `name` has in `scripts/ci/mdk_pins.env`, read as the guards read
/// it: by sourcing the file.
pub fn pin(name: &str) -> String {
    let pins = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/ci/mdk_pins.env");
    let out = std::process::Command::new("bash")
        .args(["-c", r#"set -eu; . "$0"; printf '%s' "${!1}""#])
        .arg(&pins)
        .arg(name)
        .output()
        .expect("run bash");
    assert!(out.status.success(), "mdk_pins.env has no `{name}`");
    let value = String::from_utf8(out.stdout).expect("the pin is UTF-8");
    assert!(!value.is_empty(), "`{name}` is empty in mdk_pins.env");
    value
}

/// The directory of the one package named `package` in the graph, which must
/// resolve from `pin`.
pub fn package_dir(package: &str, pin: &str) -> PathBuf {
    let metadata = crate::cargo_graph::host_metadata();
    let named: Vec<&serde_json::Value> = metadata["packages"]
        .as_array()
        .expect("packages")
        .iter()
        .filter(|candidate| candidate["name"] == package)
        .collect();
    let [found] = named.as_slice() else {
        panic!(
            "{} packages named `{package}` in the graph, not one",
            named.len()
        );
    };
    assert_eq!(
        found["source"].as_str(),
        Some(pin),
        "`{package}` resolves from another source than its pin: this would read a copy \
         Haven does not build",
    );
    Path::new(found["manifest_path"].as_str().expect("a manifest path"))
        .parent()
        .expect("the package directory")
        .to_path_buf()
}

/// A crate of MDK's or of rust-nostr's in the graph, read from its pin.
pub struct PinnedLib {
    pub package: String,
    /// The name Rust code spells it with.
    pub lib: String,
    /// Its `lib.rs`.
    pub root: PathBuf,
}

/// Every crate of MDK's and of rust-nostr's in the graph, each one resolved
/// from its pin: a crate from the MDK repository or of rust-nostr's name from
/// any other source, or two crates of one name, fails here instead of being
/// read or skipped.
pub fn pinned_libs() -> Vec<PinnedLib> {
    const MDK_REPO: &str = "git+https://github.com/marmot-protocol/mdk";
    let (mdk, nostr) = (pin("HAVEN_MDK_SOURCE"), pin("HAVEN_NOSTR_SOURCE"));
    let metadata = crate::cargo_graph::host_metadata();
    let mut libs: Vec<PinnedLib> = Vec::new();
    for package in metadata["packages"].as_array().expect("packages") {
        let name = package["name"].as_str().expect("a package name");
        let source = package["source"].as_str().unwrap_or("path");
        let from_mdk = source.starts_with(MDK_REPO);
        let of_nostr = name == "nostr" || name.starts_with("nostr-");
        if !from_mdk && !of_nostr {
            continue;
        }
        assert_eq!(
            source,
            if from_mdk { &mdk } else { &nostr },
            "`{name}` resolves from another source than its pin",
        );
        assert!(
            libs.iter().all(|seen| seen.package != name),
            "two packages named `{name}` in the graph"
        );
        let lib = package["targets"]
            .as_array()
            .expect("targets")
            .iter()
            .find(|target| {
                target["kind"]
                    .as_array()
                    .expect("kinds")
                    .contains(&"lib".into())
            })
            .unwrap_or_else(|| panic!("`{name}` has no lib target"));
        libs.push(PinnedLib {
            package: name.to_owned(),
            lib: lib["name"].as_str().expect("a lib name").to_owned(),
            root: PathBuf::from(lib["src_path"].as_str().expect("a lib path")),
        });
    }
    libs.sort_by(|a, b| a.package.cmp(&b.package));
    libs
}

fn read(path: &Path) -> String {
    let source =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    assert!(
        source.len() >= MIN_FILE_BYTES,
        "{} is {} bytes: not the source a test reads",
        path.display(),
        source.len()
    );
    source
}

/// `file` of the MDK crate `package`.
pub fn mdk_source(package: &str, file: &str) -> String {
    read(&package_dir(package, &pin("HAVEN_MDK_SOURCE")).join(file))
}

/// `path` under the crates directory of the MDK checkout, for a crate of MDK's
/// that Haven may not depend on and so is not in the graph.
pub fn mdk_checkout_source(path: &str) -> String {
    let adapter = package_dir("transport-nostr-adapter", &pin("HAVEN_MDK_SOURCE"));
    read(
        &adapter
            .parent()
            .expect("the MDK crates directory")
            .join(path),
    )
}

/// `file` of the `OpenMLS` crate MDK builds on.
pub fn openmls_source(file: &str) -> String {
    read(&package_dir("openmls", &pin("HAVEN_OPENMLS_SOURCE")).join(file))
}

/// `file` of the rust-nostr relay pool.
pub fn sdk_source(file: &str) -> String {
    read(&package_dir(RELAY_POOL_PACKAGE, &pin("HAVEN_NOSTR_SOURCE")).join(file))
}

/// `file` of a crates.io crate Haven pins no source for.
pub fn registry_source(package: &str, file: &str) -> String {
    read(&package_dir(package, CRATES_IO).join(file))
}

/// Where `needle` is in `source`, which must hold it exactly once.
pub fn the_one(source: &str, needle: &str) -> usize {
    let mut at = source.match_indices(needle).map(|(at, _)| at);
    match (at.next(), at.next()) {
        (Some(only), None) => only,
        (None, _) => panic!("the source no longer holds `{needle}`"),
        (Some(_), Some(_)) => panic!("the source holds `{needle}` more than once"),
    }
}

/// `source` before its one `#[cfg(test)]` module.
pub fn product_half(source: &str) -> &str {
    let product = &source[..the_one(source, "#[cfg(test)]\nmod tests {")];
    assert!(
        product.len() >= MIN_FILE_BYTES,
        "the product half is {} bytes",
        product.len()
    );
    product
}
