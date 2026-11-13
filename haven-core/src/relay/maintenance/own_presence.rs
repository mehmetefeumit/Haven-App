//! What each own relay and lookup relay serves of the user's own events.
//!
//! The user's `KeyPackage` and relay lists are asked for with the probes
//! maintenance sends and judged by maintenance's own rules, so the relay
//! settings page can never call a relay healthy that the next tick would heal.

use nostr::{Event, Filter, Kind, PublicKey};

use super::key_package::{
    kp_event_d_tag, kp_event_is_pre_migration, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
    KIND_MARMOT_KEY_PACKAGE,
};
use super::kp_lifetime::TrackedKpLifetime;
use super::relay_list::list_relay_healthy;
use crate::log_alias;
use crate::nostr::mls::TrackedKeyPackage;
use crate::relay::publishers::dedup_key;
use crate::relay::{RelayFetchOutcome, RelayManager};

/// What one relay serves of one of the user's own events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnEventPresence {
    /// The relay is on no list this kind is published to, and was not asked.
    NotExpected,
    /// It serves what maintenance would leave in place.
    Current,
    /// It answered with an event of this account that maintenance would
    /// replace: an older package, another slot's, or a drifted list.
    Outdated,
    /// It answered in full and holds nothing of this account's.
    Missing,
    /// It could not be reached, or did not finish its answer.
    NoAnswer,
}

/// One relay and what it serves of the user's own events.
#[derive(Clone, PartialEq, Eq)]
pub struct OwnRelayPresence {
    /// The list entry, verbatim.
    pub relay_url: String,
    /// On the user's own inbox or `KeyPackage` list.
    pub own: bool,
    /// A lookup (discovery) relay.
    pub lookup: bool,
    /// The handshake succeeded for at least one of its probes.
    pub reachable: bool,
    /// Kind 30443, expected on the `KeyPackage` list.
    pub key_package: OwnEventPresence,
    /// Kind 10002, expected on the `KeyPackage` list and the lookup relays.
    pub relay_list: OwnEventPresence,
    /// Kind 10050, expected on the inbox list and the lookup relays.
    pub inbox_relay_list: OwnEventPresence,
}

/// Redacting `Debug`: the relay is named by a salted handle (Rule 15).
impl std::fmt::Debug for OwnRelayPresence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OwnRelayPresence")
            .field(
                "relay",
                &log_alias::relay(log_alias::RelayUrl(&self.relay_url)),
            )
            .field("own", &self.own)
            .field("lookup", &self.lookup)
            .field("reachable", &self.reachable)
            .field("key_package", &self.key_package)
            .field("relay_list", &self.relay_list)
            .field("inbox_relay_list", &self.inbox_relay_list)
            .finish()
    }
}

/// The relays [`own_presence`] asks: the user's two lists as configured, and
/// the lookup relays.
pub struct OwnRelayLists<'a> {
    /// The inbox (kind 10050) list.
    pub inbox: &'a [String],
    /// The `KeyPackage` (kind 10002) list.
    pub key_package: &'a [String],
    /// The lookup relays.
    pub lookup: &'a [String],
}

/// Asks every relay of `lists` for the user's own events of each kind
/// expected there, and nothing else, and judges each answer.
///
/// One row per relay, deduplicated: the inbox list first, then the
/// `KeyPackage` list, then the lookup relays.
///
/// The probes are maintenance's (30443 `limit` 64, 10002 and 10050 `limit` 4),
/// one kind after another so a relay's handshake is never raced against
/// itself, and only events `own` signed count. A 30443 is current exactly when
/// maintenance would count the relay as serving `tracked`
/// ([`RelayKpSnapshot::serves_current_package`]); a relay list when its newest
/// copy names exactly the configured list ([`list_relay_healthy`]).
pub async fn own_presence<'a>(
    relay: &RelayManager,
    own: &PublicKey,
    lists: &OwnRelayLists<'a>,
    tracked: Option<&TrackedKeyPackage>,
    tracked_lifetime: TrackedKpLifetime,
) -> Vec<OwnRelayPresence> {
    let on = |list: &[String], key: &str| list.iter().any(|url| dedup_key(url) == key);
    let expected = |yes: bool| {
        if yes {
            OwnEventPresence::NoAnswer
        } else {
            OwnEventPresence::NotExpected
        }
    };
    let mut keys: Vec<String> = Vec::new();
    let mut rows: Vec<OwnRelayPresence> = Vec::new();
    for url in lists
        .inbox
        .iter()
        .chain(lists.key_package)
        .chain(lists.lookup)
    {
        let key = dedup_key(url);
        if keys.contains(&key) {
            continue;
        }
        let (inbox, key_package, lookup) = (
            on(lists.inbox, &key),
            on(lists.key_package, &key),
            on(lists.lookup, &key),
        );
        rows.push(OwnRelayPresence {
            relay_url: url.clone(),
            own: inbox || key_package,
            lookup,
            reachable: false,
            key_package: expected(key_package),
            relay_list: expected(key_package || lookup),
            inbox_relay_list: expected(inbox || lookup),
        });
        keys.push(key);
    }

    let kp_current = |mine: &[&Event]| {
        RelayKpSnapshot {
            responders: vec![RelayKpPerRelay {
                relay_url: String::new(),
                canonical: mine.iter().copied().map(kp_entry).collect(),
            }],
        }
        .serves_current_package(tracked, tracked_lifetime)
    };
    let list_current = |tag: &'static str, configured: &'a [String]| {
        move |mine: &[&Event]| {
            mine.first()
                .is_some_and(|newest| list_relay_healthy(&tagged_urls(newest, tag), configured))
        }
    };
    let (key_package_list, inbox_list) = (
        list_current("r", lists.key_package),
        list_current("relay", lists.inbox),
    );
    let probes: [Probe<'_>; 3] = [
        (
            Kind::RelayList,
            4,
            |row| &mut row.relay_list,
            &key_package_list,
        ),
        (
            Kind::InboxRelays,
            4,
            |row| &mut row.inbox_relay_list,
            &inbox_list,
        ),
        (
            Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
            64,
            |row| &mut row.key_package,
            &kp_current,
        ),
    ];
    for (kind, limit, field, current) in probes {
        let asked: Vec<usize> = rows
            .iter_mut()
            .enumerate()
            .filter_map(|(i, row)| (*field(row) != OwnEventPresence::NotExpected).then_some(i))
            .collect();
        if asked.is_empty() {
            continue;
        }
        let urls: Vec<String> = asked.iter().map(|&i| rows[i].relay_url.clone()).collect();
        let filter = Filter::new().kind(kind).author(*own).limit(limit);
        // Boxed: every relay's answer is in flight at once, and each caller's
        // own future would otherwise carry them.
        let answers = Box::pin(relay.fetch_events_per_relay(filter, &urls))
            .await
            .unwrap_or_default();
        for (&i, answer) in asked.iter().zip(&answers) {
            rows[i].reachable |= answer.responded;
            *field(&mut rows[i]) = judge(answer, own, kind, current);
        }
    }
    rows
}

/// One probe: the kind, its `limit`, the field it is judged into, and what
/// makes the user's own events of it current.
type Probe<'p> = (
    Kind,
    usize,
    fn(&mut OwnRelayPresence) -> &mut OwnEventPresence,
    &'p (dyn Fn(&[&Event]) -> bool + Sync),
);

/// One relay's answer for `kind`. A relay answers a REQ with whatever it
/// likes, so another author's event never counts; the page is newest first.
fn judge(
    answer: &RelayFetchOutcome,
    own: &PublicKey,
    kind: Kind,
    current: &(dyn Fn(&[&Event]) -> bool + Sync),
) -> OwnEventPresence {
    let mine: Vec<&Event> = answer
        .events
        .iter()
        .filter(|event| event.pubkey == *own && event.kind == kind)
        .collect();
    if current(&mine) {
        OwnEventPresence::Current
    } else if !answer.drained {
        OwnEventPresence::NoAnswer
    } else if mine.is_empty() {
        OwnEventPresence::Missing
    } else {
        OwnEventPresence::Outdated
    }
}

fn kp_entry(event: &Event) -> RelayKpEntry {
    RelayKpEntry {
        d_tag: kp_event_d_tag(event).unwrap_or_default(),
        event_id: event.id.to_hex(),
        created_at: event.created_at.as_secs(),
        pre_migration: kp_event_is_pre_migration(event),
    }
}

/// The relay list a kind-10002 (`r`) or kind-10050 (`relay`) event names, as
/// maintenance reads it: every such tag, whatever its marker.
fn tagged_urls(event: &Event, name: &str) -> Vec<String> {
    event
        .tags
        .iter()
        .filter_map(|tag| {
            let values = tag.as_slice();
            (values.len() >= 2 && values[0] == name).then(|| values[1].clone())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::maintenance::KeyPackageLifetime;
    use crate::relay::recording_front::RecordingFront;
    use crate::relay::scripted_relay::{Frame, ScriptedRelay};
    use nostr::{EventBuilder, Keys, Tag, Timestamp};
    use OwnEventPresence::{Current, Missing, NoAnswer, NotExpected, Outdated};

    const VALID: TrackedKpLifetime = TrackedKpLifetime::Known(KeyPackageLifetime::new(0, u64::MAX));
    const GONE: &str = "wss://gone.example.com";
    /// A slot a conformant inviter accepts.
    const SLOT: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

    fn signed(keys: &Keys, kind: Kind, tags: Vec<Tag>, at: u64) -> Event {
        EventBuilder::new(kind, "")
            .tags(tags)
            .custom_created_at(Timestamp::from_secs(at))
            .sign_with_keys(keys)
            .expect("a locally built event signs")
    }

    /// A relay list of `kind` naming `urls`, in the tags its kind uses.
    fn list(keys: &Keys, kind: Kind, urls: &[&str], at: u64) -> Event {
        let name = if kind == Kind::RelayList {
            "r"
        } else {
            "relay"
        };
        let tags = urls
            .iter()
            .map(|url| Tag::parse([name, url]).expect("a relay tag"))
            .collect();
        signed(keys, kind, tags, at)
    }

    /// A kind 30443 in slot `d`; its content is never read here.
    fn key_package(keys: &Keys, d: &str, at: u64) -> Event {
        let tags = vec![Tag::parse(["d", d]).expect("a d tag")];
        signed(keys, Kind::Custom(KIND_MARMOT_KEY_PACKAGE), tags, at)
    }

    /// Answers every REQ for `kind` with `frames`.
    fn answer(relay: &ScriptedRelay, kind: Kind, frames: Vec<Frame>) {
        relay.answer(
            move |filter| filter.kinds.as_ref().is_some_and(|k| k.contains(&kind)),
            frames,
        );
    }

    fn served(events: Vec<Event>) -> Vec<Frame> {
        events
            .into_iter()
            .map(Frame::Event)
            .chain(std::iter::once(Frame::Eose))
            .collect()
    }

    /// This device's record of `event`, published and still openable.
    fn tracked_in_slot(event: &Event) -> TrackedKeyPackage {
        TrackedKeyPackage {
            slot: kp_event_d_tag(event).expect("a slot"),
            published: Some(event.clone()),
            created_at: Some(event.created_at.as_secs()),
            package: vec![1],
            pending: None,
            adopted: false,
            replacement_owed: false,
            consumed_but_held: false,
        }
    }

    async fn presence(
        own: &Keys,
        inbox: &[String],
        key_package: &[String],
        lookup: &[String],
        tracked: Option<&TrackedKeyPackage>,
        lifetime: TrackedKpLifetime,
    ) -> Vec<OwnRelayPresence> {
        own_presence(
            &RelayManager::new(),
            &own.public_key(),
            &OwnRelayLists {
                inbox,
                key_package,
                lookup,
            },
            tracked,
            lifetime,
        )
        .await
    }

    fn kinds_of(row: &OwnRelayPresence) -> [OwnEventPresence; 3] {
        [row.key_package, row.relay_list, row.inbox_relay_list]
    }

    /// The kinds of every REQ the front handed on, in order.
    fn asked_kinds(front: &RecordingFront) -> Vec<u64> {
        front
            .frames()
            .iter()
            .filter_map(|frame| serde_json::from_str::<serde_json::Value>(&frame.text).ok())
            .filter(|message| message[0] == "REQ")
            .flat_map(|message| {
                message[2]["kinds"]
                    .as_array()
                    .expect("a REQ names its kinds")
                    .iter()
                    .map(|kind| kind.as_u64().expect("a kind"))
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    /// A loopback address nothing listens on.
    fn dead_relay() -> String {
        let _ = crate::relay::allow_ws_loopback_for_test();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("local addr").port();
        drop(listener);
        format!("ws://127.0.0.1:{port}")
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn each_relay_is_asked_only_for_the_kinds_its_lists_expect() {
        let relays = [
            ScriptedRelay::start(),
            ScriptedRelay::start(),
            ScriptedRelay::start(),
        ];
        let fronts = relays
            .each_ref()
            .map(|relay| RecordingFront::start(relay.url()));
        let [inbox, key_package, lookup] = fronts.each_ref().map(|f| vec![f.url().to_owned()]);

        let rows = presence(
            &Keys::generate(),
            &inbox,
            &key_package,
            &lookup,
            None,
            VALID,
        )
        .await;

        let shape = |row: &OwnRelayPresence| {
            (
                row.relay_url.clone(),
                row.own,
                row.lookup,
                row.reachable,
                kinds_of(row),
            )
        };
        assert_eq!(
            rows.iter().map(shape).collect::<Vec<_>>(),
            [
                (
                    inbox[0].clone(),
                    true,
                    false,
                    true,
                    [NotExpected, NotExpected, Missing]
                ),
                (
                    key_package[0].clone(),
                    true,
                    false,
                    true,
                    [Missing, Missing, NotExpected]
                ),
                (
                    lookup[0].clone(),
                    false,
                    true,
                    true,
                    [NotExpected, Missing, Missing]
                ),
            ],
        );
        let [inbox_asked, key_package_asked, lookup_asked] = fronts.each_ref().map(asked_kinds);
        assert_eq!(
            inbox_asked,
            [10050],
            "an inbox relay holds no 30443 or 10002"
        );
        assert_eq!(key_package_asked, [10002, 30443]);
        assert_eq!(
            lookup_asked,
            [10002, 10050],
            "a lookup relay holds no 30443"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_rows_are_the_lists_deduplicated_each_entry_verbatim() {
        let (a, b) = (ScriptedRelay::start(), ScriptedRelay::start());
        // Spelt as no other list spells it: the same relay by maintenance's
        // rule, and echoed as configured.
        let a_upper = a.url().replace("ws://127.0.0.1", "WS://127.0.0.1");
        let rows = presence(
            &Keys::generate(),
            std::slice::from_ref(&a_upper),
            &[a.url().to_owned(), b.url().to_owned()],
            &[a.url().to_owned(), b.url().to_owned()],
            None,
            VALID,
        )
        .await;

        assert_eq!(
            rows.iter()
                .map(|row| (row.relay_url.as_str(), row.own, row.lookup))
                .collect::<Vec<_>>(),
            [(a_upper.as_str(), true, true), (b.url(), true, true)],
        );
        assert!(
            rows.iter()
                .all(|row| row.reachable && kinds_of(row) == [Missing; 3]),
            "an own relay that is also a lookup relay is asked for all three: {rows:?}",
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_list_is_current_only_when_its_newest_copy_names_the_configured_list() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let configured = vec![relay.url().to_owned()];
        let current = [relay.url()];

        answer(
            &relay,
            Kind::RelayList,
            served(vec![list(&own, Kind::RelayList, &current, 2_000)]),
        );
        answer(
            &relay,
            Kind::InboxRelays,
            served(vec![list(&own, Kind::InboxRelays, &[GONE], 2_000)]),
        );
        let rows = presence(&own, &configured, &configured, &[], None, VALID).await;
        assert_eq!(
            (rows[0].relay_list, rows[0].inbox_relay_list),
            (Current, Outdated)
        );

        // The newest copy is judged, whatever order the relay sent them in.
        answer(
            &relay,
            Kind::RelayList,
            served(vec![
                list(&own, Kind::RelayList, &current, 1_000),
                list(&own, Kind::RelayList, &[GONE], 2_000),
            ]),
        );
        answer(
            &relay,
            Kind::InboxRelays,
            served(vec![
                list(&own, Kind::InboxRelays, &[GONE], 1_000),
                list(&own, Kind::InboxRelays, &current, 2_000),
            ]),
        );
        let rows = presence(&own, &configured, &configured, &[], None, VALID).await;
        assert_eq!(
            (rows[0].relay_list, rows[0].inbox_relay_list),
            (Outdated, Current)
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn only_this_devices_valid_tracked_package_reads_current() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let kp_list = vec![relay.url().to_owned()];
        let tracked_event = key_package(&own, SLOT, 1_000);
        let record = tracked_in_slot(&tracked_event);
        let tracked = Some(&record);
        let newer = key_package(&own, SLOT, 2_000);
        let older = key_package(&own, SLOT, 500);
        let other_slot = key_package(&own, &"b2".repeat(32), 2_000);
        let cases = [
            ("the tracked event", &tracked_event, tracked, VALID, Current),
            ("a newer event in the slot", &newer, tracked, VALID, Current),
            (
                "an older event in the slot",
                &older,
                tracked,
                VALID,
                Outdated,
            ),
            ("only another slot", &other_slot, tracked, VALID, Outdated),
            (
                "an adopted slot",
                &tracked_event,
                tracked,
                TrackedKpLifetime::Absent,
                Outdated,
            ),
            (
                "an expired package",
                &tracked_event,
                tracked,
                TrackedKpLifetime::NotCurrent,
                Outdated,
            ),
            (
                "an unreadable package",
                &tracked_event,
                tracked,
                TrackedKpLifetime::Unreadable,
                Outdated,
            ),
            ("nothing tracked", &tracked_event, None, VALID, Outdated),
        ];
        for (case, event, tracked, lifetime, expected) in cases {
            answer(
                &relay,
                Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
                served(vec![event.clone()]),
            );
            let rows = presence(&own, &[], &kp_list, &[], tracked, lifetime).await;
            assert_eq!(rows[0].key_package, expected, "{case}");
        }
        answer(
            &relay,
            Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
            served(vec![]),
        );
        let rows = presence(&own, &[], &kp_list, &[], tracked, VALID).await;
        assert_eq!(rows[0].key_package, Missing, "nothing served");
    }

    /// A package maintenance would replace never reads current, however the
    /// relay serves it: the Settings check and the tick share one rule.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_package_maintenance_would_replace_reads_outdated() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let kp_list = vec![relay.url().to_owned()];
        let tracked_event = key_package(&own, SLOT, 1_000);
        let record = tracked_in_slot(&tracked_event);
        // Maintenance's own rule: a Welcome consumed the package and its key
        // is gone, so it is owed a replacement and opens nothing.
        let consumed_not_held = TrackedKeyPackage {
            replacement_owed: true,
            ..record.clone()
        };
        let consumed_but_held = TrackedKeyPackage {
            replacement_owed: true,
            consumed_but_held: true,
            ..record.clone()
        };
        let bundle_lost = TrackedKeyPackage {
            package: Vec::new(),
            ..record.clone()
        };
        let never_acknowledged = TrackedKeyPackage {
            published: None,
            ..record
        };

        let cases = [
            (
                "a consumed package whose key is not held",
                &consumed_not_held,
                Outdated,
            ),
            (
                "a consumed package whose key is still held",
                &consumed_but_held,
                Current,
            ),
            ("a package whose bundle is lost", &bundle_lost, Outdated),
            (
                "a package no relay acknowledged",
                &never_acknowledged,
                Outdated,
            ),
        ];
        answer(
            &relay,
            Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
            served(vec![tracked_event]),
        );
        for (case, tracked, expected) in cases {
            let rows = presence(&own, &[], &kp_list, &[], Some(tracked), VALID).await;
            assert_eq!(rows[0].key_package, expected, "{case}");
        }
    }

    /// A slot a conformant inviter rejects is retired by maintenance before
    /// anything is published into it, so the package there is not current.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_package_in_a_non_conformant_slot_is_outdated() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let kp_list = vec![relay.url().to_owned()];
        for (slot, expected) in [("slot", Outdated), (SLOT, Current)] {
            let event = key_package(&own, slot, 1_000);
            answer(
                &relay,
                Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
                served(vec![event.clone()]),
            );
            let rows = presence(
                &own,
                &[],
                &kp_list,
                &[],
                Some(&tracked_in_slot(&event)),
                VALID,
            )
            .await;
            assert_eq!(rows[0].key_package, expected, "slot {slot:?}");
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn another_authors_event_never_counts() {
        let (own, other) = (Keys::generate(), Keys::generate());
        let relay = ScriptedRelay::start();
        let lists = vec![relay.url().to_owned()];
        let tracked_event = key_package(&own, SLOT, 1_000);
        // Each would read current were its author not checked.
        answer(
            &relay,
            Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
            served(vec![key_package(&other, SLOT, 2_000)]),
        );
        answer(
            &relay,
            Kind::RelayList,
            served(vec![list(&other, Kind::RelayList, &[relay.url()], 2_000)]),
        );
        answer(
            &relay,
            Kind::InboxRelays,
            served(vec![list(&other, Kind::InboxRelays, &[relay.url()], 2_000)]),
        );

        let rows = presence(
            &own,
            &lists,
            &lists,
            &[],
            Some(&tracked_in_slot(&tracked_event)),
            VALID,
        )
        .await;
        assert_eq!(kinds_of(&rows[0]), [Missing; 3]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_req_the_relay_closed_is_no_answer_unless_what_came_first_is_current() {
        let own = Keys::generate();
        let relay = ScriptedRelay::start();
        let lists = vec![relay.url().to_owned()];
        let closed = || Frame::Closed("rate-limited: slow down".to_owned());
        answer(
            &relay,
            Kind::Custom(KIND_MARMOT_KEY_PACKAGE),
            vec![closed()],
        );
        answer(
            &relay,
            Kind::RelayList,
            vec![
                Frame::Event(list(&own, Kind::RelayList, &[GONE], 2_000)),
                closed(),
            ],
        );
        answer(
            &relay,
            Kind::InboxRelays,
            vec![
                Frame::Event(list(&own, Kind::InboxRelays, &[relay.url()], 2_000)),
                closed(),
            ],
        );

        let rows = presence(&own, &lists, &lists, &[], None, VALID).await;
        assert!(rows[0].reachable);
        assert_eq!(kinds_of(&rows[0]), [NoAnswer, NoAnswer, Current]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_relay_that_cannot_be_reached_is_no_answer() {
        let unreachable = vec![
            dead_relay(),
            "ws://insecure.relay.example.com".to_owned(),
            "not-a-url".to_owned(),
        ];
        let rows = presence(
            &Keys::generate(),
            &unreachable,
            &unreachable,
            &[],
            None,
            VALID,
        )
        .await;
        assert_eq!(rows.len(), 3);
        for row in &rows {
            assert!(!row.reachable, "{row:?}");
            assert_eq!(kinds_of(row), [NoAnswer; 3], "{row:?}");
        }
    }

    #[test]
    fn own_relay_presence_debug_redacts_the_relay() {
        const RELAY: &str = "wss://private.relay.example.com";
        let row = OwnRelayPresence {
            relay_url: RELAY.to_owned(),
            own: true,
            lookup: false,
            reachable: true,
            key_package: Current,
            relay_list: Outdated,
            inbox_relay_list: NoAnswer,
        };
        crate::assert_debug_redacted!(
            &row,
            "OwnRelayPresence",
            &[RELAY, "private.relay.example.com"]
        );
    }
}
