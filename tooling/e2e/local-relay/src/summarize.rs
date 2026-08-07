//! The upload-safe, redacted view of a wire journal.
//!
//! # Why this exists
//!
//! The raw journal is a complete transcript: full event JSON (ciphertext,
//! ephemeral pubkeys, ids, signatures), REQ filters carrying long-term
//! identity pubkeys, and now `relay_url`, which maps that traffic to named
//! endpoints. CI uploads lane logs as artifacts with 14-day retention, which
//! would turn a privacy instrument into a durable privacy hazard, so the raw
//! journal is NEVER uploaded (`scripts/ci/check_wire_proxy_test_only.sh`
//! enforces that) and this redacted summary is uploaded instead.
//!
//! # Redaction is an ALLOWLIST, not a filter
//!
//! Nothing is "stripped". Each output line is BUILT from a fixed set of
//! fields, so a future addition to the journal cannot leak by default — an
//! unmodelled field is simply absent. What survives:
//!
//! | kept | dropped |
//! |---|---|
//! | `wire_seq`, `conn_id`, `dir`, `type`, `raw_len` | — |
//! | `relay_url`, `listen` (lane infrastructure) | — |
//! | event `kind`, tag NAMES | event `id`, `pubkey`, `sig`, `content`, tag VALUES |
//! | `content_len` | `content` |
//! | REQ filter KEY names and `kinds` values | `authors`, `#p`, `#h`, `ids`, every other filter value |
//! | `ok` boolean, subscription-id PRESENCE | subscription id, NOTICE/CLOSED text |
//! | `preview_len` | `raw_preview` |
//!
//! Tag values are dropped because `["p", <pubkey>]` and `["h",
//! <nostr_group_id>]` are exactly the identifiers a wire journal must not
//! outlive its lane with. Filter values are dropped for the same reason.
//! `kinds` survives because a kind number carries no identity and is the
//! single most useful thing in a triage transcript.
//!
//! # The allowlist is over FIELDS; the surviving VALUES need their own bound
//!
//! Choosing which fields survive stops an unmodelled field leaking. It does
//! nothing about a modelled field whose value is remote-controlled, and three
//! are: a frame's verb, a tag's NAME and a REQ filter's KEY are all copied out
//! of arbitrary attacker-shaped JSON. `["<64-hex pubkey>", …]` is a
//! structurally valid frame, so its "verb" is a pubkey — and a value
//! containing a newline could forge whole summary lines, including the totals.
//!
//! Every such value therefore goes through [`safe_token`]: bounded length and
//! a fixed character class, REJECTED rather than truncated, because a 20-char
//! prefix of a pubkey is still an identifier while `INVALID(len=64)` is not.

use std::collections::BTreeSet;
use std::fmt::Write as _;

use serde_json::Value;

/// Longest verb / tag name / filter key echoed verbatim into the summary.
///
/// Every Nostr verb is far shorter; the longest thing that legitimately
/// reaches here is the sentinel's own `HAVEN_WIRE_SENTINEL` (19).
const TOKEN_MAX: usize = 20;

/// Longest `conn_error` reason echoed verbatim.
const REASON_MAX: usize = 48;

/// Counts reported after a summarize run.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SummaryStats {
    /// Lines read from the journal.
    pub lines: u64,
    /// Lines that did not parse as JSON (reported, never dropped).
    pub malformed: u64,
    /// Traffic lines whose `frame` was `null` — findings.
    pub unparseable_frames: u64,
}

/// Renders one redacted line for each journal line.
///
/// A journal line that is not valid JSON is itself reported as
/// `MALFORMED-JOURNAL-LINE` with its byte length only — never its content.
#[must_use]
pub fn summarize(journal: &str) -> (String, SummaryStats) {
    let mut out = String::new();
    let mut stats = SummaryStats::default();

    out.push_str(
        "# haven wire-journal summary (redacted: no ids, pubkeys, signatures, \
         content, tag values or filter values)\n",
    );

    for line in journal.lines() {
        if line.trim().is_empty() {
            continue;
        }
        stats.lines += 1;
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            // A torn write or a truncated file. REPORTED, never skipped:
            // skipping would hide exactly the truncation a fail-closed oracle
            // needs to see, and the content is never echoed.
            stats.malformed += 1;
            let _ = writeln!(out, "MALFORMED-JOURNAL-LINE bytes={}", line.len());
            continue;
        };
        if value
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|t| t == crate::journal::TYPE_FRAME)
            && value.get("frame").is_some_and(Value::is_null)
        {
            stats.unparseable_frames += 1;
        }
        out.push_str(&summarize_line(&value));
        out.push('\n');
    }

    let _ = writeln!(
        out,
        "# totals lines={} malformed={} unparseable_frames={}",
        stats.lines, stats.malformed, stats.unparseable_frames
    );
    (out, stats)
}

fn summarize_line(value: &Value) -> String {
    let mut out = String::new();
    let _ = write!(
        out,
        "seq={} type={} conn={} relay={} listen={}",
        num(value, "wire_seq"),
        text(value, "type"),
        text(value, "conn_id"),
        text(value, "relay_url"),
        text(value, "listen"),
    );

    if let Some(reason) = value.get("reason").and_then(Value::as_str) {
        // A fixed label chosen by the proxy — but this reads a FILE, which may
        // be stale, hand-made or foreign, so the label is bounded here rather
        // than trusted.
        let _ = write!(out, " reason=\"{}\"", safe_reason(reason));
    }
    if value.get("discarded").is_some() {
        // How many journalled frames on this connection never left the proxy:
        // a count, so it cannot identify anything, and load-bearing — it is
        // the journal retracting a delivery claim it already made.
        let _ = write!(out, " discarded={}", num(value, "discarded"));
    }
    if value.get("dir").is_some() {
        let _ = write!(out, " dir={}", text(value, "dir"));
    }
    if value.get("raw_len").is_some() {
        // Through `num`, like every adjacent numeric field: a non-conforming
        // journal must not get a string reproduced verbatim here.
        let _ = write!(out, " raw_len={}", num(value, "raw_len"));
    }
    if let Some(preview) = value.get("raw_preview").and_then(Value::as_str) {
        // LENGTH only. The preview is a bounded slice of an unparseable
        // payload, which is precisely where unexpected plaintext would be.
        let _ = write!(out, " preview_len={}", preview.len());
    }

    match value.get("frame") {
        None => {}
        Some(Value::Null) => out.push_str(" frame=NULL(unparseable)"),
        Some(frame) => {
            out.push(' ');
            out.push_str(&summarize_frame(frame));
        }
    }

    out
}

fn summarize_frame(frame: &Value) -> String {
    let Some(array) = frame.as_array() else {
        return "verb=?".to_owned();
    };
    // `frame[0]` is whatever the peer put there. The producer keeps `frame`
    // for ANY array with a string first element — deliberately, so a novel
    // verb stays visible to an oracle — which means this string is arbitrary
    // remote-controlled text and must be bounded before it is printed.
    let raw_verb = array.first().and_then(Value::as_str);
    let mut out = format!(
        "verb={}",
        raw_verb.map_or_else(|| "?".to_owned(), safe_token)
    );

    match raw_verb.unwrap_or("?") {
        "EVENT" => {
            // The event object is at [1] for a client publish and [2] for a
            // relay delivery; take whichever is an object.
            if let Some(event) = array.iter().find(|v| v.is_object()) {
                let _ = write!(out, " kind={}", num(event, "kind"));
                let _ = write!(out, " tags=[{}]", tag_names(event));
                let content_len = event
                    .get("content")
                    .and_then(Value::as_str)
                    .map_or(0, str::len);
                let _ = write!(out, " content_len={content_len}");
                let _ = write!(
                    out,
                    " signed={}",
                    event.get("sig").and_then(Value::as_str).is_some()
                );
            }
        }
        "REQ" => {
            let mut keys = BTreeSet::new();
            let mut kinds = BTreeSet::new();
            for filter in array.iter().filter_map(Value::as_object) {
                for (key, value) in filter {
                    keys.insert(key.as_str());
                    if key == "kinds" {
                        if let Some(list) = value.as_array() {
                            for kind in list.iter().filter_map(Value::as_u64) {
                                kinds.insert(kind);
                            }
                        }
                    }
                }
            }
            let _ = write!(
                out,
                " filter_keys=[{}] kinds=[{}]",
                joined(keys.iter().map(|k| safe_token(k))),
                joined(kinds.iter().map(u64::to_string)),
            );
        }
        "OK" => {
            let accepted = array.get(2).and_then(Value::as_bool);
            let _ = write!(
                out,
                " accepted={}",
                accepted.map_or_else(|| "?".to_owned(), |a| a.to_string())
            );
        }
        // CLOSE / EOSE / NOTICE / CLOSED / AUTH and any unknown verb: the verb
        // itself is the whole signal. A NOTICE's text and a CLOSED's reason are
        // relay-authored and can quote an event id, so only the length survives.
        _ => {
            let text_len: usize = array
                .iter()
                .skip(1)
                .filter_map(Value::as_str)
                .map(str::len)
                .sum();
            if text_len > 0 {
                let _ = write!(out, " text_len={text_len}");
            }
        }
    }

    out
}

/// Tag NAMES only — and bounded, because a tag name is as remote-controlled
/// as a verb: `[["<64-hex>","x"]]` is a well-formed tag whose name is a
/// pubkey.
fn tag_names(event: &Value) -> String {
    let mut names = BTreeSet::new();
    if let Some(tags) = event.get("tags").and_then(Value::as_array) {
        for tag in tags {
            if let Some(name) = tag
                .as_array()
                .and_then(|t| t.first())
                .and_then(Value::as_str)
            {
                names.insert(safe_token(name));
            }
        }
    }
    joined(names.iter().map(String::as_str))
}

/// Renders one remote-controlled token safe for the summary.
///
/// REJECTS rather than truncates. Truncating a 64-hex pubkey to fit would
/// still emit a 20-hex prefix, which is every bit as much an identifier;
/// `INVALID(len=64)` carries only a length, which the summary already
/// publishes for content and previews. The character class additionally keeps
/// a value from containing a newline and forging summary lines — including
/// the totals line a reader trusts.
fn safe_token(raw: &str) -> String {
    let len = raw.chars().count();
    if len == 0 || len > TOKEN_MAX || !raw.chars().all(is_token_char) {
        return format!("INVALID(len={len})");
    }
    raw.to_owned()
}

/// `#` is included because NIP-01 tag filters are literally `#p`, `#e`, `#h`.
const fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '#')
}

/// Same treatment for a `conn_error` reason: the producer only ever writes a
/// fixed label, but this reads a file rather than the producer.
fn safe_reason(raw: &str) -> String {
    let len = raw.chars().count();
    if len == 0 || len > REASON_MAX || !raw.chars().all(is_reason_char) {
        return format!("INVALID(len={len})");
    }
    raw.to_owned()
}

const fn is_reason_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, ' ' | '-' | '_' | ':')
}

fn joined<I, S>(items: I) -> String
where
    I: Iterator<Item = S>,
    S: AsRef<str>,
{
    items
        .map(|s| s.as_ref().to_owned())
        .collect::<Vec<_>>()
        .join(",")
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("-")
        .to_owned()
}

fn num(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_u64)
        .map_or_else(|| "-".to_owned(), |n| n.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A realistic kind-445 publish, with every field a real one carries.
    const EVENT_LINE: &str = concat!(
        r#"{"wire_seq":4,"type":"frame","conn_id":"c1","ts_ms":1785886144123,"#,
        r#""dir":"c2r","relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
        r#""frame":["EVENT",{"id":"a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2","#,
        r#""pubkey":"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d","#,
        r#""kind":445,"created_at":1785886144,"tags":[["h","deadbeefdeadbeefdeadbeefdeadbeef"],"#,
        r#"["expiration","1785886372"]],"content":"BASE64CIPHERTEXT==","#,
        r#""sig":"ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"}],"#,
        r#""raw_len":420}"#,
    );

    const REQ_LINE: &str = concat!(
        r#"{"wire_seq":5,"type":"frame","conn_id":"c1","ts_ms":1,"dir":"c2r","#,
        r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
        r##""frame":["REQ","sub-9",{"kinds":[1059],"#p":"##,
        r#"["3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"],"limit":50}],"#,
        r#""raw_len":140}"#,
    );

    fn summary_of(lines: &[&str]) -> String {
        summarize(&lines.join("\n")).0
    }

    // The load-bearing test: nothing identifying may survive into the artifact.
    #[test]
    fn no_identifier_survives_into_the_summary() {
        let summary = summary_of(&[EVENT_LINE, REQ_LINE]);
        for secret in [
            "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2", // event id
            "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", // pubkey
            "ffeeddccbbaa99887766554433221100",                                 // sig prefix
            "deadbeefdeadbeefdeadbeefdeadbeef",                                 // nostr_group_id
            "BASE64CIPHERTEXT",                                                 // content
            "sub-9",                                                            // subscription id
            "1785886372",                                                       // expiration VALUE
        ] {
            assert!(
                !summary.contains(secret),
                "summary leaked '{secret}':\n{summary}"
            );
        }
    }

    #[test]
    fn an_event_keeps_kind_tag_names_and_content_length() {
        let summary = summary_of(&[EVENT_LINE]);
        assert!(summary.contains("verb=EVENT"), "{summary}");
        assert!(summary.contains("kind=445"), "{summary}");
        assert!(
            summary.contains("tags=[expiration,h]"),
            "tag NAMES survive, values do not: {summary}"
        );
        assert!(summary.contains("content_len=18"), "{summary}");
        assert!(summary.contains("signed=true"), "{summary}");
    }

    #[test]
    fn a_req_keeps_filter_key_names_and_kinds_only() {
        let summary = summary_of(&[REQ_LINE]);
        assert!(summary.contains("verb=REQ"), "{summary}");
        assert!(
            summary.contains("filter_keys=[#p,kinds,limit]"),
            "{summary}"
        );
        assert!(summary.contains("kinds=[1059]"), "{summary}");
    }

    #[test]
    fn endpoint_and_ordering_fields_survive_because_containment_needs_them() {
        let summary = summary_of(&[EVENT_LINE]);
        assert!(summary.contains("seq=4"), "{summary}");
        assert!(summary.contains("conn=c1"), "{summary}");
        assert!(summary.contains("dir=c2r"), "{summary}");
        assert!(summary.contains("relay=ws://127.0.0.1:7777"), "{summary}");
        assert!(summary.contains("listen=127.0.0.1:7788"), "{summary}");
    }

    #[test]
    fn an_unparseable_frame_is_flagged_and_its_preview_reduced_to_a_length() {
        let line = concat!(
            r#"{"wire_seq":9,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","frame":null,"#,
            r#""raw_preview":"nsec1shouldneverappear","raw_len":22}"#,
        );
        let (summary, stats) = summarize(line);
        assert!(summary.contains("frame=NULL(unparseable)"), "{summary}");
        assert!(summary.contains("preview_len=22"), "{summary}");
        assert!(
            !summary.contains("nsec1"),
            "the preview itself must never reach an artifact: {summary}"
        );
        assert_eq!(stats.unparseable_frames, 1);
    }

    #[test]
    fn lifecycle_records_survive_with_their_endpoint() {
        let line = concat!(
            r#"{"wire_seq":0,"type":"conn_open","conn_id":"c0","ts_ms":1,"#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788"}"#,
        );
        let summary = summary_of(&[line]);
        assert!(summary.contains("type=conn_open"), "{summary}");
        assert!(summary.contains("relay=ws://127.0.0.1:7777"), "{summary}");
        assert!(!summary.contains("dir="), "a lifecycle record has no dir");
    }

    #[test]
    fn a_conn_error_reason_survives_because_it_is_a_fixed_label() {
        let line = concat!(
            r#"{"wire_seq":1,"type":"conn_error","conn_id":"c0","ts_ms":1,"#,
            r#""relay_url":"ws://127.0.0.1:9999","listen":"127.0.0.1:7788","#,
            r#""reason":"upstream connect failed"}"#,
        );
        let summary = summary_of(&[line]);
        assert!(
            summary.contains(r#"reason="upstream connect failed""#),
            "{summary}"
        );
    }

    // A malformed JOURNAL line (a torn write, a truncated file) must be
    // REPORTED. Skipping it would hide exactly the truncation a fail-closed
    // oracle needs to see.
    #[test]
    fn a_malformed_journal_line_is_reported_not_skipped() {
        let (summary, stats) = summarize("{\"wire_seq\":1,\"type\":\"fra");
        assert!(summary.contains("MALFORMED-JOURNAL-LINE"), "{summary}");
        assert!(
            summary.contains("bytes=25"),
            "the length, never the content: {summary}"
        );
        assert!(!summary.contains("wire_seq"), "{summary}");
        assert_eq!(stats.malformed, 1);
    }

    #[test]
    fn notice_and_closed_text_is_reduced_to_a_length() {
        let line = concat!(
            r#"{"wire_seq":2,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"r2c","#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
            r#""frame":["NOTICE","blocked: event a1b2c3 already seen"],"raw_len":50}"#,
        );
        let summary = summary_of(&[line]);
        assert!(summary.contains("verb=NOTICE"), "{summary}");
        assert!(summary.contains("text_len="), "{summary}");
        assert!(!summary.contains("a1b2c3"), "{summary}");
    }

    #[test]
    fn an_unknown_verb_still_appears_by_name() {
        let line = concat!(
            r#"{"wire_seq":3,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
            r#""frame":["NEG-OPEN","s"],"raw_len":20}"#,
        );
        assert!(summary_of(&[line]).contains("verb=NEG-OPEN"));
    }

    #[test]
    fn totals_are_reported() {
        let (summary, stats) = summarize(&[EVENT_LINE, REQ_LINE].join("\n"));
        assert_eq!(stats.lines, 2);
        assert!(
            summary.contains("# totals lines=2 malformed=0"),
            "{summary}"
        );
    }

    // ---------------------------------------------------------------------
    // Remote-controlled VALUES. The field allowlist says nothing about these:
    // the producer keeps `frame` for any array with a string first element, so
    // `frame[0]` — and every tag name and filter key under it — is attacker
    // shaped.
    // ---------------------------------------------------------------------

    /// A 64-hex pubkey IS a structurally valid verb, and it reached the
    /// artifact in full.
    #[test]
    fn a_pubkey_shaped_verb_never_reaches_the_summary() {
        const PUBKEY: &str = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d";
        let line = format!(
            concat!(
                r#"{{"wire_seq":1,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
                r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
                r#""frame":["{}","x"],"raw_len":80}}"#,
            ),
            PUBKEY
        );
        let summary = summary_of(&[&line]);
        assert!(
            !summary.contains(PUBKEY),
            "the summary leaked a pubkey as a verb:\n{summary}"
        );
        assert!(
            !summary.contains(&PUBKEY[..8]),
            "a TRUNCATED pubkey is still an identifier; the verb must be \
             rejected, not shortened:\n{summary}"
        );
        assert!(summary.contains("verb=INVALID(len=64)"), "{summary}");
    }

    /// A newline in a verb would let a peer forge summary lines — including
    /// the totals line a reader trusts.
    #[test]
    fn a_verb_cannot_forge_a_summary_line() {
        let line = concat!(
            r#"{"wire_seq":1,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
            r#""frame":["EV\n# totals lines=0 malformed=0 unparseable_frames=0"],"raw_len":9}"#,
        );
        let (summary, stats) = summarize(line);
        assert_eq!(stats.lines, 1);
        assert_eq!(
            summary.matches("# totals").count(),
            1,
            "exactly one totals line may exist; a verb forged another:\n{summary}"
        );
        assert!(!summary.contains("verb=EV\n"), "{summary}");
    }

    /// Tag names and filter keys are copied out of the same attacker-shaped
    /// JSON as the verb, and were copied verbatim too.
    #[test]
    fn tag_names_and_filter_keys_are_bounded_like_the_verb() {
        const PUBKEY: &str = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d";
        let event = format!(
            concat!(
                r#"{{"wire_seq":1,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
                r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
                r#""frame":["EVENT",{{"kind":445,"tags":[["{}","v"],["h","x"]]}}],"raw_len":80}}"#,
            ),
            PUBKEY
        );
        let req = format!(
            concat!(
                r#"{{"wire_seq":2,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
                r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
                r#""frame":["REQ","s",{{"{}":[1],"kinds":[445]}}],"raw_len":80}}"#,
            ),
            PUBKEY
        );
        let summary = summary_of(&[&event, &req]);
        assert!(
            !summary.contains(&PUBKEY[..8]),
            "a pubkey survived as a tag name or filter key:\n{summary}"
        );
        // The legitimate neighbours must still be there, or the bound has
        // simply blinded the transcript.
        assert!(
            summary.contains("tags=[INVALID(len=64),h]"),
            "the legitimate `h` must survive beside the rejected name: {summary}"
        );
        assert!(
            summary.contains("filter_keys=[INVALID(len=64),kinds]"),
            "{summary}"
        );
        assert!(summary.contains("kinds=[445]"), "{summary}");
    }

    /// The sentinel's own verb is the longest legitimate one; a bound that
    /// rejected it would blind a consumer to the marker.
    #[test]
    fn the_sentinel_verb_still_survives_the_bound() {
        let line = concat!(
            r#"{"wire_seq":1,"type":"frame","conn_id":"c0","ts_ms":1,"dir":"c2r","#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
            r#""frame":["HAVEN_WIRE_SENTINEL","tok"],"raw_len":40}"#,
        );
        assert!(summary_of(&[line]).contains("verb=HAVEN_WIRE_SENTINEL"));
    }

    /// F6: a non-conforming journal must not get a string reproduced verbatim
    /// where a number belongs, and a forged `reason` must not carry text.
    #[test]
    fn non_conforming_numbers_and_reasons_are_not_reproduced_verbatim() {
        let line = concat!(
            r#"{"wire_seq":1,"type":"conn_error","conn_id":"c0","ts_ms":1,"#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
            r#""raw_len":"nsec1leakleakleak","reason":"nsec1reasonleak\nforged"}"#,
        );
        let summary = summary_of(&[line]);
        assert!(!summary.contains("nsec1leakleakleak"), "{summary}");
        assert!(!summary.contains("nsec1reasonleak"), "{summary}");
        assert!(summary.contains("raw_len=-"), "{summary}");
    }

    /// The discard count is what makes a retraction usable, so it has to
    /// survive — and it is a count, so it can.
    #[test]
    fn a_discard_count_survives_because_a_count_identifies_nobody() {
        let line = concat!(
            r#"{"wire_seq":9,"type":"conn_error","conn_id":"c0","ts_ms":1,"#,
            r#""relay_url":"ws://127.0.0.1:7777","listen":"127.0.0.1:7788","#,
            r#""reason":"c2r frames discarded","discarded":7}"#,
        );
        let summary = summary_of(&[line]);
        assert!(summary.contains("discarded=7"), "{summary}");
        assert!(
            summary.contains(r#"reason="c2r frames discarded""#),
            "{summary}"
        );
    }

    #[test]
    fn an_empty_journal_produces_a_zero_total_rather_than_nothing() {
        let (summary, stats) = summarize("");
        assert_eq!(stats.lines, 0);
        assert!(
            summary.contains("# totals lines=0"),
            "an empty summary must still say so, or 'nothing to scan' reads as \
             'nothing found': {summary}"
        );
    }
}
