//! The one expander: a declared value in, every encoding the tree can render it
//! in out.
//!
//! # Why one expander
//!
//! Three consumers read its output (the CI scan, the Tier-1 in-process capture,
//! the Dart literal matcher). Two expanders would mean two coverage claims and
//! one tested one, so the expansion happens ONCE, at seal time, and every
//! matcher consumes the sealed term list.
//!
//! # Labels are a vocabulary, not a description
//!
//! Every label below is declared in `policy.toml`'s `[ledger]` as `covered` or
//! as a `gap` with a reason, and [`crate::ledger`] reconciles the two on every
//! seal. That is what makes the coverage claim falsifiable: an encoding that
//! stops being produced, or starts being produced undeclared, is rc 3 rather
//! than a silently narrower search. The model is
//! `haven/integration_test/e2e/_lib/wire_canaries.dart`'s
//! `CanaryEncodingLedger` (~842-1213).
//!
//! # Every label always produces an entry
//!
//! For each (value, label) the expander emits EITHER a [`Term`] or a
//! [`Dropped`], never nothing. A label that silently produced neither would be
//! invisible to the ledger, to the report, and to every check written over
//! those two lists.

use std::collections::BTreeMap;

use base64::engine::general_purpose::{STANDARD_NO_PAD, URL_SAFE_NO_PAD};
use base64::Engine;
use bech32::primitives::hrp::Hrp;
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

use crate::fold::search_fold;
use crate::policy::{ClassKind, ClassSpec, Policy};

/// A searchable term.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Term {
    /// The value it was derived from (`v1`, `v2`, …). Never a value.
    pub value: String,
    /// The needle class.
    pub class: String,
    /// The encoding label — the ledger's vocabulary.
    pub encoding: String,
    /// The text to search for.
    pub text: String,
    /// Whether the match must respect case. Only base64 does.
    pub case_sensitive: bool,
}

/// Why a label produced no searchable term.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DropKind {
    /// The rendering exists but is already covered by another term (an equal
    /// string, or the same string under a case-insensitive automaton). Nothing
    /// is lost.
    Alias,
    /// The declared VALUE has no such rendering (a name too short for this
    /// prefix, a negative axis with no `+` form, a geohash shorter than this
    /// precision). A real hole, but not a policy choice.
    Unavailable,
    /// The expander deliberately does not search this rendering. This is the
    /// only kind the ledger accepts against a `gap` claim.
    PolicyGap,
}

/// A label that produced no term, and why.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Dropped {
    /// The value it would have been derived from.
    pub value: String,
    /// The needle class.
    pub class: String,
    /// The encoding label.
    pub encoding: String,
    /// Whose limitation this is.
    pub kind: DropKind,
    /// One sentence, naming classes and labels only — never a value.
    pub reason: String,
    /// Whether recall is actually lost (everything but an alias).
    pub coverage_gap: bool,
}

/// A value as declared on the wire or by the host.
#[derive(Clone, Debug)]
pub struct Declared {
    /// Manifest-local id (`v1`, `v2`, …).
    pub id: String,
    /// The needle class.
    pub class: String,
    /// The raw declared text. Never serialised for a secret class.
    pub raw: String,
}

/// Everything one seal expanded.
#[derive(Clone, Debug, Default)]
pub struct Expansion {
    /// Searchable terms, in declaration order then label order.
    pub terms: Vec<Term>,
    /// Labels that produced no term.
    pub dropped: Vec<Dropped>,
}

/// The byte labels, in expansion order.
pub const BYTE_LABELS: &[&str] = &[
    "hex-lower",
    "hex-upper",
    "hex-prefix8",
    "hex-prefix12",
    "hex-prefix16",
    "hex-spaced",
    "hex-reversed-bytes",
    "rust-debug-x",
    "rust-debug-upper-x",
    "rust-debug-02x",
    "rust-debug-alt-x",
    "dart-radix16-unpadded",
    "base64-std-align0",
    "base64-std-align0-padded",
    "base64-std-align1",
    "base64-std-align1-padded",
    "base64-std-align2",
    "base64-std-align2-padded",
    "base64-url-align0",
    "base64-url-align0-padded",
    "base64-url-align1",
    "base64-url-align1-padded",
    "base64-url-align2",
    "base64-url-align2-padded",
    "debug-array",
    "debug-array-compact",
    "sha256-hex",
    "sha256-hex-prefix8",
    "sha256-hex-prefix16",
];

/// The byte labels that render the RAW bytes. For a secret class every one of
/// these is a policy gap: the raw value is never serialised, so the manifest
/// cannot hold a term for it.
///
/// A POSITION into [`BYTE_LABELS`], so inserting a label in the wrong place
/// would silently make a raw rendering searchable for an `nsec`;
/// `the_raw_byte_boundary_is_where_the_commitment_starts` is the pin.
const RAW_BYTE_LABELS: usize = 26;

/// The string forms, in expansion order. Each also carries one base64 layer.
pub const TEXT_FORMS: &[&str] = &[
    "utf8",
    "nfc",
    "nfd",
    "nfkc",
    "nfkd",
    "lower",
    "upper",
    "casefold",
    "search-fold",
    "percent-component",
    "percent-form",
    "json-escaped",
    "latin1-from-char-codes",
];

/// How many trailing characters the name-prefix ladder drops.
///
/// Four, because four characters is where a prefix of a realistic name stops
/// being specific to that name: the ladder exists because a truncated name is
/// still the name (remote prose, a width-limited UI echo and a `…`-elided
/// diagnostic all produce one), not because any one call site truncates today.
/// Stated here as a number rather than derived from a floor: a ladder that
/// recomputed its own bound would follow a policy change instead of reporting it.
pub const NAME_DROPS: usize = 4;

/// The per-axis coordinate labels, in expansion order.
///
/// The ladders start at FOUR decimals: a single axis at three decimals is a
/// six-character decimal number (`47.209`), which collides with a millisecond
/// duration, a percentage and a logcat stamp — CI run 34766632019 matched one
/// in a relay log. `policy.toml`'s `[ledger.coordinate].not_gaps` names the two
/// labels per axis that removes, and the PAIR labels keep three decimals
/// because a pair is unambiguous.
const AXIS_LABELS: &[&str] = &[
    "decimal-round4",
    "decimal-round5",
    "decimal-round6",
    "decimal-round7",
    "decimal-trunc4",
    "decimal-trunc5",
    "decimal-trunc6",
    "decimal-trunc7",
    "trimmed",
    "scientific",
    "scientific-dart",
    "comma-decimal",
    "unsigned",
    "sign-plus",
];

/// The coordinate pair labels, in expansion order.
const PAIR_LABELS: &[&str] = &[
    "pair-latlon/sep-comma",
    "pair-latlon/sep-comma-space",
    "pair-latlon/sep-space",
    "pair-lonlat/sep-comma",
    "pair-lonlat/sep-comma-space",
    "pair-lonlat/sep-space",
];

/// The geohash labels, in expansion order.
///
/// The ladder is written out to precision 4 and then FILTERED by the global term
/// floor, rather than starting at the floor: the precisions that exist are a
/// property of geohash, the ones that are searchable are a property of policy,
/// and `policy.toml`'s `not_gaps` has to name the difference.
const GEOHASH_LABELS: &[&str] = &[
    "full", "prefix4", "prefix5", "prefix6", "prefix7", "prefix8",
];

/// The geohash labels a sink could actually search under `min_term_len`.
///
/// A prefix shorter than the floor is unsearchable for EVERY value, not just for
/// a short one, so it must not be produced at all: an `Unavailable` drop would
/// satisfy a `covered` claim and let the ledger promise a search nothing ever
/// performs.
fn geohash_labels(min_term_len: usize) -> Vec<&'static str> {
    GEOHASH_LABELS
        .iter()
        .copied()
        .filter(|label| {
            label
                .strip_prefix("prefix")
                .and_then(|n| n.parse::<usize>().ok())
                .is_none_or(|n| n >= min_term_len)
        })
        .collect()
}

/// The URL labels, in expansion order.
const URL_LABELS: &[&str] = &[
    "as-declared",
    "no-trailing-slash",
    "trailing-slash",
    "scheme-alt",
    "host-only",
    "host-upper",
    "host-punycode",
    "with-port",
    "without-port",
    "percent-encoded",
];

/// Dart's `Uri.encodeComponent` unreserved set.
const UNRESERVED_COMPONENT: &[u8] = b"-_.!~*'()";

/// Dart's `Uri.encodeQueryComponent` unreserved set — the RFC 3986 one.
///
/// Narrower than `encodeComponent`'s on purpose: a query rendering escapes `'`,
/// `!`, `*`, `(` and `)`, so `Kai's Circle` is `Kai%27s+Circle` there and
/// `Kai's%20Circle` in a path component. Using one set for both would have left
/// the form rendering of any name containing an apostrophe searched for by
/// nothing.
const UNRESERVED_QUERY: &[u8] = b"-._~";

/// Expands every declared value under `policy`.
///
/// # Errors
///
/// Returns a message when a declared value does not have the shape its class
/// promises — a producer bug, reported as a broken guard rather than a leak.
pub fn expand(policy: &Policy, declared: &[Declared]) -> Result<Expansion, String> {
    let mut sink = Sink {
        policy,
        seen: BTreeMap::new(),
        out: Expansion::default(),
    };
    for value in declared {
        let spec = policy.class(&value.class)?;
        match spec.kind {
            ClassKind::Bytes => expand_bytes(&mut sink, value, spec)?,
            ClassKind::Text => expand_text(&mut sink, value),
            ClassKind::Coordinate => expand_coordinate(&mut sink, value)?,
            ClassKind::Geohash => expand_geohash(&mut sink, value),
            ClassKind::Url => expand_url(&mut sink, value)?,
            // A plant is matched literally and tallied, never expanded: it
            // proves sink reach, and an expanded plant would prove nothing the
            // expander's own tests do not already prove.
            ClassKind::Plant => {}
        }
    }
    Ok(sink.out)
}

/// The expansion in progress.
struct Sink<'a> {
    policy: &'a Policy,
    /// Dedup is global: the same text reached through two labels, or through two
    /// values, is ONE pattern. The key is the automaton's view of the text, so
    /// `hex-upper` collapses into `hex-lower` and `bech32-*-upper` into
    /// `bech32-*` without either label going unrecorded.
    seen: BTreeMap<(bool, String), (String, String)>,
    out: Expansion,
}

impl Sink<'_> {
    /// Records one term, or the reason there is none.
    fn push(
        &mut self,
        value: &Declared,
        encoding: &str,
        text: Option<String>,
        case_sensitive: bool,
        unavailable_reason: &str,
    ) {
        let Some(text) = text else {
            self.drop_it(
                value,
                encoding,
                DropKind::Unavailable,
                unavailable_reason.to_owned(),
            );
            return;
        };
        if text.chars().count() < self.policy.min_term_len {
            self.drop_it(
                value,
                encoding,
                DropKind::Unavailable,
                "the declared value yields fewer characters at this encoding than the global term floor"
                    .to_owned(),
            );
            return;
        }
        if self
            .policy
            .furniture
            .iter()
            .any(|f| f.eq_ignore_ascii_case(&text))
        {
            self.drop_it(
                value,
                encoding,
                DropKind::Unavailable,
                "identical to sink furniture, which every log line carries anyway".to_owned(),
            );
            return;
        }
        // The dedup key must be EXACTLY what the automaton sees, and
        // `ascii_case_insensitive` folds ASCII only. Keying on a full Unicode
        // lowercase would collapse `KÅRE` into `kåre` and then search for
        // neither spelling of the `Å`.
        let key = (
            case_sensitive,
            if case_sensitive {
                text.clone()
            } else {
                text.to_ascii_lowercase()
            },
        );
        if let Some((other_class, other_encoding)) = self.seen.get(&key) {
            let reason = format!("already searched as {other_class}/{other_encoding}");
            self.drop_it(value, encoding, DropKind::Alias, reason);
            return;
        }
        self.seen
            .insert(key, (value.class.clone(), encoding.to_owned()));
        self.out.terms.push(Term {
            value: value.id.clone(),
            class: value.class.clone(),
            encoding: encoding.to_owned(),
            text,
            case_sensitive,
        });
    }

    fn drop_it(&mut self, value: &Declared, encoding: &str, kind: DropKind, reason: String) {
        self.out.dropped.push(Dropped {
            value: value.id.clone(),
            class: value.class.clone(),
            encoding: encoding.to_owned(),
            kind,
            reason,
            coverage_gap: kind != DropKind::Alias,
        });
    }
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

/// Decodes a byte-class declaration, which may arrive as hex or as bech32.
fn decode_bytes(value: &Declared, spec: &ClassSpec) -> Result<Vec<u8>, String> {
    let raw = value.raw.trim();
    for hrp in &spec.bech32 {
        if raw.to_lowercase().starts_with(&format!("{hrp}1")) {
            let (_, data) = bech32::decode(raw).map_err(|_| {
                format!(
                    "class `{}` declared a bech32 value that does not decode",
                    value.class
                )
            })?;
            return Ok(data);
        }
    }
    hex::decode(raw).map_err(|_| {
        format!(
            "class `{}` declared a value that is neither hex nor one of its bech32 forms",
            value.class
        )
    })
}

fn expand_bytes(sink: &mut Sink<'_>, value: &Declared, spec: &ClassSpec) -> Result<(), String> {
    let bytes = decode_bytes(value, spec)?;
    let digest: [u8; 32] = Sha256::digest(&bytes).into();
    let digest_hex = hex::encode(digest);

    for (index, label) in BYTE_LABELS.iter().enumerate() {
        // Secret class: the raw value is never serialised, so every raw
        // rendering is a declared coverage gap and only the commitment's
        // encodings remain searchable. Recall for raw secrets is carried by
        // `scan-logs-for-secrets.sh`'s keyword-anchored patterns and by
        // S1/S2/S4/S8/S9.
        if spec.secret && index < RAW_BYTE_LABELS {
            sink.drop_it(
                value,
                label,
                DropKind::PolicyGap,
                "secret-class raw never serialised".to_owned(),
            );
            continue;
        }
        let (text, case_sensitive) = byte_encoding(label, &bytes, &digest_hex);
        sink.push(
            value,
            label,
            text,
            case_sensitive,
            "the declared value is too short for this rendering",
        );
    }

    for hrp in &spec.bech32 {
        for (label, upper) in [
            (format!("bech32-{hrp}"), false),
            (format!("bech32-{hrp}-upper"), true),
        ] {
            if spec.secret {
                sink.drop_it(
                    value,
                    &label,
                    DropKind::PolicyGap,
                    "secret-class raw never serialised".to_owned(),
                );
                continue;
            }
            let text = bech32_form(hrp, &bytes, upper);
            sink.push(
                value,
                &label,
                text,
                false,
                "the declared value cannot be encoded under this HRP",
            );
        }
    }

    for hrp in &spec.bech32_tlv_gap {
        sink.drop_it(
            value,
            &format!("bech32-{hrp}-tlv-hint"),
            DropKind::PolicyGap,
            "TLV forms carry relay hints; S3 is the net".to_owned(),
        );
    }
    Ok(())
}

/// One byte encoding. `None` means the value cannot carry it.
fn byte_encoding(label: &str, bytes: &[u8], digest_hex: &str) -> (Option<String>, bool) {
    let hex_lower = hex::encode(bytes);
    let text = match label {
        "hex-lower" => Some(hex_lower),
        "hex-upper" => Some(hex::encode_upper(bytes)),
        "hex-prefix8" => hex_lower.get(..8).map(str::to_owned),
        "hex-prefix12" => hex_lower.get(..12).map(str::to_owned),
        "hex-prefix16" => hex_lower.get(..16).map(str::to_owned),
        "hex-spaced" => Some(render_bytes(bytes.iter().copied(), true, " ", "")),
        "hex-reversed-bytes" => Some(render_bytes(bytes.iter().rev().copied(), true, "", "")),
        // The four Rust byte-slice debug dialects. `{:#x?}` is multi-line, so
        // the term is its whitespace-collapsed normalisation — which is the
        // view `scan` builds when it re-joins a chunked logcat record.
        "rust-debug-x" => Some(format!("{bytes:x?}")),
        "rust-debug-upper-x" => Some(format!("{bytes:X?}")),
        "rust-debug-02x" => Some(format!("{bytes:02x?}")),
        "rust-debug-alt-x" => Some(render_bytes(bytes.iter().copied(), false, ", ", "0x")),
        // Dart's `b.toRadixString(16)` drops the leading zero of every byte
        // below 0x10, so the canonical 64-hex term misses this rendering for
        // ~87 % of random 32-byte values — and so does S1.
        "dart-radix16-unpadded" => Some(render_bytes(bytes.iter().copied(), false, "", "")),
        // An alignment core is whole 3-byte groups, so it is a substring of the
        // padded rendering of the same stream: searching the core catches both,
        // and the `-padded` labels therefore collapse into aliases.
        "base64-std-align0" | "base64-std-align0-padded" => b64_core(&STANDARD_NO_PAD, bytes, 0),
        "base64-std-align1" | "base64-std-align1-padded" => b64_core(&STANDARD_NO_PAD, bytes, 1),
        "base64-std-align2" | "base64-std-align2-padded" => b64_core(&STANDARD_NO_PAD, bytes, 2),
        "base64-url-align0" | "base64-url-align0-padded" => b64_core(&URL_SAFE_NO_PAD, bytes, 0),
        "base64-url-align1" | "base64-url-align1-padded" => b64_core(&URL_SAFE_NO_PAD, bytes, 1),
        "base64-url-align2" | "base64-url-align2-padded" => b64_core(&URL_SAFE_NO_PAD, bytes, 2),
        "debug-array" => Some(format!("{bytes:?}")),
        "debug-array-compact" => Some(format!("{bytes:?}").replace(", ", ",")),
        "sha256-hex" => Some(digest_hex.to_owned()),
        "sha256-hex-prefix8" => digest_hex.get(..8).map(str::to_owned),
        "sha256-hex-prefix16" => digest_hex.get(..16).map(str::to_owned),
        other => unreachable!("byte label `{other}` has no encoder"),
    };
    (text, label.starts_with("base64-"))
}

/// Lower-hex digits, so the byte renderers need no per-byte allocation.
const HEX: &[u8; 16] = b"0123456789abcdef";

/// Renders bytes as hex with a separator and a per-byte prefix.
///
/// `padded` keeps the leading zero of a byte below `0x10`; dropping it is what
/// Dart's `toRadixString(16)` does and what Rust's `{:x?}` does, and the two
/// renderings of the same value are different strings.
fn render_bytes<I: Iterator<Item = u8>>(
    bytes: I,
    padded: bool,
    separator: &str,
    prefix: &str,
) -> String {
    let mut out = String::new();
    for (index, byte) in bytes.enumerate() {
        if index > 0 {
            out.push_str(separator);
        }
        out.push_str(prefix);
        if padded || byte >= 0x10 {
            out.push(char::from(HEX[usize::from(byte >> 4)]));
        }
        out.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    out
}

/// The alignment-stable core of a base64 rendering.
///
/// With `align` filler bytes ahead of the value in the encoded stream, the
/// value's bytes from index `3 - align` are group-aligned, so encoding whole
/// groups from there yields a string that is a substring of the real rendering
/// whatever the stream's length or padding.
fn b64_core<E: Engine>(engine: &E, bytes: &[u8], align: usize) -> Option<String> {
    let skip = (3 - align) % 3;
    let remaining = bytes.len().checked_sub(skip)?;
    let take = (remaining / 3) * 3;
    if take == 0 {
        return None;
    }
    Some(engine.encode(&bytes[skip..skip + take]))
}

/// The hint-free bech32 rendering for `hrp`.
fn bech32_form(hrp: &str, bytes: &[u8], upper: bool) -> Option<String> {
    let parsed = Hrp::parse(hrp).ok()?;
    // `nevent` and `nprofile` are TLV-framed even without hints: type 0,
    // length 32, the id. Everything else is the bare 32 bytes.
    let data: Vec<u8> = if matches!(hrp, "nevent" | "nprofile" | "naddr") {
        let mut tlv = Vec::with_capacity(bytes.len() + 2);
        tlv.push(0u8);
        tlv.push(u8::try_from(bytes.len()).ok()?);
        tlv.extend_from_slice(bytes);
        tlv
    } else {
        bytes.to_vec()
    };
    if upper {
        bech32::encode_upper::<bech32::Bech32>(parsed, &data).ok()
    } else {
        bech32::encode::<bech32::Bech32>(parsed, &data).ok()
    }
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

fn expand_text(sink: &mut Sink<'_>, value: &Declared) {
    let raw = value.raw.as_str();
    for form in TEXT_FORMS {
        let text = text_form(form, raw);
        sink.push(
            value,
            form,
            Some(text),
            false,
            "the declared value has no such rendering",
        );
    }
    for form in TEXT_FORMS {
        // ONE base64 layer over each string form. The composition space is
        // unbounded (`base64(hex(percent(x)))` is as real as any other); base64
        // gets the budget because base64 is the layer a Nostr `content` field
        // and an FFI error string actually carry.
        let layered = b64_core(&STANDARD_NO_PAD, text_form(form, raw).as_bytes(), 0);
        sink.push(
            value,
            &format!("{form}/base64"),
            layered,
            true,
            "the declared value is shorter than one base64 group",
        );
    }
    let chars: Vec<char> = raw.chars().collect();
    for k in 1..=NAME_DROPS {
        let text = chars
            .len()
            .checked_sub(k)
            .map(|keep| chars[..keep].iter().collect::<String>());
        sink.push(
            value,
            &format!("utf8-drop{k}"),
            text,
            false,
            "the declared value is shorter than this truncation drops",
        );
    }
}

/// One string form.
fn text_form(form: &str, raw: &str) -> String {
    match form {
        "utf8" => raw.to_owned(),
        "nfc" => raw.nfc().collect(),
        "nfd" => raw.nfd().collect(),
        "nfkc" => raw.nfkc().collect(),
        "nfkd" => raw.nfkd().collect(),
        "lower" => raw.to_lowercase(),
        "upper" => raw.to_uppercase(),
        // The `lower(upper(x))` approximation of full case folding: it is what
        // turns `ß` into `ss` without vendoring `CaseFolding.txt`. The fold the
        // app ACTUALLY applies is `search-fold`, ported in `crate::fold`.
        "casefold" => raw.to_uppercase().to_lowercase(),
        "search-fold" => search_fold(raw),
        "percent-component" => percent(raw, false),
        "percent-form" => percent(raw, true),
        "json-escaped" => json_escape(raw),
        // Dart's `String.fromCharCodes(utf8Bytes)`: every UTF-8 byte becomes one
        // code unit, so a name round-trips into mojibake that still identifies
        // its owner.
        "latin1-from-char-codes" => raw.bytes().map(char::from).collect(),
        other => unreachable!("text form `{other}` has no encoder"),
    }
}

/// Percent-encoding in Dart's two dialects: `Uri.encodeComponent` and, with
/// `form`, `Uri.encodeQueryComponent` (space becomes `+`).
fn percent(raw: &str, form: bool) -> String {
    let unreserved = if form {
        UNRESERVED_QUERY
    } else {
        UNRESERVED_COMPONENT
    };
    let mut out = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        if byte.is_ascii_alphanumeric() || unreserved.contains(&byte) {
            out.push(char::from(byte));
        } else if form && byte == b' ' {
            out.push('+');
        } else {
            out.push('%');
            out.push(char::from(HEX[usize::from(byte >> 4)].to_ascii_uppercase()));
            out.push(char::from(
                HEX[usize::from(byte & 0x0f)].to_ascii_uppercase(),
            ));
        }
    }
    out
}

/// JSON string escaping in its ASCII-safe dialect (`\uXXXX` for every non-ASCII
/// scalar), which is the form an ASCII-escaping encoder writes into a log.
fn json_escape(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_ascii_graphic() || c == ' ' => out.push(c),
            c => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    out.push_str("\\u");
                    for shift in [12, 8, 4, 0] {
                        out.push(char::from(HEX[usize::from((*unit >> shift) & 0xf)]));
                    }
                }
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Coordinate
// ---------------------------------------------------------------------------

fn expand_coordinate(sink: &mut Sink<'_>, value: &Declared) -> Result<(), String> {
    let (lat, lon) = value
        .raw
        .split_once(',')
        .ok_or_else(|| "class `coordinate` declared a value that is not `lat,lon`".to_owned())?;
    let axes = [("lat", lat.trim()), ("lon", lon.trim())];
    for (axis, declared) in axes {
        let parsed: f64 = declared.parse().map_err(|_| {
            format!("class `coordinate` declared a `{axis}` that is not a decimal number")
        })?;
        for label in AXIS_LABELS {
            let text = axis_encoding(label, declared, parsed);
            sink.push(
                value,
                &format!("{axis}/{label}"),
                text,
                false,
                "the declared axis has no such rendering",
            );
        }
    }
    for label in PAIR_LABELS {
        let (first, second) = if label.starts_with("pair-latlon") {
            (axes[0].1, axes[1].1)
        } else {
            (axes[1].1, axes[0].1)
        };
        let separator = match label.rsplit_once('/').map(|(_, s)| s) {
            Some("sep-comma") => ",",
            Some("sep-comma-space") => ", ",
            Some("sep-space") => " ",
            _ => unreachable!("pair label `{label}` has no separator"),
        };
        sink.push(
            value,
            label,
            Some(format!("{first}{separator}{second}")),
            false,
            "the declared coordinate has no such pair rendering",
        );
    }
    Ok(())
}

/// One axis rendering. `declared` keeps the precision the scenario declared;
/// `parsed` is only used where a rendering needs arithmetic.
fn axis_encoding(label: &str, declared: &str, parsed: f64) -> Option<String> {
    let negative = declared.starts_with('-');
    let unsigned = declared.trim_start_matches(['-', '+']);
    match label {
        "decimal-round4" => Some(format!("{parsed:.4}")),
        "decimal-round5" => Some(format!("{parsed:.5}")),
        "decimal-round6" => Some(format!("{parsed:.6}")),
        "decimal-round7" => Some(format!("{parsed:.7}")),
        "decimal-trunc4" => truncate_decimals(declared, 4),
        "decimal-trunc5" => truncate_decimals(declared, 5),
        "decimal-trunc6" => truncate_decimals(declared, 6),
        "decimal-trunc7" => truncate_decimals(declared, 7),
        "trimmed" => Some(trim_trailing_zeros(declared)),
        // Rust's `{:e}` and Dart's `toStringAsExponential()` disagree on the
        // exponent sign, and both appear in this tree's logs, so both are terms.
        "scientific" => Some(format!("{parsed:e}")),
        "scientific-dart" => Some(dart_exponential(parsed)),
        "comma-decimal" => Some(declared.replace('.', ",")),
        "unsigned" => Some(unsigned.to_owned()),
        "sign-plus" => {
            if negative {
                None
            } else {
                Some(format!("+{unsigned}"))
            }
        }
        other => unreachable!("axis label `{other}` has no encoder"),
    }
}

/// Truncates (never rounds) `declared` to `places` decimals, by string surgery
/// so no float rounding can invent a digit the log never held.
fn truncate_decimals(declared: &str, places: usize) -> Option<String> {
    let (whole, fraction) = declared.split_once('.')?;
    let kept = fraction.get(..places)?;
    Some(format!("{whole}.{kept}"))
}

fn trim_trailing_zeros(declared: &str) -> String {
    if !declared.contains('.') {
        return declared.to_owned();
    }
    let trimmed = declared.trim_end_matches('0');
    trimmed.trim_end_matches('.').to_owned()
}

/// Dart's `double.toStringAsExponential()` with no argument: the shortest
/// mantissa, a signed exponent with no zero padding.
fn dart_exponential(parsed: f64) -> String {
    let rust = format!("{parsed:e}");
    match rust.split_once('e') {
        Some((mantissa, exponent)) if exponent.starts_with('-') => format!("{mantissa}e{exponent}"),
        Some((mantissa, exponent)) => format!("{mantissa}e+{exponent}"),
        None => rust,
    }
}

// ---------------------------------------------------------------------------
// Geohash
// ---------------------------------------------------------------------------

fn expand_geohash(sink: &mut Sink<'_>, value: &Declared) {
    let raw = value.raw.trim();
    for label in geohash_labels(sink.policy.min_term_len) {
        let text = if label == "full" {
            Some(raw.to_owned())
        } else {
            label
                .strip_prefix("prefix")
                .and_then(|n| n.parse::<usize>().ok())
                .and_then(|n| raw.get(..n).map(str::to_owned))
        };
        sink.push(
            value,
            label,
            text,
            false,
            "the declared geohash is shorter than this precision",
        );
    }
}

// ---------------------------------------------------------------------------
// URL
// ---------------------------------------------------------------------------

/// The pieces of a URL the expander re-renders.
struct UrlParts {
    scheme: String,
    host: String,
    port: Option<String>,
    path: String,
}

fn split_url(raw: &str) -> Option<UrlParts> {
    let (scheme, rest) = raw.split_once("://")?;
    let (authority, path) = rest
        .find('/')
        .map_or((rest, ""), |at| (&rest[..at], &rest[at..]));
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() => {
            (h.to_owned(), Some(p.to_owned()))
        }
        _ => (authority.to_owned(), None),
    };
    Some(UrlParts {
        scheme: scheme.to_lowercase(),
        host,
        port,
        path: path.to_owned(),
    })
}

fn expand_url(sink: &mut Sink<'_>, value: &Declared) -> Result<(), String> {
    let raw = value.raw.trim();
    let parts = split_url(raw).ok_or_else(|| {
        format!(
            "class `{}` declared a value with no `scheme://host`",
            value.class
        )
    })?;
    for label in URL_LABELS {
        let text = url_encoding(label, raw, &parts);
        sink.push(
            value,
            label,
            text,
            false,
            "the declared URL has no such rendering",
        );
    }
    Ok(())
}

fn url_encoding(label: &str, raw: &str, parts: &UrlParts) -> Option<String> {
    let authority = parts.port.as_ref().map_or_else(
        || parts.host.clone(),
        |port| format!("{}:{port}", parts.host),
    );
    let rendered = format!("{}://{authority}{}", parts.scheme, parts.path);
    match label {
        "as-declared" => Some(raw.to_owned()),
        "no-trailing-slash" => Some(rendered.trim_end_matches('/').to_owned()),
        "trailing-slash" => Some(format!("{}/", rendered.trim_end_matches('/'))),
        "scheme-alt" => {
            alternate_scheme(&parts.scheme).map(|alt| format!("{alt}://{authority}{}", parts.path))
        }
        "host-only" => Some(parts.host.clone()),
        "host-upper" => Some(parts.host.to_uppercase()),
        "host-punycode" => idna::domain_to_ascii(&parts.host).ok(),
        "with-port" => {
            let port = parts
                .port
                .clone()
                .or_else(|| default_port(&parts.scheme).map(str::to_owned))?;
            Some(format!(
                "{}://{}:{port}{}",
                parts.scheme, parts.host, parts.path
            ))
        }
        "without-port" => Some(format!("{}://{}{}", parts.scheme, parts.host, parts.path)),
        "percent-encoded" => Some(percent(raw, false)),
        other => unreachable!("url label `{other}` has no encoder"),
    }
}

const fn alternate_scheme(scheme: &str) -> Option<&'static str> {
    Some(match scheme.as_bytes() {
        b"wss" => "ws",
        b"ws" => "wss",
        b"https" => "http",
        b"http" => "https",
        _ => return None,
    })
}

const fn default_port(scheme: &str) -> Option<&'static str> {
    Some(match scheme.as_bytes() {
        b"wss" | b"https" => "443",
        b"ws" | b"http" => "80",
        _ => return None,
    })
}

/// Every label the expander can emit for `class`, in expansion order.
///
/// The ledger reconciles against the labels the expander actually produced; this
/// is what lets a test assert that the two agree for every class in the policy.
#[must_use]
pub fn labels_for(policy: &Policy, spec: &ClassSpec) -> Vec<String> {
    let mut labels: Vec<String> = Vec::new();
    match spec.kind {
        ClassKind::Bytes => {
            labels.extend(BYTE_LABELS.iter().map(|&l| l.to_owned()));
            for hrp in &spec.bech32 {
                labels.push(format!("bech32-{hrp}"));
                labels.push(format!("bech32-{hrp}-upper"));
            }
            for hrp in &spec.bech32_tlv_gap {
                labels.push(format!("bech32-{hrp}-tlv-hint"));
            }
        }
        ClassKind::Text => {
            labels.extend(TEXT_FORMS.iter().map(|&f| f.to_owned()));
            labels.extend(TEXT_FORMS.iter().map(|f| format!("{f}/base64")));
            labels.extend((1..=NAME_DROPS).map(|k| format!("utf8-drop{k}")));
        }
        ClassKind::Coordinate => {
            for axis in ["lat", "lon"] {
                labels.extend(AXIS_LABELS.iter().map(|l| format!("{axis}/{l}")));
            }
            labels.extend(PAIR_LABELS.iter().map(|&l| l.to_owned()));
        }
        ClassKind::Geohash => labels.extend(
            geohash_labels(policy.min_term_len)
                .into_iter()
                .map(str::to_owned),
        ),
        ClassKind::Url => labels.extend(URL_LABELS.iter().map(|&l| l.to_owned())),
        ClassKind::Plant => {}
    }
    labels
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{
        expand, labels_for, Declared, DropKind, Expansion, BYTE_LABELS, NAME_DROPS,
        RAW_BYTE_LABELS, TEXT_FORMS,
    };
    use crate::policy::Policy;

    /// The synthetic fixture values. Never a real key, never a wire-canary value
    /// (see README.md's Fixtures section), and chosen so every encoding DIFFERS:
    /// the byte string contains a byte below `0x10` (so Dart's unpadded
    /// `toRadixString(16)` diverges from hex) and its base64 contains a `+` (so
    /// standard and URL-safe alphabets diverge).
    const BYTES_HEX: &str = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";
    const NAME: &str = "Kåre's Café";
    const COORD: &str = "-33.865143,151.209901";
    const GEOHASH: &str = "r3gx2f7k";
    const URL: &str = "wss://rëlay.fixture.invalid:7777/";

    /// What one label produced.
    #[derive(Debug, PartialEq, Eq)]
    enum Got {
        Term(String),
        Drop(DropKind),
    }

    fn outcomes(class: &str, raw: &str) -> (BTreeMap<String, Got>, Expansion) {
        let policy = Policy::load().expect("policy");
        let declared = vec![Declared {
            id: "v1".to_owned(),
            class: class.to_owned(),
            raw: raw.to_owned(),
        }];
        let expansion = expand(&policy, &declared).expect("expand");
        let mut map = BTreeMap::new();
        for term in &expansion.terms {
            map.insert(term.encoding.clone(), Got::Term(term.text.clone()));
        }
        for dropped in &expansion.dropped {
            map.insert(dropped.encoding.clone(), Got::Drop(dropped.kind));
        }
        (map, expansion)
    }

    /// Asserts the table is EXACTLY the produced label set, then every entry.
    ///
    /// Exactly, because a table that merely checked the labels it happens to list
    /// would let a new encoding land with no expected value and no reviewer.
    fn assert_table(class: &str, raw: &str, table: &[(&str, Got)]) {
        let (got, _) = outcomes(class, raw);
        let expected: BTreeMap<&str, &Got> = table.iter().map(|(l, g)| (*l, g)).collect();
        let produced: Vec<&str> = got.keys().map(String::as_str).collect();
        let declared: Vec<&str> = expected.keys().copied().collect();
        assert_eq!(
            produced, declared,
            "the expected-term table for `{class}` must name exactly the labels the expander produces"
        );
        for (label, want) in table {
            assert_eq!(
                got.get(*label),
                Some(want),
                "`{class}`/`{label}` does not render as expected"
            );
        }
    }

    fn term(text: &str) -> Got {
        Got::Term(text.to_owned())
    }

    const ALIAS: Got = Got::Drop(DropKind::Alias);
    const UNAVAILABLE: Got = Got::Drop(DropKind::Unavailable);
    const POLICY_GAP: Got = Got::Drop(DropKind::PolicyGap);

    /// Every byte label, asserted literally against values computed
    /// independently of this implementation.
    #[test]
    fn every_byte_label_renders_exactly() {
        assert_table(
            "pubkey",
            BYTES_HEX,
            &[
                ("base64-std-align0", term("ChssPU5fYHGCk6S1xtfo+QobLD1OX2BxgpOktcbX")),
                ("base64-std-align0-padded", ALIAS),
                ("base64-std-align1", term("LD1OX2BxgpOktcbX6PkKGyw9Tl9gcYKTpLXG1+j5")),
                ("base64-std-align1-padded", ALIAS),
                ("base64-std-align2", term("Gyw9Tl9gcYKTpLXG1+j5ChssPU5fYHGCk6S1xtfo")),
                ("base64-std-align2-padded", ALIAS),
                ("base64-url-align0", term("ChssPU5fYHGCk6S1xtfo-QobLD1OX2BxgpOktcbX")),
                ("base64-url-align0-padded", ALIAS),
                ("base64-url-align1", term("LD1OX2BxgpOktcbX6PkKGyw9Tl9gcYKTpLXG1-j5")),
                ("base64-url-align1-padded", ALIAS),
                ("base64-url-align2", term("Gyw9Tl9gcYKTpLXG1-j5ChssPU5fYHGCk6S1xtfo")),
                ("base64-url-align2-padded", ALIAS),
                ("bech32-npub", term("npub1pgdjc02wtas8rq5n5j6ud4lgly9pktpafe0kquvzjwjtt3kharusk0rcun")),
                ("bech32-npub-upper", ALIAS),
                ("bech32-nprofile-tlv-hint", POLICY_GAP),
                (
                    "dart-radix16-unpadded",
                    term("a1b2c3d4e5f60718293a4b5c6d7e8f9a1b2c3d4e5f60718293a4b5c6d7e8f9"),
                ),
                (
                    "debug-array",
                    term("[10, 27, 44, 61, 78, 95, 96, 113, 130, 147, 164, 181, 198, 215, 232, 249, 10, 27, 44, 61, 78, 95, 96, 113, 130, 147, 164, 181, 198, 215, 232, 249]"),
                ),
                (
                    "debug-array-compact",
                    term("[10,27,44,61,78,95,96,113,130,147,164,181,198,215,232,249,10,27,44,61,78,95,96,113,130,147,164,181,198,215,232,249]"),
                ),
                ("hex-lower", term(BYTES_HEX)),
                ("hex-prefix12", term("0a1b2c3d4e5f")),
                ("hex-prefix16", term("0a1b2c3d4e5f6071")),
                ("hex-prefix8", term("0a1b2c3d")),
                (
                    "hex-reversed-bytes",
                    term("f9e8d7c6b5a4938271605f4e3d2c1b0af9e8d7c6b5a4938271605f4e3d2c1b0a"),
                ),
                (
                    "hex-spaced",
                    term("0a 1b 2c 3d 4e 5f 60 71 82 93 a4 b5 c6 d7 e8 f9 0a 1b 2c 3d 4e 5f 60 71 82 93 a4 b5 c6 d7 e8 f9"),
                ),
                ("hex-upper", ALIAS),
                (
                    "rust-debug-02x",
                    term("[0a, 1b, 2c, 3d, 4e, 5f, 60, 71, 82, 93, a4, b5, c6, d7, e8, f9, 0a, 1b, 2c, 3d, 4e, 5f, 60, 71, 82, 93, a4, b5, c6, d7, e8, f9]"),
                ),
                (
                    "rust-debug-alt-x",
                    term("0xa, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f, 0x60, 0x71, 0x82, 0x93, 0xa4, 0xb5, 0xc6, 0xd7, 0xe8, 0xf9, 0xa, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f, 0x60, 0x71, 0x82, 0x93, 0xa4, 0xb5, 0xc6, 0xd7, 0xe8, 0xf9"),
                ),
                ("rust-debug-upper-x", ALIAS),
                (
                    "rust-debug-x",
                    term("[a, 1b, 2c, 3d, 4e, 5f, 60, 71, 82, 93, a4, b5, c6, d7, e8, f9, a, 1b, 2c, 3d, 4e, 5f, 60, 71, 82, 93, a4, b5, c6, d7, e8, f9]"),
                ),
                (
                    "sha256-hex",
                    term("0999fa4e23e7356c7507cfa0281250ec238e4856eff238cb0b500e155e88f46b"),
                ),
                ("sha256-hex-prefix16", term("0999fa4e23e7356c")),
                ("sha256-hex-prefix8", term("0999fa4e")),
            ],
        );
    }

    /// An `event_id` carries the two hint-free bech32 forms a NIP-19 reader
    /// writes, and records the hinted one as a gap.
    #[test]
    fn an_event_id_expands_note_and_hint_free_nevent() {
        let (got, _) = outcomes("event_id", BYTES_HEX);
        assert_eq!(
            got.get("bech32-note"),
            Some(&term(
                "note1pgdjc02wtas8rq5n5j6ud4lgly9pktpafe0kquvzjwjtt3kharus89q99m"
            ))
        );
        assert_eq!(
            got.get("bech32-nevent"),
            Some(&term(
                "nevent1qqsq5xev84897cr3s2f6fdwx6l50jzsm9s75uhmqwxpf8f94cmt737gym0vzh"
            ))
        );
        assert_eq!(got.get("bech32-nevent-tlv-hint"), Some(&POLICY_GAP));
    }

    /// A secret class serialises the commitment and nothing else.
    #[test]
    fn a_secret_class_withholds_every_raw_rendering() {
        let (got, expansion) = outcomes("nsec", BYTES_HEX);
        assert_eq!(
            got.get("sha256-hex"),
            Some(&term(
                "0999fa4e23e7356c7507cfa0281250ec238e4856eff238cb0b500e155e88f46b"
            ))
        );
        assert_eq!(got.get("hex-lower"), Some(&POLICY_GAP));
        assert_eq!(got.get("bech32-nsec"), Some(&POLICY_GAP));
        // Nothing searchable may contain the raw value in ANY encoding.
        for forbidden in [
            BYTES_HEX,
            "npub1pgdjc02wtas8rq5n5j6ud4lgly9pktpafe0kquvzjwjtt3kharusk0rcun",
            "nsec1pgdjc02wtas8rq5n5j6ud4lgly9pktpafe0kquvzjwjtt3kharus6ege6x",
            "ChssPU5fYHGCk6S1xtfo+QobLD1OX2BxgpOktcbX",
        ] {
            assert!(
                !expansion.terms.iter().any(|t| t.text.contains(forbidden)),
                "a secret-class term must not carry the raw value"
            );
        }
        for dropped in &expansion.dropped {
            if dropped.kind == DropKind::PolicyGap {
                assert_eq!(dropped.reason, "secret-class raw never serialised");
            }
        }
    }

    #[test]
    fn every_string_label_renders_exactly() {
        assert_table(
            "circle_name",
            NAME,
            &[
                ("casefold", ALIAS),
                ("casefold/base64", ALIAS),
                ("json-escaped", term("K\\u00e5re's Caf\\u00e9")),
                ("json-escaped/base64", term("S1x1MDBlNXJlJ3MgQ2FmXHUwMGU5")),
                ("latin1-from-char-codes", term("KÃ¥re's CafÃ©")),
                (
                    "latin1-from-char-codes/base64",
                    term("S8ODwqVyZSdzIENhZsOD"),
                ),
                // `lower` folds only the ASCII letters of this name, which is
                // exactly what the case-insensitive automaton already does to
                // `utf8` — so it is an alias, while `upper` (which moves the
                // `Å` and the `É`) is a term of its own.
                ("lower", ALIAS),
                ("lower/base64", term("a8OlcmUncyBjYWbD")),
                ("nfc", ALIAS),
                ("nfc/base64", ALIAS),
                ("nfd", term("Ka\u{30a}re's Cafe\u{301}")),
                ("nfd/base64", term("S2HMinJlJ3MgQ2FmZcyB")),
                ("nfkc", ALIAS),
                ("nfkc/base64", ALIAS),
                ("nfkd", ALIAS),
                ("nfkd/base64", ALIAS),
                ("percent-component", term("K%C3%A5re's%20Caf%C3%A9")),
                (
                    "percent-component/base64",
                    term("SyVDMyVBNXJlJ3MlMjBDYWYlQzMl"),
                ),
                // `%27` for the apostrophe: the query dialect's unreserved set
                // is RFC 3986's `-._~`, not `encodeComponent`'s.
                ("percent-form", term("K%C3%A5re%27s+Caf%C3%A9")),
                ("percent-form/base64", term("SyVDMyVBNXJlJTI3cytDYWYlQzMl")),
                ("search-fold", term("kare's cafe")),
                ("search-fold/base64", term("a2FyZSdzIGNh")),
                ("upper", term("KÅRE'S CAFÉ")),
                ("upper/base64", term("S8OFUkUnUyBDQUbD")),
                ("utf8", term(NAME)),
                ("utf8-drop1", term("Kåre's Caf")),
                ("utf8-drop2", term("Kåre's Ca")),
                ("utf8-drop3", term("Kåre's C")),
                ("utf8-drop4", term("Kåre's ")),
                ("utf8/base64", term("S8OlcmUncyBDYWbD")),
            ],
        );
    }

    #[test]
    fn every_coordinate_label_renders_exactly() {
        assert_table(
            "coordinate",
            COORD,
            &[
                // `lat/decimal-round3` and `lat/decimal-trunc3` are absent, not
                // dropped: a 3-decimal single axis collides with a duration, so
                // the ledger declares the four labels out of scope.
                ("lat/comma-decimal", term("-33,865143")),
                ("lat/decimal-round4", term("-33.8651")),
                ("lat/decimal-round5", term("-33.86514")),
                ("lat/decimal-round6", term("-33.865143")),
                ("lat/decimal-round7", term("-33.8651430")),
                ("lat/decimal-trunc4", ALIAS),
                ("lat/decimal-trunc5", ALIAS),
                ("lat/decimal-trunc6", ALIAS),
                ("lat/decimal-trunc7", UNAVAILABLE),
                ("lat/scientific", term("-3.3865143e1")),
                ("lat/scientific-dart", term("-3.3865143e+1")),
                ("lat/sign-plus", UNAVAILABLE),
                ("lat/trimmed", ALIAS),
                ("lat/unsigned", term("33.865143")),
                ("lon/comma-decimal", term("151,209901")),
                ("lon/decimal-round4", term("151.2099")),
                ("lon/decimal-round5", term("151.20990")),
                ("lon/decimal-round6", term("151.209901")),
                ("lon/decimal-round7", term("151.2099010")),
                ("lon/decimal-trunc4", ALIAS),
                ("lon/decimal-trunc5", ALIAS),
                ("lon/decimal-trunc6", ALIAS),
                ("lon/decimal-trunc7", UNAVAILABLE),
                ("lon/scientific", term("1.51209901e2")),
                ("lon/scientific-dart", term("1.51209901e+2")),
                ("lon/sign-plus", term("+151.209901")),
                ("lon/trimmed", ALIAS),
                ("lon/unsigned", ALIAS),
                ("pair-latlon/sep-comma", term("-33.865143,151.209901")),
                (
                    "pair-latlon/sep-comma-space",
                    term("-33.865143, 151.209901"),
                ),
                ("pair-latlon/sep-space", term("-33.865143 151.209901")),
                ("pair-lonlat/sep-comma", term("151.209901,-33.865143")),
                (
                    "pair-lonlat/sep-comma-space",
                    term("151.209901, -33.865143"),
                ),
                ("pair-lonlat/sep-space", term("151.209901 -33.865143")),
            ],
        );
    }

    #[test]
    fn every_geohash_label_renders_exactly() {
        assert_table(
            "geohash",
            GEOHASH,
            &[
                // `prefix4` and `prefix5` are absent, not dropped: they are
                // below the global term floor for EVERY value, so the ledger
                // declares them out of scope rather than covered.
                ("full", term("r3gx2f7k")),
                ("prefix6", term("r3gx2f")),
                ("prefix7", term("r3gx2f7")),
                ("prefix8", ALIAS),
            ],
        );
    }

    #[test]
    fn every_url_label_renders_exactly() {
        assert_table(
            "relay_url",
            URL,
            &[
                ("as-declared", term("wss://rëlay.fixture.invalid:7777/")),
                ("host-only", term("rëlay.fixture.invalid")),
                ("host-punycode", term("xn--rlay-lpa.fixture.invalid")),
                ("host-upper", term("RËLAY.FIXTURE.INVALID")),
                (
                    "no-trailing-slash",
                    term("wss://rëlay.fixture.invalid:7777"),
                ),
                (
                    "percent-encoded",
                    term("wss%3A%2F%2Fr%C3%ABlay.fixture.invalid%3A7777%2F"),
                ),
                ("scheme-alt", term("ws://rëlay.fixture.invalid:7777/")),
                ("trailing-slash", ALIAS),
                ("with-port", ALIAS),
                ("without-port", term("wss://rëlay.fixture.invalid/")),
            ],
        );
    }

    /// A URL with no port gets the scheme's default port added, and a URL with
    /// one gets it removed. Both directions, because a log can hold either.
    /// The two percent dialects on a name that distinguishes them.
    ///
    /// `Kai's Circle` is an ordinary circle name and the apostrophe is exactly
    /// where `encodeComponent` and `encodeQueryComponent` disagree, so one set
    /// for both dialects would have left the query rendering unsearched.
    #[test]
    fn the_two_percent_dialects_differ_on_an_apostrophe() {
        let (got, _) = outcomes("circle_name", "Kai's Circle");
        assert_eq!(got.get("percent-component"), Some(&term("Kai's%20Circle")));
        assert_eq!(got.get("percent-form"), Some(&term("Kai%27s+Circle")));
        assert_eq!(
            got.get("percent-component/base64"),
            Some(&term("S2FpJ3MlMjBDaXJj"))
        );
        assert_eq!(
            got.get("percent-form/base64"),
            Some(&term("S2FpJTI3cytDaXJj"))
        );
    }

    /// The single-axis ladders start at four decimals, and say so in the ledger.
    ///
    /// A 3-decimal axis is six characters — `47.209` matched a millisecond
    /// duration in a relay log on CI run 34766632019 — so the two labels per
    /// axis are not produced at all rather than produced and later forgiven by
    /// an allowlist, which would forgive the real coordinate too.
    #[test]
    fn the_axis_ladders_start_at_four_decimals() {
        let policy = Policy::load().expect("policy");
        let spec = policy.class("coordinate").expect("class");
        let labels = labels_for(&policy, spec);
        for below in [
            "lat/decimal-round3",
            "lat/decimal-trunc3",
            "lon/decimal-round3",
            "lon/decimal-trunc3",
        ] {
            assert!(
                !labels.contains(&below.to_owned()),
                "`{below}` must not be produced"
            );
            assert!(
                policy.ledger["coordinate"]
                    .not_gaps
                    .get(below)
                    .is_some_and(|reason| reason.contains("collides with durations")),
                "`{below}` must be declared out of scope, with the reason"
            );
        }
        // The pair renderings are untouched: two axes and a separator cannot be
        // a duration, so a 3-decimal pair stays searchable.
        let (got, _) = outcomes("coordinate", "47.209,-122.331");
        assert_eq!(
            got.get("pair-latlon/sep-comma"),
            Some(&term("47.209,-122.331"))
        );
    }

    /// The geohash ladder starts at the floor, and says so in the ledger.
    #[test]
    fn the_geohash_ladder_starts_at_the_global_term_floor() {
        let policy = Policy::load().expect("policy");
        let spec = policy.class("geohash").expect("class");
        let labels = labels_for(&policy, spec);
        assert_eq!(
            labels,
            vec![
                "full".to_owned(),
                "prefix6".to_owned(),
                "prefix7".to_owned(),
                "prefix8".to_owned()
            ],
            "a prefix below min_term_len is unsearchable for every value and must not be produced"
        );
        for below in ["prefix4", "prefix5"] {
            assert!(
                policy.ledger["geohash"].not_gaps.contains_key(below),
                "`{below}` must be declared out of scope, with the reason"
            );
        }
    }

    #[test]
    fn the_port_ladder_runs_in_both_directions() {
        let (got, _) = outcomes("blossom_url", "https://blossom.fixture.invalid/media");
        assert_eq!(
            got.get("with-port"),
            Some(&term("https://blossom.fixture.invalid:443/media"))
        );
        assert_eq!(got.get("without-port"), Some(&ALIAS));
        assert_eq!(
            got.get("scheme-alt"),
            Some(&term("http://blossom.fixture.invalid/media"))
        );
    }

    #[test]
    fn a_term_identical_to_sink_furniture_is_dropped() {
        // A scenario that names a circle "flutter" cannot be searched for: the
        // word is on every line of the capture anyway.
        let (got, _) = outcomes("circle_name", "flutter");
        assert_eq!(got.get("utf8"), Some(&UNAVAILABLE));
        let (got, _) = outcomes("circle_name", "Quiet Wanderer");
        assert_eq!(got.get("utf8"), Some(&term("Quiet Wanderer")));
    }

    #[test]
    fn a_short_name_drops_the_prefixes_it_cannot_carry() {
        // Five characters: the utf8 term itself is below the floor, and so is
        // every truncation of it. Recorded, never silent.
        let (got, _) = outcomes("petname", "Çağrı");
        assert_eq!(got.get("utf8"), Some(&UNAVAILABLE));
        for k in 1..=NAME_DROPS {
            assert_eq!(got.get(&format!("utf8-drop{k}")), Some(&UNAVAILABLE));
        }
    }

    #[test]
    fn every_label_produces_either_a_term_or_a_recorded_drop() {
        // The invariant the ledger depends on: a label that produced neither
        // would be invisible to reconciliation, to the report and to every check
        // written over those two lists.
        let policy = Policy::load().expect("policy");
        for (class, raw) in [
            ("pubkey", BYTES_HEX),
            ("nsec", BYTES_HEX),
            ("event_id", BYTES_HEX),
            ("circle_name", NAME),
            ("coordinate", COORD),
            ("geohash", GEOHASH),
            ("relay_url", URL),
        ] {
            let (got, _) = outcomes(class, raw);
            let spec = policy.class(class).expect("class");
            let mut expected = labels_for(&policy, spec);
            expected.sort_unstable();
            let mut produced: Vec<String> = got.keys().cloned().collect();
            produced.sort_unstable();
            assert_eq!(produced, expected, "`{class}` label set");
        }
    }

    /// The secret-class boundary, pinned positionally AND by name.
    ///
    /// `RAW_BYTE_LABELS` is an index, and an index that drifts by one turns a
    /// withheld `nsec` rendering into a searchable term — a secret written into
    /// the manifest. Two independent statements of the same boundary, so one
    /// cannot move without the other.
    #[test]
    fn the_raw_byte_boundary_is_where_the_commitment_starts() {
        assert_eq!(BYTE_LABELS[RAW_BYTE_LABELS], "sha256-hex");
        assert!(
            BYTE_LABELS[..RAW_BYTE_LABELS]
                .iter()
                .all(|label| !label.starts_with("sha256-")),
            "every label below the boundary renders the raw value"
        );
        assert!(
            BYTE_LABELS[RAW_BYTE_LABELS..]
                .iter()
                .all(|label| label.starts_with("sha256-")),
            "every label at or above it renders the commitment"
        );
    }

    #[test]
    fn the_text_form_count_is_what_the_ledger_was_written_against() {
        // Pinned: adding a form without extending the ledger must fail, and the
        // ledger is 13 forms + 13 base64 layers + 4 truncations per text class.
        assert_eq!(TEXT_FORMS.len(), 13);
        assert_eq!(NAME_DROPS, 4);
    }

    #[test]
    fn a_declared_value_that_does_not_match_its_class_is_a_guard_failure() {
        let policy = Policy::load().expect("policy");
        for (class, raw) in [
            ("pubkey", "not-hex-at-all"),
            ("coordinate", "somewhere"),
            ("coordinate", "12.3"),
            ("relay_url", "relay.example.com"),
        ] {
            let declared = vec![Declared {
                id: "v1".to_owned(),
                class: class.to_owned(),
                raw: raw.to_owned(),
            }];
            assert!(
                expand(&policy, &declared).is_err(),
                "`{class}` must reject `{raw}`"
            );
        }
    }

    #[test]
    fn a_bech32_declaration_is_accepted_for_a_key_class() {
        // The harness declares what it has: `npub1…` from the UI, hex from the
        // FFI. Both must expand to the same term set.
        let (from_hex, _) = outcomes("pubkey", BYTES_HEX);
        let (from_npub, _) = outcomes(
            "pubkey",
            "npub1pgdjc02wtas8rq5n5j6ud4lgly9pktpafe0kquvzjwjtt3kharusk0rcun",
        );
        assert_eq!(from_hex.get("hex-lower"), from_npub.get("hex-lower"));
    }
}
