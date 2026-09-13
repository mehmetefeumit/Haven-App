//! Positive controls.
//!
//! A plant proves **sink reach only**: that the file the scanner was pointed at
//! is the file the run actually wrote. Nothing else in this instrument can prove
//! that — a wrong path, a rotated log, a dead capture, an unflushed
//! `debugPrintThrottled` buffer and a mis-installed Rust log backend all read as
//! "clean" to a needle search. A missed plant is therefore rc 3, never a pass.
//!
//! # Two kinds, for two different reasons
//!
//! * **Declared** — the Dart plant. `LogNeedles.plant(phase)` mints one token
//!   per phase, declares it over `HAVEN_NEEDLE_DECL` and `debugPrint`s it, so it
//!   reaches both `logcat` (tag `flutter`) and the drive transcript. Per run, so
//!   a token from a previous run cannot satisfy this run.
//! * **Shape-matched** — Rust, Kotlin and Swift. There is no native harness
//!   channel to declare through, so those three are matched by shape
//!   (`logscan-plant-<emitter>-open-<10 chars>`). Staleness is covered by the
//!   per-run Dart tokens and by `adb logcat -c` before capture.
//!
//! # Structurally inert by construction
//!
//! `tooling/e2e/ci/scan-logs-for-secrets.sh` has no allowlist mechanism of any
//! kind, and the wrapper runs both scanners: a class-shaped synthetic plant (a
//! fake `nsec1…`, a 32-element array) would trip that scanner on every green run
//! and take the containment branch, deleting the evidence the plant existed to
//! prove. Hence the alphabet and the literal prefix below, and hence
//! [`assert_inert`], which is rc 2 — a mis-designed control, not a leak.

use rand::rngs::OsRng;
use rand::TryRngCore;
use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::rules::RuleSet;

/// The plant alphabet.
///
/// The 24 upper-case letters without `I` and `O`, plus the digits `2`-`9`. No
/// `0` and no `1`, so a token can never read as bech32 data (whose separator is
/// `1`) or as a transcription slip.
pub const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/// How many random characters a token carries. 32^10 ≈ 2^50: a token cannot
/// collide with another run's by chance.
pub const TOKEN_CHARS: usize = 10;

/// The only emitter whose plants are declared.
pub const DECLARED_EMITTER: &str = "dart";

/// The phases a declared plant has. `close` is emitted as the LAST act of the
/// capture, so a truncated, rotated or unflushed sink is rc 3 rather than green.
pub const PHASES: [&str; 2] = ["open", "close"];

/// Emitters matched by shape rather than by declaration.
pub const SHAPE_EMITTERS: [&str; 3] = ["rust", "kotlin", "swift"];

/// Where a slot's token came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PlantOrigin {
    /// The harness minted it and declared it back over the proxy channel.
    Declared,
    /// No declaration arrived, so `seal` minted one for the harness to print.
    Minted,
}

/// One (emitter, phase) slot.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlantSlot {
    /// The emitter (`dart`).
    pub sink: String,
    /// `open` or `close`.
    pub phase: String,
    /// The token the scanner requires.
    pub token: String,
    /// Where the token came from.
    pub origin: PlantOrigin,
    /// The declaration's sequence number, kept for the record. It is NOT what
    /// picks the winner: see [`resolve_slots`].
    pub seq: Option<u64>,
    /// Tokens declared EARLIER for this slot. The Android lane's connect-flake
    /// retry re-runs the drive target, which re-mints and re-declares: an older
    /// token still present in a concatenated log is ignored, not a failure.
    pub superseded: Vec<String>,
}

/// A plant declaration as it arrived on the sidecar.
#[derive(Clone, Debug)]
pub struct DeclaredPlant {
    /// The emitter the harness named.
    pub sink: String,
    /// `open` or `close`.
    pub phase: String,
    /// The token.
    pub token: String,
    /// The proxy's per-role sequence number.
    pub seq: Option<u64>,
    /// Position in the sidecar — the proxy appends in chronological order, so
    /// the last line is the latest declaration. This is what picks the winner.
    pub order: usize,
}

/// The shape every plant token has, whatever its emitter.
///
/// # Panics
///
/// Never in practice: the pattern is a literal with one interpolated integer
/// constant, so a failure here would mean the crate was built with a broken
/// `TOKEN_CHARS`.
#[must_use]
pub fn shape_regex() -> Regex {
    Regex::new(&format!(
        r"logscan-plant-(dart|rust|kotlin|swift)-(open|close)-([A-Z2-9]{{{TOKEN_CHARS}}})"
    ))
    .expect("the plant shape is a literal")
}

/// Mints one token from the OS CSPRNG.
///
/// # Errors
///
/// Returns a message when the OS CSPRNG is unavailable. A guessable positive
/// control would let a stale log satisfy a fresh run, so there is no fallback.
pub fn mint(emitter: &str, phase: &str) -> Result<String, String> {
    let mut bytes = [0u8; TOKEN_CHARS];
    // `OsRng` only, and the crate is built without `thread_rng` at all: a
    // guessable positive control would let a stale log satisfy a fresh run.
    OsRng.try_fill_bytes(&mut bytes).map_err(|_| {
        "the OS CSPRNG is unavailable, so no positive control can be minted".to_owned()
    })?;
    // 256 is an exact multiple of 32, so the modulo is unbiased.
    let token: String = bytes
        .iter()
        .map(|b| char::from(ALPHABET[usize::from(*b) % ALPHABET.len()]))
        .collect();
    Ok(format!("logscan-plant-{emitter}-{phase}-{token}"))
}

/// Asserts a token trips no structural rule.
///
/// # Errors
///
/// Returns the rule id that fired. The caller's contract is rc 2.
pub fn assert_inert(token: &str, rules: &RuleSet) -> Result<(), String> {
    let hits = rules.evaluate(token, "plant-inertness-probe", Some("haven"));
    hits.first().map_or(Ok(()), |hit| {
        Err(format!(
            "plant token shape trips structural rule {} — the control is mis-designed, and on a green run it would delete the evidence it exists to prove",
            hit.rule
        ))
    })
}

/// Resolves declared plants into one slot per (emitter, phase), keeping the
/// highest `seq` and minting what was never declared.
///
/// # Errors
///
/// Returns a message when a declaration names an emitter or a phase the
/// declaration channel is not allowed to use — producer/policy drift, rc 2.
pub fn resolve_slots(declared: &[DeclaredPlant]) -> Result<Vec<PlantSlot>, String> {
    for plant in declared {
        if plant.sink != DECLARED_EMITTER {
            return Err(format!(
                "a plant was declared for emitter `{}`, but only `{DECLARED_EMITTER}` plants are declared; {:?} are matched by shape",
                plant.sink, SHAPE_EMITTERS
            ));
        }
        if !PHASES.contains(&plant.phase.as_str()) {
            return Err(format!(
                "a plant was declared for phase `{}`, which is not one of {PHASES:?}",
                plant.phase
            ));
        }
    }
    let mut slots = Vec::with_capacity(PHASES.len());
    for phase in PHASES {
        let mut candidates: Vec<&DeclaredPlant> = declared
            .iter()
            .filter(|p| p.phase == phase && p.sink == DECLARED_EMITTER)
            .collect();
        // The LAST declaration in the sidecar wins, and `seq` is only a tiebreak
        // for two lines at one position (which cannot happen). Position, not
        // `seq`: the proxy's counter restarts at 0 in a new process while it
        // appends to a sidecar it did not create, so a restart mid-lane would
        // otherwise let run 1's high-`seq` token outrank run 2's and a stale
        // token would satisfy a fresh run — the one failure plants exist to
        // prevent.
        candidates.sort_by_key(|p| (p.order, p.seq.unwrap_or(0)));
        match candidates.pop() {
            Some(winner) => slots.push(PlantSlot {
                sink: DECLARED_EMITTER.to_owned(),
                phase: phase.to_owned(),
                token: winner.token.clone(),
                origin: PlantOrigin::Declared,
                seq: winner.seq,
                superseded: candidates.iter().map(|p| p.token.clone()).collect(),
            }),
            None => slots.push(PlantSlot {
                sink: DECLARED_EMITTER.to_owned(),
                phase: phase.to_owned(),
                token: mint(DECLARED_EMITTER, phase)?,
                origin: PlantOrigin::Minted,
                seq: None,
                superseded: Vec::new(),
            }),
        }
    }
    Ok(slots)
}

#[cfg(test)]
mod tests {
    use super::{
        assert_inert, mint, resolve_slots, shape_regex, DeclaredPlant, PlantOrigin, ALPHABET,
        PHASES, SHAPE_EMITTERS, TOKEN_CHARS,
    };
    use crate::rules::RuleSet;

    fn rules() -> RuleSet {
        RuleSet::new(4.2, 1_800_000_000, &[], Vec::new()).expect("rules")
    }

    /// The seven patterns of `tooling/e2e/ci/scan-logs-for-secrets.sh:88-96`,
    /// transcribed so a plant can be proven inert against the OTHER scanner too
    /// — the one with no allowlist, whose rc 1 deletes the evidence.
    const BASH_PATTERNS: &[&str] = &[
        r"secret:\s*Some\(\[",
        r"password:\s*Some\(\[",
        r"nsec1[ac-hj-np-z02-9]{20,}",
        r"(secret|seed|exporter_secret|private[_-]?key)[^]]{0,30}\[[0-9]{1,3}(,\s*[0-9]{1,3}){15,}\]",
        r"(PRAGMA\s+key|pragma_key|sqlcipher[_-]?key|db[_-]?key|passphrase)[^0-9a-fA-F]{0,24}[0-9a-fA-F]{64}",
        r"(secret|seed|identity|private[_-]?key)[^A-Za-z0-9+/]{0,24}[A-Za-z0-9+/]{42,43}=",
        r"(flutter|RustStdoutStderr|keyring|haven|Haven).{0,200}\[[0-9]{1,3}(,\s*[0-9]{1,3}){31}\]",
    ];

    #[test]
    fn a_minted_token_has_the_declared_shape_and_alphabet() {
        let token = mint("dart", "open").expect("mint");
        assert!(shape_regex().is_match(&token), "{token}");
        let random = token.rsplit('-').next().expect("suffix");
        assert_eq!(random.chars().count(), TOKEN_CHARS);
        assert!(random.bytes().all(|b| ALPHABET.contains(&b)));
    }

    #[test]
    fn two_tokens_differ() {
        // Not a statistical claim: a generator wired to a constant would make
        // every run satisfiable by a log from any other run.
        let a = mint("dart", "open").expect("mint");
        let b = mint("dart", "open").expect("mint");
        assert_ne!(a, b);
    }

    /// The structural argument behind the inertness claim, asserted directly.
    ///
    /// Sampling tokens (below) can only ever be evidence; THESE are the
    /// properties that make each rule unreachable inside a token, and each is a
    /// consequence of the alphabet and the shape rather than of luck:
    ///
    /// * no `1` at all, so S3's bech32 separator and S11's `1<9 digits>` epoch
    ///   cannot occur;
    /// * no `.`, `:`, `=`, `/` or `[`, so S5, S7, S9, S10 and S12 cannot occur;
    /// * every alphanumeric run is at most 10 characters, so S1 (64 hex), S2 (32
    ///   hex), S4 (32 base64) and S8 (a 24-character blob) cannot occur;
    /// * a `gh`/`geo` inside the random part is either preceded by an
    ///   alphanumeric or followed by one, and S6 requires a delimited keyword
    ///   AND a non-alphanumeric separator.
    #[test]
    fn the_token_shape_makes_every_rule_unreachable() {
        let token = mint("dart", "open").expect("mint");
        assert!(!token.contains('1'), "no bech32 separator, no epoch second");
        for punctuation in ['.', ':', '=', '/', '[', ']', ',', '+'] {
            assert!(!token.contains(punctuation), "no `{punctuation}`");
        }
        let longest = token
            .split('-')
            .map(str::len)
            .max()
            .expect("a token has fields");
        assert!(longest <= TOKEN_CHARS, "longest run {longest}");
        // A compile-time assertion, because the bound is a property of the
        // constant rather than of this token: 10 characters cannot satisfy S1's
        // 64 hex, S2's 32 hex, S4's 32 base64 or S8's 24-character blob.
        const { assert!(TOKEN_CHARS < 24) };
        // Both halves of the S6 argument, on the two worst cases: a random part
        // that BEGINS with `GH` (so the keyword is delimited by the preceding
        // dash, and only the missing separator saves it) and one that ENDS with
        // `GH` — which matters because the guarantee is about the whole LINE,
        // not the token alone, and the word after a token is not ours to
        // choose. `cursed` is six geohash-alphabet characters.
        for hostile in [
            "logscan-plant-dart-open-GHJKMNPQRS",
            "logscan-plant-dart-open-BCDEFJKMGH",
        ] {
            assert!(shape_regex().is_match(hostile), "the worst case is a token");
            assert_inert(hostile, &rules()).expect("no rule may fire inside a token");
            assert_inert(&format!("{hostile} cursed"), &rules())
                .expect("nor when a geohash-shaped word follows the token");
            assert_inert(&format!("flutter: {hostile} cursed"), &rules())
                .expect("nor on the line a harness actually writes");
        }
    }

    /// Sampling as evidence for the argument above: every token of every emitter
    /// and phase must trip no rule of EITHER scanner.
    #[test]
    fn no_minted_token_trips_any_rule_of_either_scanner() {
        let rules = rules();
        let bash: Vec<regex::Regex> = BASH_PATTERNS
            .iter()
            .map(|p| regex::Regex::new(p).expect("bash pattern"))
            .collect();
        let mut emitters = vec![super::DECLARED_EMITTER];
        emitters.extend(SHAPE_EMITTERS);
        for emitter in emitters {
            for phase in PHASES {
                for _ in 0..64 {
                    let token = mint(emitter, phase).expect("mint");
                    assert_inert(&token, &rules).expect("a plant must be structurally inert");
                    // The line a harness actually writes, not just the token.
                    let line = format!("flutter: {token}");
                    for (index, pattern) in bash.iter().enumerate() {
                        assert!(
                            !pattern.is_match(&line),
                            "bash pattern {} matched plant line",
                            index + 1
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn a_token_that_trips_a_rule_is_rejected() {
        // The mis-designed control the review warned about: a class-shaped
        // synthetic nsec.
        let bad = "logscan-plant-dart-open-nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq";
        let err = assert_inert(bad, &rules()).expect_err("a bech32-shaped plant must be rejected");
        assert!(err.contains("S3"), "{err}");
    }

    #[test]
    fn an_undeclared_slot_is_minted_and_a_declared_one_is_adopted() {
        let declared = vec![DeclaredPlant {
            sink: "dart".to_owned(),
            phase: "open".to_owned(),
            token: "logscan-plant-dart-open-ABCDEFGHJK".to_owned(),
            seq: Some(3),
            order: 0,
        }];
        let slots = resolve_slots(&declared).expect("resolve");
        assert_eq!(slots.len(), 2);
        assert_eq!(slots[0].origin, PlantOrigin::Declared);
        assert_eq!(slots[0].token, "logscan-plant-dart-open-ABCDEFGHJK");
        assert_eq!(slots[1].origin, PlantOrigin::Minted);
        assert_eq!(slots[1].phase, "close");
    }

    #[test]
    fn the_last_declaration_wins_and_the_rest_are_superseded() {
        // The retry case: the drive target re-ran and re-declared. The older
        // token is still in the concatenated log and must be ignored rather
        // than read as an undeclared plant.
        let declared = vec![
            DeclaredPlant {
                sink: "dart".to_owned(),
                phase: "open".to_owned(),
                token: "logscan-plant-dart-open-AAAAAAAAAA".to_owned(),
                seq: Some(2),
                order: 0,
            },
            DeclaredPlant {
                sink: "dart".to_owned(),
                phase: "open".to_owned(),
                token: "logscan-plant-dart-open-BBBBBBBBBB".to_owned(),
                seq: Some(9),
                order: 1,
            },
        ];
        let slots = resolve_slots(&declared).expect("resolve");
        assert_eq!(slots[0].token, "logscan-plant-dart-open-BBBBBBBBBB");
        assert_eq!(
            slots[0].superseded,
            vec!["logscan-plant-dart-open-AAAAAAAAAA".to_owned()]
        );
    }

    /// A restarted proxy declares at `seq = 0` onto a sidecar that already
    /// holds higher numbers. The LATER line must still win, or a stale token
    /// from the previous run would satisfy this one.
    #[test]
    fn a_restarted_sequence_counter_cannot_resurrect_a_superseded_token() {
        let declared = vec![
            DeclaredPlant {
                sink: "dart".to_owned(),
                phase: "open".to_owned(),
                token: "logscan-plant-dart-open-AAAAAAAAAA".to_owned(),
                seq: Some(9),
                order: 0,
            },
            DeclaredPlant {
                sink: "dart".to_owned(),
                phase: "open".to_owned(),
                token: "logscan-plant-dart-open-BBBBBBBBBB".to_owned(),
                seq: Some(0),
                order: 1,
            },
        ];
        let slots = resolve_slots(&declared).expect("resolve");
        assert_eq!(slots[0].token, "logscan-plant-dart-open-BBBBBBBBBB");
        assert_eq!(
            slots[0].superseded,
            vec!["logscan-plant-dart-open-AAAAAAAAAA".to_owned()]
        );
    }

    #[test]
    fn sidecar_order_decides_when_no_sequence_number_arrived() {
        let declared = vec![
            DeclaredPlant {
                sink: "dart".to_owned(),
                phase: "close".to_owned(),
                token: "logscan-plant-dart-close-AAAAAAAAAA".to_owned(),
                seq: None,
                order: 0,
            },
            DeclaredPlant {
                sink: "dart".to_owned(),
                phase: "close".to_owned(),
                token: "logscan-plant-dart-close-BBBBBBBBBB".to_owned(),
                seq: None,
                order: 1,
            },
        ];
        let slots = resolve_slots(&declared).expect("resolve");
        let close = slots.iter().find(|s| s.phase == "close").expect("close");
        assert_eq!(close.token, "logscan-plant-dart-close-BBBBBBBBBB");
    }

    #[test]
    fn a_declaration_for_a_shape_matched_emitter_is_rejected() {
        let declared = vec![DeclaredPlant {
            sink: "kotlin".to_owned(),
            phase: "open".to_owned(),
            token: "logscan-plant-kotlin-open-ABCDEFGHJK".to_owned(),
            seq: Some(1),
            order: 0,
        }];
        let err = resolve_slots(&declared).expect_err("kotlin plants are undeclared");
        assert!(err.contains("matched by shape"), "{err}");
    }

    #[test]
    fn the_shape_regex_reports_the_emitter_and_the_phase() {
        let captures = shape_regex()
            .captures("D haven: logscan-plant-rust-open-ABCDEFGHJK")
            .expect("a token in a log line");
        assert_eq!(captures.get(1).map(|m| m.as_str()), Some("rust"));
        assert_eq!(captures.get(2).map(|m| m.as_str()), Some("open"));
        // A lowercase tail is not a token: the alphabet is upper-case only, so a
        // prose mention of a plant cannot satisfy a sink.
        assert!(!shape_regex().is_match("logscan-plant-rust-open-abcdefghjk"));
        // Nor is an unknown emitter, however plausible.
        assert!(!shape_regex().is_match("logscan-plant-python-open-ABCDEFGHJK"));
    }
}
