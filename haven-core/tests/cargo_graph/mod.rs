//! The dependency graph cargo resolved for this crate, read offline.

/// `cargo metadata` for the host alone: the whole graph also needs every other
/// platform's crates, which a cache filled by building the tests for the host
/// lacks.
pub fn host_metadata() -> serde_json::Value {
    let version = std::process::Command::new(env!("CARGO"))
        .arg("-vV")
        .output()
        .expect("run cargo -vV");
    let version = String::from_utf8(version.stdout).expect("cargo -vV is UTF-8");
    let host = version
        .lines()
        .find_map(|line| line.strip_prefix("host: "))
        .expect("cargo names its host");
    let metadata = std::process::Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--offline"])
        .args(["--filter-platform", host])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("run cargo metadata");
    assert!(metadata.status.success(), "cargo metadata failed");
    serde_json::from_slice(&metadata.stdout).expect("cargo metadata JSON")
}
