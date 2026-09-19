//! Every field the rig renders carries a privacy CLASS, and this is where that
//! is proven.
//!
//! A name allowlist is not enough: a field called `epoch` passes one and is
//! still an identifier. So every leaf of every record — the timeline, the
//! schedule file and the banner — is classified `tag`, `bucket`, `delta`,
//! `duration`, `measurement` or `literal`, and this test asserts BOTH halves:
//! a rendered leaf whose path is not in the table fails (a field was added and
//! nobody classified it), and a table entry no sample reaches fails (a field was
//! removed and its class is now a comment).
//!
//! The classes mean:
//!
//! * **tag** — one of the rig's own handles (`simdev#3`), which name nothing
//!   outside this process;
//! * **bucket** — a magnitude of the world's behaviour, rendered through
//!   haven-core's own bucket policy;
//! * **delta** — a count from the world's origin: a tick, an epoch distance.
//!   Never an absolute epoch and never an instant;
//! * **duration** — a measured span in milliseconds;
//! * **measurement** — a measured wall time or resident size, in the banner;
//! * **literal** — a string constant from this crate, or a value drawn from one
//!   of its own closed vocabularies.

use std::collections::BTreeSet;
use std::time::Duration;

use haven_soak::banner::{Banner, Measured, Provenance};
use haven_soak::nemesis::types::{ClosedPrefix, DeviceOp, Fault, Op, Schedule, ScheduledOp};
use haven_soak::profiles::ProfileName;
use haven_soak::rig::{DeviceTag, KillKind, RelayTag, TimelineRecord};

/// Every field this rig renders, across all three surfaces.
///
/// Pinned by equality and asserted below: a table whose length can drift is a
/// table that can lose a field's class without anything saying so.
const CLASSIFIED_FIELDS: usize = 42;

/// What a moved pin means, kept as a constant so the assertion below stays on
/// one line: the guard that requires this pin to be ASSERTED reads the
/// assertion and its name together.
const PIN_MOVED: &str =
    "the number of classified fields moved; classify the new one or delete its row";

/// What a duplicated row means.
const PIN_DUPLICATED: &str =
    "one field is classified twice, so one of the two classes is never checked";

/// What a field is allowed to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    /// One of the rig's own handles.
    Tag,
    /// A bucketed magnitude.
    Bucket,
    /// A count from the world's origin.
    Delta,
    /// A measured span, in milliseconds.
    DurationMs,
    /// A measured wall time or resident size.
    Measurement,
    /// A constant from this crate, or a value from one of its vocabularies.
    Literal,
}

/// Which rendered surface a field belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Surface {
    /// `soak-timeline-<seed>.log`, one NDJSON record per line.
    Timeline,
    /// `schedule.log`, written before the first tick.
    Schedule,
    /// `banner.log`, written before the run and again with its measurements.
    Banner,
}

/// The table: one row per rendered field.
fn table() -> Vec<(Surface, &'static str, Class)> {
    use Class::{Bucket, Delta, DurationMs, Literal, Measurement, Tag};
    use Surface::{Banner as B, Schedule as S, Timeline as T};
    vec![
        // The timeline's records.
        (T, "record", Literal),
        (T, "tick", Delta),
        (T, "heal_at_tick", Delta),
        (T, "op", Literal),
        (T, "op.fault.relay", Tag),
        (T, "op.fault.fault", Literal),
        (T, "op.fault.fault.closed", Literal),
        (T, "op.fault.fault.notice", Literal),
        (T, "op.device.device", Tag),
        (T, "op.device.op", Literal),
        (T, "op.device.op.restart", Literal),
        (T, "op.device.op.step-policy-offset.secs", Delta),
        (T, "device", Tag),
        (T, "kind", Literal),
        (T, "release_ms", DurationMs),
        (T, "reopen_ms", DurationMs),
        (T, "outcome", Literal),
        (T, "witness_ms", DurationMs),
        (T, "events", Bucket),
        (T, "relay", Tag),
        (T, "attempts", Bucket),
        (T, "wait_ms", DurationMs),
        // The schedule file.
        (S, "schedule_tag", Tag),
        (S, "ops.tick", Delta),
        (S, "ops.heal_at", Delta),
        (S, "ops.op", Literal),
        (S, "ops.op.fault.relay", Tag),
        (S, "ops.op.fault.fault", Literal),
        (S, "ops.op.fault.fault.closed", Literal),
        (S, "ops.op.fault.fault.notice", Literal),
        (S, "ops.op.device.device", Tag),
        (S, "ops.op.device.op", Literal),
        (S, "ops.op.device.op.restart", Literal),
        (S, "ops.op.device.op.step-policy-offset.secs", Delta),
        // The banner.
        (B, "profile", Literal),
        (B, "seed", Literal),
        (B, "commit", Literal),
        (B, "rustc", Literal),
        (B, "schedule", Tag),
        (B, "rc_names", Literal),
        (B, "wall", Measurement),
        (B, "peak_rss", Measurement),
    ]
}

/// The closed vocabularies a `literal` field may draw from.
///
/// Every one of them is a constant in this crate: an op label, a kill kind, a
/// publish outcome, a record kind, a machine-readable prefix, a profile name or
/// one of the banner's own words. A value outside them is a string somebody
/// else composed, which is exactly what Rule 15 keeps out of a rendered file.
fn vocabulary() -> BTreeSet<String> {
    let mut words = BTreeSet::new();
    for kind in [
        "scheduled",
        "applied",
        "healed",
        "restarted",
        "published",
        "rebound",
    ] {
        words.insert(kind.to_owned());
    }
    for label in [
        "down",
        "up",
        "wipe-store",
        "closed",
        "notice",
        "swallow-ok",
        "double-every-event",
        "reverse-pages",
        "eose-for-another-subscription",
        "heal",
        "probe",
        "restart-soft",
        "restart-hard",
        "go-offline",
        "come-online",
        "step-policy-offset",
    ] {
        words.insert(label.to_owned());
    }
    for kind in [KillKind::Soft, KillKind::Hard] {
        words.insert(kind.label().to_owned());
    }
    for prefix in ClosedPrefix::ALL {
        // The serialised spelling is the kebab-case variant name, which is the
        // wire prefix without its colon.
        words.insert(prefix.as_str().trim_end_matches(':').to_owned());
    }
    for outcome in ["confirmed", "rolled-back"] {
        words.insert(outcome.to_owned());
    }
    for profile in ProfileName::ALL {
        words.insert(profile.as_str().to_owned());
    }
    words.insert(NOTICE.to_owned());
    words
}

/// The notice text the samples carry. A literal from this test, standing in for
/// the literals the scenarios define.
const NOTICE: &str = "haven-soak sample notice";

/// One rendered field: where it came from, its path and its rendered value.
struct Rendered {
    surface: Surface,
    path: String,
    value: serde_json::Value,
}

/// Every record shape the timeline can carry.
fn records() -> Vec<TimelineRecord> {
    vec![
        TimelineRecord::Scheduled {
            tick: 4,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Down,
            },
            heal_at_tick: Some(9),
        },
        TimelineRecord::Scheduled {
            tick: 5,
            op: Op::Fault {
                relay: RelayTag::new(1),
                fault: Fault::Closed(ClosedPrefix::RateLimited),
            },
            heal_at_tick: None,
        },
        TimelineRecord::Scheduled {
            tick: 6,
            op: Op::Fault {
                relay: RelayTag::new(1),
                fault: Fault::Notice(NOTICE),
            },
            heal_at_tick: Some(8),
        },
        TimelineRecord::Applied {
            tick: 7,
            op: Op::Device {
                device: DeviceTag::new(2),
                op: DeviceOp::Restart(KillKind::Hard),
            },
        },
        TimelineRecord::Applied {
            tick: 8,
            op: Op::Device {
                device: DeviceTag::new(2),
                op: DeviceOp::StepPolicyOffset { secs: 288 },
            },
        },
        TimelineRecord::Applied {
            tick: 9,
            op: Op::Probe,
        },
        TimelineRecord::Applied {
            tick: 10,
            op: Op::Device {
                device: DeviceTag::new(2),
                op: DeviceOp::GoOffline,
            },
        },
        TimelineRecord::Healed {
            tick: 10,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::SwallowOk,
            },
        },
        TimelineRecord::Restarted {
            tick: 11,
            device: DeviceTag::new(1),
            kind: KillKind::Soft,
            release_ms: 40,
            reopen_ms: 90,
        },
        TimelineRecord::Published {
            tick: 12,
            device: DeviceTag::new(0),
            outcome: "confirmed",
            witness_ms: Some(25),
            events: "2-4",
        },
        // The rollback shape: no relay acknowledged, so there is no witness
        // latency and the field is ABSENT rather than a bound rendered as a
        // measurement. It is in the samples so the classifier sees a record
        // that omits a field the table classifies.
        TimelineRecord::Published {
            tick: 12,
            device: DeviceTag::new(0),
            outcome: "rolled-back",
            witness_ms: None,
            events: "1",
        },
        TimelineRecord::Rebound {
            tick: 13,
            relay: RelayTag::new(0),
            attempts: "1",
            wait_ms: 60,
        },
    ]
}

/// The schedule the sample writes.
fn schedule() -> Schedule {
    Schedule::new(vec![
        ScheduledOp {
            tick: 4,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Down,
            },
            heal_at: Some(9),
        },
        ScheduledOp {
            tick: 5,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Closed(ClosedPrefix::AuthRequired),
            },
            heal_at: None,
        },
        ScheduledOp {
            tick: 6,
            op: Op::Fault {
                relay: RelayTag::new(0),
                fault: Fault::Notice(NOTICE),
            },
            heal_at: Some(7),
        },
        ScheduledOp {
            tick: 8,
            op: Op::Device {
                device: DeviceTag::new(1),
                op: DeviceOp::Restart(KillKind::Soft),
            },
            heal_at: None,
        },
        ScheduledOp {
            tick: 9,
            op: Op::Device {
                device: DeviceTag::new(1),
                op: DeviceOp::StepPolicyOffset { secs: 288 },
            },
            heal_at: None,
        },
        ScheduledOp {
            tick: 10,
            op: Op::Probe,
            heal_at: None,
        },
        ScheduledOp {
            tick: 11,
            op: Op::Device {
                device: DeviceTag::new(1),
                op: DeviceOp::ComeOnline,
            },
            heal_at: None,
        },
    ])
}

/// The banner the sample writes.
fn banner() -> Banner {
    Banner::new(
        ProfileName::Pr,
        0,
        &schedule().tag(),
        Provenance::new(Some("bb310e2f4a9c"), Some("1.97.1")),
    )
}

/// Walks one JSON value, emitting one [`Rendered`] per leaf.
fn walk(surface: Surface, prefix: &str, value: &serde_json::Value, into: &mut Vec<Rendered>) {
    match value {
        serde_json::Value::Object(fields) => {
            for (key, nested) in fields {
                let path = if prefix.is_empty() {
                    key.clone()
                } else {
                    format!("{prefix}.{key}")
                };
                walk(surface, &path, nested, into);
            }
        }
        // Array indices are NOT part of a path: `ops[0]` and `ops[1]` are the
        // same field, and numbering them would make the table grow with the
        // sample rather than with the schema.
        serde_json::Value::Array(items) => {
            for item in items {
                walk(surface, prefix, item, into);
            }
        }
        leaf => into.push(Rendered {
            surface,
            path: prefix.to_owned(),
            value: leaf.clone(),
        }),
    }
}

/// Every field the three surfaces render, from the samples above.
fn rendered() -> Vec<Rendered> {
    let mut out = Vec::new();
    for record in records() {
        let json = serde_json::to_value(&record).expect("a record renders");
        walk(Surface::Timeline, "", &json, &mut out);
    }
    let json = serde_json::to_value(schedule()).expect("a schedule renders");
    walk(Surface::Schedule, "", &json, &mut out);
    for line in banner()
        .render(Some(Measured {
            wall: Duration::from_secs(271),
            peak_rss_mib: Some(412),
        }))
        .lines()
    {
        for token in line.split_whitespace() {
            let Some((key, value)) = token.split_once('=') else {
                continue;
            };
            out.push(Rendered {
                surface: Surface::Banner,
                path: key.to_owned(),
                value: serde_json::Value::String(value.to_owned()),
            });
        }
    }
    out
}

/// Whether `value` conforms to `class`.
fn conforms(class: Class, value: &serde_json::Value) -> bool {
    let vocabulary = vocabulary();
    match class {
        // A handle, and the rig's own: `circle#a91f3c` is production's and is
        // deliberately a different vocabulary.
        Class::Tag => value.as_str().is_some_and(|text| {
            let Some((prefix, ordinal)) = text.split_once('#') else {
                // The schedule's own tag: 8 hex, short enough that no
                // structural rule can match it.
                return text.len() == 8 && text.chars().all(|c| c.is_ascii_hexdigit());
            };
            matches!(
                prefix,
                "simdev" | "simcircle" | "simrelay" | "simevt" | "simworld"
            ) && ordinal.chars().all(|c| c.is_ascii_digit())
        }),
        // haven-core's own bucket policy, and nothing else.
        Class::Bucket => value
            .as_str()
            .is_some_and(|text| matches!(text, "0" | "1" | "2-4" | "5+")),
        // A count from the world's origin. `null` is allowed where the field is
        // optional: an absent heal is a permanent fault, not an instant.
        Class::Delta => value.is_null() || value.as_u64().is_some(),
        Class::DurationMs => value.as_u64().is_some(),
        // A wall time in seconds or a resident size in MiB, and the one honest
        // alternative to a figure nobody took.
        Class::Measurement => value.as_str().is_some_and(|text| {
            text == "unavailable"
                || text
                    .trim_end_matches("MiB")
                    .trim_end_matches('s')
                    .parse::<u64>()
                    .is_ok()
        }),
        Class::Literal => value
            .as_str()
            .is_some_and(|text| vocabulary.contains(text) || banner_fact(text)),
    }
}

/// Whether `text` is one of the banner's four repository or build facts.
///
/// Spelled out rather than approximated, because the loose version of this
/// predicate accepted anything: "digits and dots" is also the shape of an IPv4
/// address, and "all hex digits" is vacuously true of the empty string.
fn banner_fact(text: &str) -> bool {
    // The seed: `0x` and exactly sixteen hex, as the banner formats it.
    let seed = text.strip_prefix("0x").is_some_and(|hex| {
        hex.len() == 16 && hex.chars().all(|character| character.is_ascii_hexdigit())
    });
    // A short commit: hex, non-empty, and under the 32 a structural rule
    // matches — the banner truncates to twelve.
    let commit = !text.is_empty()
        && text.len() <= 12
        && text.chars().all(|character| character.is_ascii_hexdigit());
    // A toolchain version: at most three dot-separated numbers, which an IPv4
    // address (four) is not, and each of them short.
    let parts: Vec<&str> = text.split('.').collect();
    let version = (1..=3).contains(&parts.len())
        && parts.iter().all(|part| {
            !part.is_empty()
                && part.len() <= 3
                && part.chars().all(|character| character.is_ascii_digit())
        });
    // The rc-name list, which is one constant in this crate.
    let rc_names = text.contains("clean/");
    seed || commit || version || rc_names
}

#[test]
fn the_field_table_is_pinned_and_holds_no_duplicate() {
    let table = table();
    assert!(table.len() == CLASSIFIED_FIELDS, "{PIN_MOVED}");
    let unique: BTreeSet<(Surface, &str)> = table
        .iter()
        .map(|(surface, path, _)| (*surface, *path))
        .collect();
    assert!(unique.len() == CLASSIFIED_FIELDS, "{PIN_DUPLICATED}");
}

#[test]
fn every_rendered_field_is_classified() {
    let table = table();
    for field in rendered() {
        let classified = table
            .iter()
            .any(|(surface, path, _)| *surface == field.surface && *path == field.path);
        assert!(
            classified,
            "a rendered field carries no privacy class; classify it or stop rendering it"
        );
    }
}

#[test]
fn every_rendered_field_conforms_to_its_class() {
    let table = table();
    for field in rendered() {
        let Some((_, _, class)) = table
            .iter()
            .find(|(surface, path, _)| *surface == field.surface && *path == field.path)
        else {
            continue;
        };
        assert!(
            conforms(*class, &field.value),
            "a rendered field does not conform to the class it declares"
        );
    }
}

#[test]
fn every_classified_field_is_reached_by_a_sample() {
    // The other direction: a row nothing renders is a class nobody checks, and
    // it would keep the pin above satisfied while the field itself was gone.
    let rendered = rendered();
    for (surface, path, _) in table() {
        let reached = rendered
            .iter()
            .any(|field| field.surface == surface && field.path == path);
        assert!(
            reached,
            "a classified field is never rendered by any sample; the sample or the row is stale"
        );
    }
}

#[test]
fn no_rendered_field_carries_an_absolute_instant_or_an_exact_world_count() {
    // The two shapes a class table cannot catch on its own. An instant: a delta
    // is counted from the world's origin, so it stays small. An exact count: a
    // magnitude of the world's behaviour is bucketed, so the only NUMBERS a
    // record may carry are the two classes that are numbers by definition —
    // anything else numeric is a count somebody rendered exactly.
    let table = table();
    for field in rendered() {
        let Some(number) = field.value.as_u64() else {
            continue;
        };
        assert!(
            number < 1_000_000_000,
            "a rendered number is large enough to be a Unix instant"
        );
        let class = table
            .iter()
            .find(|(surface, path, _)| *surface == field.surface && *path == field.path)
            .map(|(_, _, class)| *class);
        assert!(
            matches!(class, Some(Class::Delta | Class::DurationMs)),
            "a rendered number is neither a delta nor a duration, so it is an exact count of \
             something the world did; bucket it"
        );
    }
}

#[test]
fn the_literal_class_refuses_the_two_shapes_it_used_to_wave_through() {
    // The classifier is the whole of the privacy proof for a `literal` field,
    // so its own refusals are worth a test: the loose version accepted an IPv4
    // address as a version and the empty string as a commit.
    assert!(banner_fact("0x00000000000000ff"), "the banner's own seed");
    assert!(banner_fact("bb310e2f4a9c"), "a short commit");
    assert!(banner_fact("1.97.1"), "a toolchain version");
    assert!(
        !banner_fact("127.0.0.1"),
        "an address is not a version, and four dotted numbers is exactly its shape"
    );
    assert!(
        !banner_fact("192.168.1.24"),
        "nor is a private one, which is what a runner's own address looks like"
    );
    assert!(
        !banner_fact(""),
        "the empty string is not a commit; a predicate over its characters is vacuously true"
    );
    assert!(
        !banner_fact("9f86d081884c7d659a2feaa0c55ad015"),
        "32 hex is a structural rule's own shape, whatever else it might be"
    );
}

#[test]
fn the_banner_renders_no_hex_run_a_structural_rule_could_match() {
    // S2 matches 32-63 hex and S1 matches 64. The banner is scanned as one of
    // the run's own sinks, so a long hex run would red a clean run's own scan.
    let text = banner().render(Some(Measured {
        wall: Duration::from_secs(1),
        peak_rss_mib: None,
    }));
    let longest = text
        .split(|c: char| !c.is_ascii_hexdigit())
        .map(str::len)
        .max()
        .unwrap_or(0);
    assert!(longest < 32, "the banner rendered a scanner-shaped hex run");
}

#[test]
fn the_schedule_file_renders_its_tag_and_never_its_digest() {
    let schedule = schedule();
    let json = serde_json::to_string(&schedule).expect("a schedule renders");
    assert!(
        json.contains(&schedule.tag()),
        "the tag is what a reader gets"
    );
    assert!(
        !json.contains(&hex::encode(schedule.digest())),
        "64 hex characters is the shape of a pubkey, an event id and a group id"
    );
}
