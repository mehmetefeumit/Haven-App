//! A route that answers as a relay serving some kinds' reads only to a client
//! that has authenticated (NIP-42).
//!
//! That is strfry's `relay.auth.restrictedReadKinds`, whose default
//! `"4, 1059"` is what `relay.damus.io` runs. The upstream relay is not
//! gated: the proxy plays the gate in front of it, frame for frame as
//! haven-core's `RecordingFront::start_gating` does (strfry
//! `RelayIngester.cpp`, `ReadRestrictor.h`). To a client that has not
//! authenticated:
//!
//! * a `REQ` whose every filter names only restricted kinds is refused,
//! * a `COUNT` with any filter naming a restricted kind is refused,
//! * a `NEG-OPEN` whose filter names only restricted kinds is refused,
//!
//! each with an `AUTH` challenge and then `CLOSED` (`NEG-ERR` for the
//! `NEG-OPEN`), and never reaches the relay; an event of a restricted kind the
//! relay sends for any other subscription is withheld. Every `EVENT` a client
//! publishes is handed on, so writes still get `OK true` — which is exactly
//! what makes a relay like this a trap for an inbox read that never
//! authenticates: it takes the gift wrap and never serves it back.
//!
//! A client that answers the challenge ([`answer_auth`]) is checked as strfry
//! `RelayIngester.cpp` `handleAuth` checks it: a kind-22242 event, valid id
//! and signature, carrying the challenge its connection was sent and a
//! `relay` tag naming this route. The relay tag is matched by scheme and port
//! only: an emulator dials the route through its host alias (`10.0.2.2`),
//! never the loopback address the proxy listens on. It is answered `OK true`
//! and never handed on; from then on its connection's reads are handed on,
//! and of the restricted kinds it is served only the events naming its key in
//! a `p` tag or signed by it (strfry's `shouldSendToSubscriber`). Any other
//! answer is `OK false`, as is a second answer on a connection already
//! authenticated.

use std::collections::BTreeSet;

use nostr_relay_builder::prelude::{Event, JsonUtil as _, Kind};
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

    /// strfry's `shouldSendToSubscriber`: no event of a restricted kind
    /// reaches a client that has not authenticated, and one that has, as the
    /// hex key `reader`, is sent only those naming it in a `p` tag or signed
    /// by it.
    #[must_use]
    pub fn withholds(&self, text: &str, reader: Option<&str>) -> bool {
        let Ok(frame) = serde_json::from_str::<Value>(text) else {
            return false;
        };
        let Some(event) = frame.get(2) else {
            return false;
        };
        let restricted = frame.get(0).and_then(Value::as_str) == Some("EVENT")
            && event
                .get("kind")
                .and_then(Value::as_u64)
                .is_some_and(|kind| self.kinds.contains(&kind));
        restricted
            && !reader.is_some_and(|reader| {
                event.get("pubkey").and_then(Value::as_str) == Some(reader)
                    || event
                        .get("tags")
                        .and_then(Value::as_array)
                        .is_some_and(|tags| {
                            tags.iter().any(|tag| {
                                tag.get(0).and_then(Value::as_str) == Some("p")
                                    && tag.get(1).and_then(Value::as_str) == Some(reader)
                            })
                        })
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

/// What a gated route answers a client's `["AUTH", <event>]` frame.
///
/// The connection was sent `challenge`, the route listens on `listen_port`,
/// and the connection has authenticated as `authed` (hex) if at all. The
/// answer is the `OK` frame, and the key that has now authenticated, if this
/// answer did. `None` for every other frame.
#[must_use]
pub fn answer_auth(
    text: &str,
    challenge: &str,
    listen_port: u16,
    authed: Option<&str>,
) -> Option<(String, Option<String>)> {
    let frame: Value = serde_json::from_str(text).ok()?;
    if frame.get(0).and_then(Value::as_str) != Some("AUTH") {
        return None;
    }
    let Some(event) = frame
        .get(1)
        .and_then(|event| Event::from_json(event.to_string()).ok())
    else {
        return Some((r#"["NOTICE","invalid: AUTH"]"#.to_owned(), None));
    };
    let tag = |name: &str| {
        event.tags.iter().find_map(|tag| match tag.as_slice() {
            [tag_name, value] if tag_name == name => Some(value.clone()),
            _ => None,
        })
    };
    let answers = event.kind == Kind::Authentication
        && event.verify().is_ok()
        && tag("challenge").as_deref() == Some(challenge)
        && tag("relay").is_some_and(|relay| names_route(&relay, listen_port));
    let (status, reason, now) = if authed.is_some() {
        (false, "error: already authenticated", None)
    } else if answers {
        (true, "", Some(event.pubkey.to_hex()))
    } else {
        (
            false,
            "restricted: the answer does not answer this connection's challenge",
            None,
        )
    };
    let ok = serde_json::json!(["OK", event.id.to_hex(), status, reason]).to_string();
    Some((ok, now))
}

/// `relay` is a `ws`/`wss` URL whose port is `listen_port`.
fn names_route(relay: &str, listen_port: u16) -> bool {
    let Some(rest) = relay
        .strip_prefix("ws://")
        .or_else(|| relay.strip_prefix("wss://"))
    else {
        return false;
    };
    let authority = rest.split('/').next().unwrap_or_default();
    authority
        .rsplit_once(':')
        .and_then(|(_, port)| port.parse::<u16>().ok())
        == Some(listen_port)
}

#[cfg(test)]
mod tests {
    use nostr_relay_builder::prelude::{EventBuilder, Keys, Tag};

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
        assert!(gate.withholds(r#"["EVENT","s",{"kind":1059,"id":"ab"}]"#, None));
        assert!(!gate.withholds(r#"["EVENT","s",{"kind":445,"id":"ab"}]"#, None));
        assert!(!gate.withholds(r#"["EOSE","s"]"#, None));
        assert!(!gate.withholds(r#"["OK","ab",true,""]"#, None));
    }

    // strfry serves an authenticated reader the restricted events that name
    // it, and still withholds everyone else's.
    #[test]
    fn an_authenticated_reader_is_served_only_what_names_or_is_signed_by_it() {
        let gate = gate();
        let to_me = r#"["EVENT","s",{"kind":1059,"pubkey":"ee","tags":[["p","me"]]}]"#;
        let by_me = r#"["EVENT","s",{"kind":1059,"pubkey":"me","tags":[["p","you"]]}]"#;
        let theirs = r#"["EVENT","s",{"kind":1059,"pubkey":"ee","tags":[["p","you"]]}]"#;
        assert!(!gate.withholds(to_me, Some("me")));
        assert!(!gate.withholds(by_me, Some("me")));
        assert!(gate.withholds(theirs, Some("me")));
        assert!(gate.withholds(to_me, None));
    }

    fn auth_frame(keys: &Keys, kind: u16, challenge: &str, relay: &str) -> String {
        let event = EventBuilder::new(Kind::Custom(kind), "")
            .tags([
                Tag::parse(["challenge", challenge]).expect("challenge tag"),
                Tag::parse(["relay", relay]).expect("relay tag"),
            ])
            .sign_with_keys(keys)
            .expect("signed");
        format!(r#"["AUTH",{}]"#, event.as_json())
    }

    fn ok_status(ok: &str) -> bool {
        let ok = json(ok);
        assert_eq!(ok[0], "OK");
        ok[2].as_bool().expect("an OK carries a status")
    }

    #[test]
    fn the_answer_to_this_connections_challenge_naming_this_route_authenticates() {
        let keys = Keys::generate();
        for relay in ["ws://10.0.2.2:7790", "ws://127.0.0.1:7790/", "wss://h:7790"] {
            let text = auth_frame(&keys, 22242, "challenge-c4", relay);
            let (ok, now) = answer_auth(&text, "challenge-c4", 7790, None).expect("answered");
            assert!(ok_status(&ok), "{relay}");
            assert_eq!(now, Some(keys.public_key().to_hex()), "{relay}");
        }
    }

    #[test]
    fn any_other_answer_is_ok_false_and_authenticates_nobody() {
        let keys = Keys::generate();
        let good = auth_frame(&keys, 22242, "challenge-c4", "ws://127.0.0.1:7790");
        let refused = [
            (
                "another connection's challenge",
                auth_frame(&keys, 22242, "challenge-c5", "ws://127.0.0.1:7790"),
            ),
            (
                "another route",
                auth_frame(&keys, 22242, "challenge-c4", "ws://127.0.0.1:7791"),
            ),
            (
                "not a websocket",
                auth_frame(&keys, 22242, "challenge-c4", "http://127.0.0.1:7790"),
            ),
            (
                "no port",
                auth_frame(&keys, 22242, "challenge-c4", "ws://127.0.0.1"),
            ),
            (
                "another kind",
                auth_frame(&keys, 1, "challenge-c4", "ws://127.0.0.1:7790"),
            ),
            // A valid answer whose signature no longer covers its content.
            (
                "a broken signature",
                good.replacen(r#""content":""#, r#""content":"x"#, 1),
            ),
        ];
        for (why, text) in &refused {
            let (ok, now) = answer_auth(text, "challenge-c4", 7790, None).expect("answered");
            assert!(!ok_status(&ok), "{why}");
            assert_eq!(now, None, "{why}");
        }
        let (ok, now) = answer_auth(&good, "challenge-c4", 7790, Some("ab")).expect("answered");
        assert!(!ok_status(&ok), "a second answer");
        assert_eq!(now, None);
        let (notice, now) =
            answer_auth(r#"["AUTH","x"]"#, "challenge-c4", 7790, None).expect("answered");
        assert_eq!(json(&notice)[0], "NOTICE");
        assert_eq!(now, None);
        assert!(answer_auth(r#"["REQ","s",{}]"#, "challenge-c4", 7790, None).is_none());
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
