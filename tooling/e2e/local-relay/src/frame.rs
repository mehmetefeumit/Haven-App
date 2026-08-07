//! Classification of a single WebSocket message into a journal observation.
//!
//! # Structural recognition, not a verb allowlist
//!
//! A message is recorded with its `frame` intact whenever it is a JSON ARRAY
//! whose first element is a STRING. That is deliberately weaker than "is a
//! recognised Nostr frame", and the weakness is the point: this whole
//! workstream exists because the previous oracle was a forbid-list that a new
//! kind or a new verb passed through silently. If the producer nulled out
//! unknown verbs, an oracle asserting `observed ⊆ allowed` over `frame[0]`
//! would lose the exact signal it is checking for — a novel verb would arrive
//! as `frame: null`, indistinguishable from line noise.
//!
//! So the split of responsibility is: the PRODUCER records faithfully and the
//! ORACLE decides what is allowed. `frame: null` therefore means something
//! stronger and rarer — the message was not even structurally a Nostr frame.
//!
//! # Never drop a line
//!
//! Anything that fails that structural test is still recorded, with
//! `frame: null` and a bounded `raw_preview`. Silence about a malformed frame
//! is the failure mode this instrument exists to remove.

use serde_json::Value;

/// Maximum number of CHARACTERS retained in `raw_preview`.
///
/// Characters, not bytes, so a multi-byte payload cannot be truncated
/// mid-codepoint into invalid UTF-8 in the journal.
pub const RAW_PREVIEW_CHARS: usize = 200;

/// The verb a client sends to place a snapshot marker in the journal.
///
/// # Shape (contract)
///
/// A TEXT WebSocket message on any connection to the proxy:
///
/// ```text
/// ["HAVEN_WIRE_SENTINEL","<opaque token>"]
/// ```
///
/// The proxy INTERCEPTS it: the message is recorded as an ordinary
/// `type:"frame"`, `dir:"c2r"` line and is **never forwarded upstream**. No
/// relay ever sees a sentinel, so the marker cannot perturb the scenario and
/// no relay's unknown-command handling (a `NOTICE`, or a connection close) is
/// involved. The only party that observes it is the recorder itself.
///
/// The token is opaque and caller-chosen. It is written verbatim into the
/// journal and echoed in the ack, so it must be a random nonce and must never
/// carry anything sensitive.
pub const SENTINEL_VERB: &str = "HAVEN_WIRE_SENTINEL";

/// The verb the proxy answers a sentinel with.
///
/// ```text
/// ["HAVEN_WIRE_SENTINEL_ACK","<token>",<wire_seq>,"<conn_id>"]
/// ```
///
/// The ack is synthesized by the proxy, so it is deliberately NOT journalled:
/// recording it as `dir:"r2c"` would claim the relay sent it. `wire_seq` is
/// the sequence number assigned to the sentinel line, which is the snapshot
/// boundary; `conn_id` lets the emitting harness identify — and therefore
/// EXCLUDE — its own connection when attributing traffic.
pub const SENTINEL_ACK_VERB: &str = "HAVEN_WIRE_SENTINEL_ACK";

/// Longest sentinel token echoed back in an ack. Tokens are opaque and
/// caller-chosen; the cap stops a client from using the ack as an
/// amplification channel.
pub const SENTINEL_TOKEN_MAX: usize = 128;

/// One classified WebSocket message, ready to be journalled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Observation {
    /// The parsed frame, verbatim, or `None` when the message was not
    /// structurally a Nostr frame.
    pub frame: Option<Value>,
    /// Bounded preview, present exactly when `frame` is `None`.
    pub raw_preview: Option<String>,
    /// Byte length of the original message, before parsing.
    pub raw_len: usize,
    /// `Some(token)` when this message is a sentinel marker.
    pub sentinel: Option<String>,
}

impl Observation {
    /// `true` when the message could not be parsed as a Nostr frame — i.e.
    /// this line is a finding, not routine traffic.
    #[must_use]
    pub const fn is_unparseable(&self) -> bool {
        self.frame.is_none()
    }
}

/// Classifies a TEXT message.
#[must_use]
pub fn classify_text(text: &str) -> Observation {
    let raw_len = text.len();
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return unparseable(text, raw_len);
    };
    let Some(array) = value.as_array() else {
        return unparseable(text, raw_len);
    };
    let Some(Value::String(verb)) = array.first() else {
        return unparseable(text, raw_len);
    };

    let sentinel = (verb == SENTINEL_VERB).then(|| sentinel_token(array));

    Observation {
        frame: Some(value),
        raw_preview: None,
        raw_len,
        sentinel,
    }
}

/// Classifies a BINARY message.
///
/// Nostr is a text protocol, so a binary message is always a finding. The
/// preview is a lossy UTF-8 rendering of the bytes: a binary payload is
/// exactly the case where a faithful preview matters most, and a silent drop
/// is what this instrument refuses to do.
#[must_use]
pub fn classify_binary(bytes: &[u8]) -> Observation {
    let rendered = String::from_utf8_lossy(bytes);
    Observation {
        frame: None,
        raw_preview: Some(preview(&rendered)),
        raw_len: bytes.len(),
        sentinel: None,
    }
}

/// Builds the ack a sentinel is answered with.
#[must_use]
pub fn sentinel_ack(token: &str, wire_seq: u64, conn_id: &str) -> String {
    let capped: String = token.chars().take(SENTINEL_TOKEN_MAX).collect();
    Value::Array(vec![
        Value::String(SENTINEL_ACK_VERB.to_owned()),
        Value::String(capped),
        Value::from(wire_seq),
        Value::String(conn_id.to_owned()),
    ])
    .to_string()
}

/// Extracts the token from a sentinel frame, or the empty string when the
/// frame carries no string token. A malformed sentinel is still intercepted
/// and still recorded verbatim — forwarding it upstream would put an unknown
/// verb in front of a relay for no benefit.
fn sentinel_token(array: &[Value]) -> String {
    array
        .get(1)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn unparseable(text: &str, raw_len: usize) -> Observation {
    Observation {
        frame: None,
        raw_preview: Some(preview(text)),
        raw_len,
        sentinel: None,
    }
}

fn preview(text: &str) -> String {
    text.chars().take(RAW_PREVIEW_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_an_event_frame_verbatim() {
        let raw = r#"["EVENT",{"id":"aa","kind":445,"tags":[["h","bb"]]}]"#;
        let obs = classify_text(raw);
        let frame = obs.frame.expect("EVENT must parse");
        assert_eq!(frame[0], "EVENT");
        assert_eq!(frame[1]["kind"], 445);
        assert_eq!(frame[1]["tags"][0][0], "h");
        assert!(obs.raw_preview.is_none());
        assert_eq!(obs.raw_len, raw.len());
        assert!(obs.sentinel.is_none());
    }

    #[test]
    fn parses_a_req_frame_with_its_filter() {
        let raw = r##"["REQ","sub1",{"kinds":[445],"#h":["deadbeef"],"limit":200}]"##;
        let frame = classify_text(raw).frame.expect("REQ must parse");
        assert_eq!(frame[0], "REQ");
        assert_eq!(frame[1], "sub1");
        assert_eq!(frame[2]["kinds"][0], 445);
    }

    #[test]
    fn parses_every_frame_verb_the_app_exchanges() {
        for raw in [
            r#"["EVENT",{"kind":445}]"#,
            r#"["REQ","s",{"kinds":[1059]}]"#,
            r#"["CLOSE","s"]"#,
            r#"["OK","abc",true,""]"#,
            r#"["EOSE","s"]"#,
            r#"["NOTICE","hello"]"#,
            r#"["AUTH","challenge"]"#,
            r#"["CLOSED","s","error: x"]"#,
        ] {
            let obs = classify_text(raw);
            assert!(obs.frame.is_some(), "{raw} must record a frame");
            assert!(!obs.is_unparseable(), "{raw} must not read as a finding");
        }
    }

    // An UNKNOWN verb must survive into the journal with its verb intact.
    // Nulling it would make an oracle's `observed ⊆ allowed` blind to exactly
    // the novelty it exists to catch — the forbid-list failure, relocated.
    #[test]
    fn an_unknown_verb_keeps_its_frame_so_an_allowlist_oracle_can_see_it() {
        let obs = classify_text(r#"["NEG-OPEN","sub",{"kinds":[445]}]"#);
        assert!(!obs.is_unparseable());
        let frame = obs.frame.expect("an unknown verb is still a frame");
        assert_eq!(frame[0], "NEG-OPEN");
    }

    #[test]
    fn invalid_json_records_as_a_finding_with_a_preview() {
        let obs = classify_text("{not json at all");
        assert!(obs.is_unparseable());
        assert_eq!(obs.raw_preview.as_deref(), Some("{not json at all"));
        assert_eq!(obs.raw_len, "{not json at all".len());
    }

    #[test]
    fn valid_json_that_is_not_an_array_records_as_a_finding() {
        let obs = classify_text(r#"{"kind":445}"#);
        assert!(obs.is_unparseable());
        assert_eq!(obs.raw_preview.as_deref(), Some(r#"{"kind":445}"#));
    }

    #[test]
    fn an_empty_array_records_as_a_finding() {
        assert!(classify_text("[]").is_unparseable());
    }

    #[test]
    fn an_array_with_a_non_string_verb_records_as_a_finding() {
        assert!(classify_text("[445,{}]").is_unparseable());
    }

    #[test]
    fn preview_is_capped_at_200_characters() {
        let long = "x".repeat(5000);
        let obs = classify_text(&long);
        let preview = obs.raw_preview.expect("finding must carry a preview");
        assert_eq!(preview.chars().count(), RAW_PREVIEW_CHARS);
        // raw_len still reports the FULL size — the preview is bounded, the
        // measurement is not.
        assert_eq!(obs.raw_len, 5000);
    }

    // Truncating on bytes would slice a multi-byte codepoint in half and put
    // invalid UTF-8 into an NDJSON file every consumer parses as text.
    #[test]
    fn preview_truncates_on_characters_not_bytes() {
        let long = "é".repeat(500);
        let obs = classify_text(&long);
        let preview = obs.raw_preview.expect("finding must carry a preview");
        assert_eq!(preview.chars().count(), RAW_PREVIEW_CHARS);
        assert_eq!(obs.raw_len, 1000, "raw_len counts bytes");
    }

    #[test]
    fn binary_messages_are_findings_with_a_lossy_preview() {
        let obs = classify_binary(&[0xff, 0xfe, b'h', b'i']);
        assert!(obs.is_unparseable());
        assert_eq!(obs.raw_len, 4);
        assert!(obs.raw_preview.is_some_and(|p| p.ends_with("hi")));
    }

    #[test]
    fn a_sentinel_is_detected_and_its_token_extracted() {
        let obs = classify_text(r#"["HAVEN_WIRE_SENTINEL","tok-42"]"#);
        assert_eq!(obs.sentinel.as_deref(), Some("tok-42"));
        // It is ALSO a normal frame line — the marker is visible in the
        // journal, not hidden behind the interception.
        assert!(obs.frame.is_some());
    }

    #[test]
    fn a_sentinel_without_a_token_is_still_intercepted() {
        let obs = classify_text(r#"["HAVEN_WIRE_SENTINEL"]"#);
        assert_eq!(obs.sentinel.as_deref(), Some(""));
    }

    #[test]
    fn a_non_sentinel_frame_never_reports_a_token() {
        assert!(classify_text(r#"["REQ","s",{}]"#).sentinel.is_none());
    }

    #[test]
    fn ack_carries_the_token_the_assigned_seq_and_the_conn_id() {
        let ack = sentinel_ack("tok-42", 17, "c3");
        assert_eq!(ack, r#"["HAVEN_WIRE_SENTINEL_ACK","tok-42",17,"c3"]"#);
    }

    #[test]
    fn ack_caps_an_oversized_token() {
        let ack = sentinel_ack(&"z".repeat(10_000), 1, "c0");
        let parsed: Value = serde_json::from_str(&ack).expect("ack is JSON");
        assert_eq!(
            parsed[1].as_str().map(str::len),
            Some(SENTINEL_TOKEN_MAX),
            "an oversized token must not be echoed back in full"
        );
    }
}
