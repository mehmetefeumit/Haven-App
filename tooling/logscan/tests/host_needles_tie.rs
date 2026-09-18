//! Ties `tooling/e2e/ci/host-needles.sh` to the harness sources it transcribes.
//!
//! A proxy-less lane declares its needles from that library instead of from a
//! recording proxy, so a constant that drifts from the harness is a lane that
//! searches for a value the app never used — and reports clean. Every constant
//! the library defines is asserted here against the file the value is really
//! read from, verbatim, and the library may define no constant this test does
//! not tie.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

fn read(rel: &str) -> String {
    let path = repo_root().join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// Every `readonly HN_<NAME>=…` line of the library, by name, paired with the
/// literal it carries or [`None`] where the value is DERIVED at source time.
///
/// Literals must stay single-quoted: an unquoted or double-quoted literal would
/// be a value a shell expansion could change between here and the lane. The two
/// offset seeds are the deliberate exception — their value is computed from
/// another constant, which is the whole point of them — so they come back as
/// `None` and [`library_values`] reads what the library actually evaluates to.
fn library_lines() -> BTreeMap<String, Option<String>> {
    let mut out = BTreeMap::new();
    for line in read("tooling/e2e/ci/host-needles.sh").lines() {
        let Some(rest) = line.strip_prefix("readonly HN_") else {
            continue;
        };
        let Some((name, value)) = rest.split_once('=') else {
            continue;
        };
        if name == "SELF_TEST_FIXTURES" {
            continue;
        }
        let literal = value
            .strip_prefix('\'')
            .and_then(|v| v.strip_suffix('\''))
            .map(str::to_owned);
        if literal.is_none() {
            assert!(
                value.starts_with("\"$(hn_seed_with_offset "),
                "HN_{name} is neither a single-quoted literal nor a seed derived \
                 from another constant, got {value:?}"
            );
        }
        out.insert(name.to_owned(), literal);
    }
    out
}

/// The single-quoted constants alone.
fn library_constants() -> BTreeMap<String, String> {
    library_lines()
        .into_iter()
        .filter_map(|(name, literal)| literal.map(|v| (name, v)))
        .collect()
}

/// What the library EVALUATES a constant to, by sourcing it in bash.
///
/// Reading the file text cannot answer this for a derived value, and hard-coding
/// the answer here would put the same arithmetic in two places — which is what
/// deriving it was meant to avoid. Sourcing is safe: the library's bottom block
/// runs only when the file is executed directly.
fn library_values(names: &[&str]) -> Vec<String> {
    let script = format!(
        "set -euo pipefail; source '{}'; printf '%s\\n' {}",
        repo_root().join("tooling/e2e/ci/host-needles.sh").display(),
        names
            .iter()
            .map(|n| format!("\"${{HN_{n}}}\""))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let out = std::process::Command::new("bash")
        .arg("-c")
        .arg(&script)
        .output()
        .expect("bash");
    assert!(
        out.status.success(),
        "sourcing host-needles.sh failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout)
        .expect("utf8")
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The text after `<prefix>` on the first line containing it, up to `<end>`.
fn between<'a>(haystack: &'a str, prefix: &str, end: &str) -> &'a str {
    let line = haystack
        .lines()
        .find(|l| l.contains(prefix))
        .unwrap_or_else(|| panic!("no line contains {prefix:?}"));
    let start = line.find(prefix).expect("prefix") + prefix.len();
    let tail = &line[start..];
    let stop = tail
        .find(end)
        .unwrap_or_else(|| panic!("{end:?} after {prefix:?}"));
    &tail[..stop]
}

fn dart_double(source: &str, name: &str) -> String {
    between(source, &format!("const double {name} = "), ";").to_owned()
}

#[test]
fn every_seed_is_the_harness_seed() {
    let constants = library_constants();
    let dart = read("haven/integration_test/e2e/_lib/test_user.dart");
    for (role, name) in [
        ("alice", "SEED_ALICE"),
        ("bob", "SEED_BOB"),
        ("carol", "SEED_CAROL"),
        ("dave", "SEED_DAVE"),
    ] {
        let fill = between(
            &dart,
            &format!("final Uint8List {role}Seed = Uint8List.fromList(List<int>.filled(32, "),
            "))",
        );
        let byte: u8 = fill
            .parse()
            .unwrap_or_else(|_| panic!("{role}Seed fill {fill:?}"));
        let want = hex::encode([byte; 32]);
        assert_eq!(
            constants[name], want,
            "HN_{name} must be 32 bytes of {byte:#04x}"
        );
    }
}

#[test]
fn every_role_coordinate_is_the_fake_location_service_pair() {
    let constants = library_constants();
    let dart = read("haven/integration_test/e2e/_lib/fake_location_service.dart");
    for (role, name) in [
        ("alice", "COORD_ALICE"),
        ("bob", "COORD_BOB"),
        ("carol", "COORD_CAROL"),
    ] {
        let lat = dart_double(&dart, &format!("{role}FakeLatitude"));
        let lon = dart_double(&dart, &format!("{role}FakeLongitude"));
        assert_eq!(constants[name], format!("{lat},{lon}"), "HN_{name}");
    }
}

#[test]
fn the_canary_constants_are_wire_canaries_verbatim() {
    let constants = library_constants();
    let dart = read("haven/integration_test/e2e/_lib/wire_canaries.dart");
    let lat = dart_double(&dart, "kCanaryLatitude");
    let lon = dart_double(&dart, "kCanaryLongitude");
    assert_eq!(constants["COORD_CANARY"], format!("{lat},{lon}"));
    let stem = between(&dart, "const String kCanaryStem = '", "'");
    // The minted names are `'$kCanaryStem CIRCLE ${token()}'` and
    // `'$kCanaryStem PETNAME ${token()}'`: the stem is everything before the
    // token, trailing space included.
    let circle = between(&dart, "circleDisplayName: '$kCanaryStem", "${token()}'");
    let petname = between(&dart, "petname: '$kCanaryStem", "${token()}'");
    assert_eq!(constants["CIRCLE_NAME_STEM"], format!("{stem}{circle}"));
    assert_eq!(constants["PETNAME_STEM"], format!("{stem}{petname}"));
}

#[test]
fn every_lane_coordinate_is_the_lane_s_own_value() {
    let constants = library_constants();
    let b3 = read(".github/workflows/e2e-real-gps.yml");
    assert_eq!(
        constants["COORD_B3"],
        format!(
            "{},{}",
            between(&b3, "HAVEN_B3_GEO_LAT: \"", "\""),
            between(&b3, "HAVEN_B3_GEO_LON: \"", "\"")
        )
    );
    let b4 = read(".github/workflows/e2e-ios-real-gps.yml");
    assert_eq!(
        constants["COORD_B4"],
        format!(
            "{},{}",
            between(&b4, "HAVEN_B4_GEO_LAT: \"", "\""),
            between(&b4, "HAVEN_B4_GEO_LON: \"", "\"")
        )
    );
    let b1 = read("tooling/e2e/ci/run-b1-fgs-publish.sh");
    assert_eq!(
        constants["COORD_B1"],
        format!(
            "{},{}",
            between(&b1, "readonly GEO_LAT=\"${B1_GEO_LAT:-", "}\""),
            between(&b1, "readonly GEO_LON=\"${B1_GEO_LON:-", "}\"")
        )
    );
}

#[test]
fn the_library_defines_exactly_the_tied_constants() {
    let lines = library_lines();
    let names: Vec<&str> = lines.keys().map(String::as_str).collect();
    assert_eq!(
        names,
        [
            "CIRCLE_NAME_STEM",
            "COORD_ALICE",
            "COORD_B1",
            "COORD_B3",
            "COORD_B4",
            "COORD_BOB",
            "COORD_CANARY",
            "COORD_CAROL",
            "PETNAME_STEM",
            "SEED_ALICE",
            "SEED_BOB",
            "SEED_BOB_OFFSET1",
            "SEED_BOB_OFFSET2",
            "SEED_CAROL",
            "SEED_DAVE",
        ],
        "a new HN_ constant needs a tie to its source here"
    );
    // …and exactly these two are derived rather than written down. A literal
    // that became derived, or a derived value quietly replaced by typed hex,
    // changes which half of this file ties it.
    let derived: Vec<&str> = lines
        .iter()
        .filter(|(_, literal)| literal.is_none())
        .map(|(name, _)| name.as_str())
        .collect();
    assert_eq!(derived, ["SEED_BOB_OFFSET1", "SEED_BOB_OFFSET2"]);
}

/// The offset seeds follow the harness's own offset rule, for exactly the
/// offsets a host-profile scenario passes.
///
/// Three things have to agree, and this test fails if any one of them moves:
/// the Dart arithmetic (`synthetic_user.dart`'s `_seedWithOffset`), the bash
/// derivation (`host-needles.sh`'s `hn_seed_with_offset`, read by sourcing it),
/// and the set of offsets the host-profile scenario actually mints
/// (`relay_customization_publish_test.dart`'s `seedOffset:` arguments). A new
/// offset there fails here until the library declares a seed for it — which is
/// the point: an undeclared offset pubkey is searched for by no needle.
#[test]
fn the_offset_seeds_follow_the_dart_offset_rule() {
    // 1. The Dart rule, asserted as the statement it is rather than assumed.
    let dart = read("haven/integration_test/e2e/_lib/synthetic_user.dart");
    assert!(
        dart.contains("seed[seed.length - 1] = (seed[seed.length - 1] + offset) & 0xFF;"),
        "the offset rule is no longer `last byte + offset mod 256`; the bash \
         derivation in host-needles.sh must move with it"
    );
    assert!(
        dart.contains("if (offset == 0) return base;"),
        "offset 0 must still be the base seed unchanged"
    );

    // 2. The offsets the HOST-profile scenario mints, read from it.
    let scenario = read("haven/integration_test/relay_customization_publish_test.dart");
    let mut offsets: Vec<u16> = scenario
        .split("seedOffset: ")
        .skip(1)
        .map(|tail| {
            tail.chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .expect("a numeric seedOffset")
        })
        .collect();
    offsets.sort_unstable();
    offsets.dedup();
    assert_eq!(
        offsets,
        [1, 2],
        "the host-profile scenario's offsets changed; host-needles.sh must \
         declare a seed for each one"
    );

    // 3. The library's evaluated values equal the base seed with its trailing
    //    byte shifted — computed here from HN_SEED_BOB, never transcribed.
    let base = library_constants()["SEED_BOB"].clone();
    let mut bytes = hex::decode(&base).expect("HN_SEED_BOB is hex");
    assert_eq!(bytes.len(), 32, "a seed is 32 bytes");
    let last = *bytes.last().expect("32 bytes");
    let names: Vec<String> = offsets
        .iter()
        .map(|o| format!("SEED_BOB_OFFSET{o}"))
        .collect();
    let got = library_values(&names.iter().map(String::as_str).collect::<Vec<_>>());
    for (i, offset) in offsets.iter().enumerate() {
        let shifted = u8::try_from(u16::from(last).wrapping_add(*offset) & 0xFF).expect("a byte");
        *bytes.last_mut().expect("32 bytes") = shifted;
        assert_eq!(
            got[i],
            hex::encode(&bytes),
            "HN_{} must be HN_SEED_BOB with its last byte +{offset}",
            names[i]
        );
        // The leading 31 bytes are untouched, which is what keeps the seed
        // recognisably Bob's family and the derivation auditable by eye.
        assert_eq!(got[i][..62], base[..62], "HN_{}", names[i]);
        assert_ne!(got[i], base, "HN_{} must differ from the base", names[i]);
    }
}

/// Which integration scenarios mint an OFFSET identity, and whether their lane
/// can declare it.
///
/// `SyntheticUser.bob(relay, seedOffset: n)` bumps the trailing seed byte
/// (`synthetic_user.dart`'s `_seedWithOffset`), so the derived pubkey shares
/// nothing with the base one. On a **proxy** lane that is harmless: the drive
/// declares every identity it mints over the control channel. On a **host**
/// lane the declaration IS `host-needles.sh`, so an offset seed it does not
/// carry is searched for by no needle, and only the structural rules (a 64-hex
/// run, an `npub`) stand between that pubkey and an uploaded log.
///
/// Pinned by equality rather than forbidden outright, because one host lane
/// does it today and pretending otherwise would be the vacuous half of a guard.
/// That lane's two offsets ARE declared now — `HN_SEED_BOB_OFFSET1/2`, tied to
/// the Dart rule by [`the_offset_seeds_follow_the_dart_offset_rule`], which also
/// fails if the scenario reaches for a THIRD offset. This test is the other
/// half: a NEW host-profile FILE reaching for `seedOffset` fails here, and has
/// two honest ways out — use the base identity, or declare the offset seed in
/// the library so the value is searched like any other.
#[test]
fn only_a_declaring_lane_mints_an_offset_identity() {
    // Derived from the workflows, never restated: a lane is `proxy` only where
    // it says so, so a lane that loses its recorder moves itself into the
    // stricter half of this pin instead of drifting out of it.
    let mut proxy_lanes: Vec<String> = Vec::new();
    let workflows = repo_root().join(".github/workflows");
    let mut entries: Vec<PathBuf> = std::fs::read_dir(&workflows)
        .expect("workflows")
        .map(|e| e.expect("entry").path())
        .collect();
    entries.sort();
    for path in entries {
        let text = std::fs::read_to_string(&path).expect("workflow");
        if text.contains("HAVEN_LOGSCAN_PROFILE: proxy") {
            proxy_lanes.push(
                path.file_name()
                    .expect("name")
                    .to_string_lossy()
                    .into_owned(),
            );
        }
    }
    assert_eq!(
        proxy_lanes,
        ["e2e-android.yml", "e2e-ios.yml"],
        "the recording lanes are the only ones that can declare a minted identity"
    );

    // Every `.dart` under haven/integration_test/ that PASSES a `seedOffset:`
    // argument. The library's own `int seedOffset = 0` parameter and its doc
    // references carry no colon, so they are not call sites.
    let root = repo_root().join("haven/integration_test");
    let mut callers: Vec<String> = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(&dir)
            .expect("integration_test dir")
            .map(|e| e.expect("entry").path())
            .collect();
        entries.sort();
        for path in entries {
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "dart")
                && std::fs::read_to_string(&path)
                    .expect("dart source")
                    .contains("seedOffset:")
            {
                callers.push(
                    path.strip_prefix(&root)
                        .expect("under root")
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
    }
    callers.sort();
    assert_eq!(
        callers,
        [
            // Proxy profile (e2e-android.yml, e2e-ios.yml): every identity this
            // drive mints is declared over the channel, offset included.
            "e2e/e2e_combined.dart",
            // HOST profile (e2e-relay-customization.yml). Its two offset Bobs
            // (`seedOffset: 1`, `seedOffset: 2`) are derived from the canonical
            // Bob seed by a rule the host knows, so host-needles.sh declares
            // them and that lane's logs ARE searched for both pubkeys.
            "relay_customization_publish_test.dart",
        ],
        "a host-profile FILE minting an offset identity must declare its seeds"
    );
}
