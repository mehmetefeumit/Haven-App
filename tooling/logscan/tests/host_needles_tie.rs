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

/// Every `readonly HN_<NAME>='<value>'` line of the library, by name.
fn library_constants() -> BTreeMap<String, String> {
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
        let value = value
            .strip_prefix('\'')
            .and_then(|v| v.strip_suffix('\''))
            .unwrap_or_else(|| panic!("HN_{name} must be a single-quoted literal, got {value:?}"));
        out.insert(name.to_owned(), value.to_owned());
    }
    out
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
    let constants = library_constants();
    let names: Vec<&str> = constants.keys().map(String::as_str).collect();
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
            "SEED_CAROL",
            "SEED_DAVE",
        ],
        "a new HN_ constant needs a tie to its source here"
    );
}
