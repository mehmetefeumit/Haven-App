//! A route that answers as a relay serving some kinds' reads only to a client
//! that has authenticated (NIP-42).
//!
//! That is strfry's `relay.auth.restrictedReadKinds`, whose default
//! `"4, 1059"` is what `relay.damus.io` runs, seen by a client that never
//! authenticates, as Haven never does (Security Rule 16). The upstream relay is not gated: the proxy plays the gate in front of it,
//! frame for frame as haven-core's `RecordingFront::start_gating` does (strfry
//! `RelayIngester.cpp`, `ReadRestrictor.h`):
//!
//! * a `REQ` whose every filter names only restricted kinds is refused,
//! * a `COUNT` with any filter naming a restricted kind is refused,
//! * a `NEG-OPEN` whose filter names only restricted kinds is refused,
//!
//! each with an `AUTH` challenge and then `CLOSED` (`NEG-ERR` for the
//! `NEG-OPEN`), and never reaches the relay; an event of a restricted kind the
//! relay sends for any other subscription is withheld. Every `EVENT` a client
//! publishes is handed on, so writes still get `OK true` — which is exactly
//! what makes a relay like this a trap for an inbox: it takes the gift wrap and
//! never serves it back.

use std::collections::BTreeSet;

use serde_json::Value;

/// strfry's refusal of a read only an authenticated client may make.
pub const AUTH_REQUIRED: &str = "auth-required: requested filter requires authentication";

/// The route option naming the restricted kinds: `gate-read=<kind>[+<kind>…]`.
pub const OPTION: &str = "gate-read";

/// The kinds a gated route restricts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadGate {
    kinds: BTreeSet<u64>,
}

impl ReadGate {
    /// Parses the value of a `gate-read=` route option: one kind or several
    /// joined by `+` (`,` already separates routes).
    ///
    /// # Errors
    ///
    /// A message naming the value when it is empty or a part is not a kind.
    pub fn parse(value: &str) -> Result<Self, String> {
        let kinds = value
            .split('+')
            .map(|part| part.trim().parse::<u64>())
            .collect::<Result<BTreeSet<_>, _>>()
            .map_err(|_| format!("{OPTION}='{value}' is not a '+'-joined list of event kinds"))?;
        if kinds.is_empty() {
            return Err(format!("{OPTION} names no kind"));
        }
        Ok(Self { kinds })
    }

    /// The restricted kinds, ascending.
    pub fn kinds(&self) -> impl Iterator<Item = u64> + '_ {
        self.kinds.iter().copied()
    }

    /// What the gate answers a client frame a gated relay refuses a client
    /// that has not authenticated: an `AUTH` challenge, then the refusal.
    /// `None` for every frame it hands on.
    #[must_use]
    pub fn refusal(&self, text: &str, challenge: &str) -> Option<[String; 2]> {
        let frame: Value = serde_json::from_str(text).ok()?;
        let frame = frame.as_array()?;
        let verb = frame.first()?.as_str()?;
        let id = frame.get(1)?.as_str()?;
        let filters = frame.get(2..)?;
        let refused = match verb {
            "REQ" => !filters.is_empty() && filters.iter().all(|f| self.only_restricted(f)),
            "COUNT" => filters.iter().any(|f| self.names_restricted(f)),
            "NEG-OPEN" => filters.first().is_some_and(|f| self.only_restricted(f)),
            _ => false,
        };
        if !refused {
            return None;
        }
        let refusal = if verb == "NEG-OPEN" {
            serde_json::json!(["NEG-ERR", id, AUTH_REQUIRED])
        } else {
            // strfry's `sendClosedError` puts `ERROR: ` before every `CLOSED`
            // reason it sends.
            serde_json::json!(["CLOSED", id, format!("ERROR: {AUTH_REQUIRED}")])
        };
        Some([
            serde_json::json!(["AUTH", challenge]).to_string(),
            refusal.to_string(),
        ])
    }

    /// strfry's `shouldSendToSubscriber` for a client that has not
    /// authenticated: no event of a restricted kind reaches it.
    #[must_use]
    pub fn withholds(&self, text: &str) -> bool {
        serde_json::from_str::<Value>(text).is_ok_and(|frame| {
            frame.get(0).and_then(Value::as_str) == Some("EVENT")
                && frame
                    .get(2)
                    .and_then(|event| event.get("kind"))
                    .and_then(Value::as_u64)
                    .is_some_and(|kind| self.kinds.contains(&kind))
        })
    }

    fn filter_kinds(filter: &Value) -> Option<impl Iterator<Item = Option<u64>> + '_> {
        Some(filter.get("kinds")?.as_array()?.iter().map(Value::as_u64))
    }

    /// strfry's `isFilterFullyRestricted`: the filter names kinds, every one
    /// of them restricted.
    fn only_restricted(&self, filter: &Value) -> bool {
        Self::filter_kinds(filter).is_some_and(|mut kinds| {
            kinds.all(|kind| kind.is_some_and(|kind| self.kinds.contains(&kind)))
        })
    }

    /// strfry's test in `isFilterAllowedToCount`: the filter names a
    /// restricted kind.
    fn names_restricted(&self, filter: &Value) -> bool {
        Self::filter_kinds(filter).is_some_and(|mut kinds| {
            kinds.any(|kind| kind.is_some_and(|kind| self.kinds.contains(&kind)))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate() -> ReadGate {
        ReadGate::parse("1059").expect("one kind parses")
    }

    fn json(text: &str) -> Value {
        serde_json::from_str(text).expect("the gate answers JSON")
    }

    #[test]
    fn a_req_naming_only_restricted_kinds_is_answered_with_auth_then_strfrys_closed() {
        let [auth, closed] = gate()
            .refusal(
                r##"["REQ","s",{"kinds":[1059],"#p":["ab"]}]"##,
                "challenge-c3",
            )
            .expect("refused");
        assert_eq!(json(&auth), serde_json::json!(["AUTH", "challenge-c3"]));
        assert_eq!(
            json(&closed),
            serde_json::json!([
                "CLOSED",
                "s",
                "ERROR: auth-required: requested filter requires authentication"
            ])
        );
    }

    // strfry refuses a REQ only when EVERY filter is fully restricted; a REQ
    // with one open filter beside a gated one is served (and the gated kinds
    // in its answer are withheld instead).
    #[test]
    fn a_req_is_refused_only_when_every_filter_names_only_restricted_kinds() {
        let gate = gate();
        for handed_on in [
            r#"["REQ","s",{"kinds":[1059,445]}]"#,
            r#"["REQ","s",{"kinds":[1059]},{"kinds":[445]}]"#,
            r##"["REQ","s",{"#p":["ab"]}]"##,
            r#"["REQ","s"]"#,
            r#"["REQ","s",{"kinds":[30443],"authors":["ab"]}]"#,
        ] {
            assert!(gate.refusal(handed_on, "x").is_none(), "{handed_on}");
        }
        assert!(gate
            .refusal(
                r#"["REQ","s",{"kinds":[1059]},{"kinds":[1059],"since":1}]"#,
                "x"
            )
            .is_some());
    }

    #[test]
    fn a_count_is_refused_when_any_filter_names_a_restricted_kind() {
        let gate = gate();
        let [_, closed] = gate
            .refusal(r#"["COUNT","c",{"kinds":[445]},{"kinds":[1059,1]}]"#, "x")
            .expect("refused");
        assert_eq!(json(&closed)[0], "CLOSED");
        assert!(gate
            .refusal(r#"["COUNT","c",{"kinds":[445]}]"#, "x")
            .is_none());
    }

    #[test]
    fn a_neg_open_is_refused_with_neg_err_and_no_error_prefix() {
        let [auth, err] = gate()
            .refusal(
                r#"["NEG-OPEN","n",{"kinds":[1059]},"6100000200"]"#,
                "challenge-c0",
            )
            .expect("refused");
        assert_eq!(json(&auth)[0], "AUTH");
        assert_eq!(
            json(&err),
            serde_json::json!(["NEG-ERR", "n", AUTH_REQUIRED])
        );
        assert!(gate()
            .refusal(
                r##"["NEG-OPEN","n",{"kinds":[445],"#h":["ab"]},"6100000200"]"##,
                "x"
            )
            .is_none());
    }

    #[test]
    fn writes_and_every_other_verb_are_handed_on() {
        let gate = gate();
        for text in [
            r#"["EVENT",{"kind":1059,"id":"ab","tags":[]}]"#,
            r#"["CLOSE","s"]"#,
            r#"["NEG-CLOSE","n"]"#,
            "not json",
            r#"{"kinds":[1059]}"#,
        ] {
            assert!(gate.refusal(text, "x").is_none(), "{text}");
        }
    }

    #[test]
    fn only_restricted_events_in_relay_answers_are_withheld() {
        let gate = gate();
        assert!(gate.withholds(r#"["EVENT","s",{"kind":1059,"id":"ab"}]"#));
        assert!(!gate.withholds(r#"["EVENT","s",{"kind":445,"id":"ab"}]"#));
        assert!(!gate.withholds(r#"["EOSE","s"]"#));
        assert!(!gate.withholds(r#"["OK","ab",true,""]"#));
    }

    #[test]
    fn the_option_takes_one_kind_or_several_joined_by_plus_and_nothing_else() {
        assert_eq!(gate().kinds().collect::<Vec<_>>(), vec![1059]);
        assert_eq!(
            ReadGate::parse("1059+4")
                .expect("two kinds")
                .kinds()
                .collect::<Vec<_>>(),
            vec![4, 1059]
        );
        for bad in ["", "gift", "1059+", "-4"] {
            let err = ReadGate::parse(bad).expect_err("refused");
            assert!(err.contains(OPTION), "{err}");
        }
    }
}
