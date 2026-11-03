//! The relay-plane judge and its journal consumer, `haven-wire-planes` (C8).
//!
//! Three halves. The judge, table-driven over `ROWS` so a row added without a
//! fixture fails: every row admits its own shape on its own list and nothing
//! else, plus one named test per binding rule. The CLI, one journal fixture per
//! C8 case, run in-process, the case count pinned. And the two parity pins: the
//! exported `tooling/e2e/relay_planes.json` and the table in
//! `haven-core/SECURITY.md` are `ROWS`, byte for byte.
//!
//! Every fixture plants pubkeys, routing ids, event ids, subscription ids,
//! URLs, ports and listens, and every rendering — a finding's `Debug`, the
//! CLI's stdout and stderr — is checked to hold none of them (Security
//! Rule 15). No assertion here prints a frame or a table.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use haven_local_relay::planes::cli::{
    self, RC_CLEAN, RC_META_FLOOR, RC_UNUSABLE, RC_USAGE, RC_VIOLATION,
};
use haven_local_relay::planes::frame::Frame;
use haven_local_relay::planes::judge::{judge, Class, Judgement, Observed};
use haven_local_relay::planes::policy::{render_markdown, Plane, Role, Row, Verb, ROWS};
use haven_local_relay::planes::table::{
    List, PlaneTable, RelayIx, RelayMatch, RoutingEnd, Unusable,
};
use serde_json::{json, Value};

// ---------------------------------------------------------------------------
// Planted values
// ---------------------------------------------------------------------------

fn alice() -> String {
    "a1".repeat(32)
}
fn bob() -> String {
    "b2".repeat(32)
}
fn carol() -> String {
    "c3".repeat(32)
}
fn dave() -> String {
    "d4".repeat(32)
}
fn eph(n: u32) -> String {
    format!("{:064x}", 0x00e0_0000_u64 + u64::from(n))
}
fn id(n: u32) -> String {
    format!("{:064x}", 0x001d_0000_u64 + u64::from(n))
}
fn hx() -> String {
    "0f".repeat(32)
}
fn hy() -> String {
    "1e".repeat(32)
}
fn hz() -> String {
    "2d".repeat(32)
}
fn hw() -> String {
    "3c".repeat(32)
}
const TOKEN: &str = "HAVEN_WIRE_SENTINEL:5e771e1ab0b0cafe5e771e1ab0b0cafe";

/// Every value a rendering must never hold.
fn planted() -> Vec<String> {
    let mut values = vec![
        alice(),
        bob(),
        carol(),
        dave(),
        hx(),
        hy(),
        hz(),
        hw(),
        TOKEN.to_owned(),
        "5e771e1ab0b0cafe".to_owned(),
        "127.0.0.".to_owned(),
        "10.0.2.2".to_owned(),
        "ws://".to_owned(),
        "wss://".to_owned(),
        ".example".to_owned(),
        "778".to_owned(),
        "779".to_owned(),
        "sub-".to_owned(),
        "harness-sock".to_owned(),
        "app-".to_owned(),
        "probe-sock".to_owned(),
    ];
    // A 16-hex prefix of each is an identifier too.
    for prefix in [alice(), bob(), hx(), hy()] {
        values.push(prefix[..16].to_owned());
    }
    for n in 0..64 {
        values.push(eph(n));
        values.push(id(n));
    }
    values
}

fn assert_holds_no_value(rendered: &str, what: &str) {
    for value in planted() {
        assert!(
            !rendered.contains(&value),
            "{what} holds a planted identifier (Security Rule 15)"
        );
    }
}

fn event(id: &str, pubkey: &str, kind: u16, created_at: u64, tags: &[&[&str]]) -> Value {
    json!({
        "id": id,
        "pubkey": pubkey,
        "kind": kind,
        "created_at": created_at,
        "tags": tags,
        "content": "",
        "sig": "00",
    })
}

fn kp_tags() -> Vec<Vec<&'static str>> {
    vec![
        vec!["d", "5107"],
        vec!["mls_protocol_version", "1.0"],
        vec!["i", "0a0b"],
        vec!["mls_ciphersuite", "0x0001"],
        vec!["mls_extensions", "0x000a"],
        vec!["mls_proposals", "0x000a"],
        vec!["app_components", "0x8009", "0x800c"],
    ]
}

fn kp_event(id: &str, pubkey: &str) -> Value {
    let tags = kp_tags();
    let tags: Vec<&[&str]> = tags.iter().map(Vec::as_slice).collect();
    event(id, pubkey, 30443, 1_000, &tags)
}

// ---------------------------------------------------------------------------
// The judge
// ---------------------------------------------------------------------------

/// One relay per plane, so each frame has exactly one home.
struct World {
    table: PlaneTable,
    a_inbox: RelayIx,
    a_kp: RelayIx,
    disc: RelayIx,
    prof: RelayIx,
    loc_x: RelayIx,
    loc_y: RelayIx,
    b_inbox: RelayIx,
    b_write: RelayIx,
}

const A_INBOX: &str = "wss://alice-inbox.example";
const A_KP: &str = "wss://alice-kp.example:7443";
const DISC: &str = "wss://discovery.example";
const PROF: &str = "wss://profile.example";
const LOC_X: &str = "wss://loc-x.example";
const LOC_Y: &str = "wss://loc-y.example";
const B_INBOX: &str = "wss://bob-inbox.example";
const B_WRITE: &str = "wss://bob-write.example";

fn world() -> World {
    let mut table = PlaneTable::new(RelayMatch::Authority);
    let mut relay = |url| table.add_relay(url).expect("a relay URL");
    let (a_inbox, a_kp, disc, prof) = (relay(A_INBOX), relay(A_KP), relay(DISC), relay(PROF));
    let (loc_x, loc_y, b_inbox, b_write) =
        (relay(LOC_X), relay(LOC_Y), relay(B_INBOX), relay(B_WRITE));
    let (alice, bob) = (alice(), bob());
    table.add(List::OwnInbox(&alice), a_inbox, 0);
    table.add(List::OwnKeyPackage(&alice), a_kp, 0);
    table.add(List::Discovery, disc, 0);
    table.add(List::Profile, prof, 0);
    table.add_routing(&hx(), loc_x, 0);
    table.add_routing(&hy(), loc_y, 0);
    table.add(List::InviteeInbox(&bob), b_inbox, 0);
    table.add(List::InviteeNip65Write(&bob), b_write, 0);
    table.add_member(&hx(), &alice, 0);
    table.add_member(&hy(), &alice, 0);
    table.index_event(&id(1), 445, Some(&hx()));
    table.index_event(&id(2), 30443, None);
    table.index_event(&id(3), 10050, None);
    World {
        table,
        a_inbox,
        a_kp,
        disc,
        prof,
        loc_x,
        loc_y,
        b_inbox,
        b_write,
    }
}

impl World {
    const fn all(&self) -> [RelayIx; 8] {
        [
            self.a_inbox,
            self.a_kp,
            self.disc,
            self.prof,
            self.loc_x,
            self.loc_y,
            self.b_inbox,
            self.b_write,
        ]
    }
}

fn frame(value: &Value) -> Frame {
    Frame::from_value(value)
}

/// Judges one frame, sent at `at` on connection 0.
fn judge_one(
    table: &PlaneTable,
    relay: RelayIx,
    sender: Option<&str>,
    at: u64,
    value: &Value,
) -> Judgement {
    let frame = frame(value);
    judge(
        table,
        [Observed {
            relay,
            conn: 0,
            sender,
            at,
            frame: &frame,
        }],
    )
    .expect("the world is usable")
}

/// The one class a judgement found, rendering checked.
fn only_class(judgement: &Judgement) -> Option<Class> {
    assert_holds_no_value(&format!("{:?}", judgement.findings), "a judgement's Debug");
    match judgement.findings.as_slice() {
        [] => None,
        [finding] => Some(finding.class),
        _ => panic!("more than one finding for one frame"),
    }
}

fn admitted(table: &PlaneTable, relay: RelayIx, sender: Option<&str>, value: &Value) -> bool {
    only_class(&judge_one(table, relay, sender, 10, value)).is_none()
}

fn class_of(
    table: &PlaneTable,
    relay: RelayIx,
    sender: Option<&str>,
    value: &Value,
) -> Option<Class> {
    only_class(&judge_one(table, relay, sender, 10, value))
}

#[allow(clippy::too_many_lines)]
/// The shape of each row, the relays it may land on, and the plane that
/// admits it there. A row with no arm here does not compile.
fn fixture(w: &World, row: Row) -> (Value, Option<String>, Vec<RelayIx>, Plane) {
    let (a, b) = (alice(), bob());
    let a_str = Some(a.clone());
    match row {
        Row::Ev445Commit => (
            json!([
                "EVENT",
                event(&id(10), &eph(1), 445, 1_000, &[&["h", &hx()]])
            ]),
            None,
            vec![w.loc_x],
            Plane::Location,
        ),
        Row::Ev445Location => (
            json!([
                "EVENT",
                event(
                    &id(11),
                    &eph(2),
                    445,
                    1_000,
                    &[&["h", &hx()], &["expiration", "1228"]]
                )
            ]),
            None,
            vec![w.loc_x],
            Plane::Location,
        ),
        Row::Ev1059 => (
            json!(["EVENT", event(&id(12), &eph(3), 1059, 1_000, &[&["p", &b]])]),
            a_str,
            vec![w.b_inbox],
            Plane::InviteeInbox,
        ),
        Row::Ev30443 => (
            json!(["EVENT", kp_event(&id(13), &a)]),
            a_str,
            vec![w.a_kp],
            Plane::OwnKeyPackage,
        ),
        Row::Ev10002 => (
            json!(["EVENT", event(&id(14), &a, 10002, 1_000, &[&["r", A_KP]])]),
            a_str,
            vec![w.a_kp],
            Plane::OwnKeyPackage,
        ),
        Row::Ev10050 => (
            json!([
                "EVENT",
                event(&id(15), &a, 10050, 1_000, &[&["relay", A_INBOX]])
            ]),
            a_str,
            vec![w.a_inbox],
            Plane::OwnInbox,
        ),
        Row::Ev0 => (
            json!(["EVENT", event(&id(16), &a, 0, 1_000, &[])]),
            a_str,
            vec![w.prof],
            Plane::Profile,
        ),
        Row::Ev5 => (
            json!([
                "EVENT",
                event(
                    &id(17),
                    &a,
                    5,
                    1_000,
                    &[&["k", "0"], &["a", &format!("0:{a}:")]]
                )
            ]),
            a_str,
            vec![w.prof],
            Plane::Profile,
        ),
        Row::Req445H => (
            json!(["REQ", "sub-h", {"kinds": [445], "#h": [hx()], "since": 1}]),
            a_str,
            vec![w.loc_x],
            Plane::Location,
        ),
        Row::Req445Ids => (
            json!(["REQ", "sub-i", {"ids": [id(1)], "kinds": [445], "limit": 1}]),
            a_str,
            vec![w.loc_x],
            Plane::Location,
        ),
        Row::Req1059P => (
            json!(["REQ", "sub-p", {"kinds": [1059], "#p": [a], "since": 1, "limit": 1000}]),
            a_str,
            vec![w.a_inbox],
            Plane::OwnInbox,
        ),
        Row::Req30443A => (
            json!(["REQ", "sub-k", {"kinds": [30443], "authors": [b], "limit": 10}]),
            a_str,
            vec![w.disc, w.b_write],
            Plane::Discovery,
        ),
        Row::Req10002A => (
            json!(["REQ", "sub-r", {"kinds": [10002], "authors": [b], "limit": 1}]),
            a_str,
            vec![w.disc, w.b_write],
            Plane::Discovery,
        ),
        Row::Req10050A => (
            json!(["REQ", "sub-l", {"kinds": [10050], "authors": [b], "limit": 1}]),
            a_str,
            vec![w.disc, w.b_inbox],
            Plane::Discovery,
        ),
        Row::Req0A => (
            json!(["REQ", "sub-0", {"kinds": [0], "authors": [b], "limit": 4}]),
            a_str,
            vec![w.prof],
            Plane::Profile,
        ),
        Row::Neg445H => (
            json!(["NEG-OPEN", "sub-n", {"kinds": [445], "#h": [hx()], "since": 1, "until": 2, "limit": 16384}, "6100000200"]),
            a_str,
            vec![w.loc_x],
            Plane::Location,
        ),
    }
}

#[test]
fn the_rows_are_listed_in_declaration_order_with_unique_ids() {
    for (i, spec) in ROWS.iter().enumerate() {
        assert!(
            spec.row as usize == i,
            "ROWS[{i}] is out of declaration order"
        );
        assert!(
            std::ptr::eq(spec.row.spec(), spec),
            "Row::spec misses ROWS[{i}]"
        );
        assert!(
            ROWS.iter()
                .filter(|other| other.row.id() == spec.row.id())
                .count()
                == 1,
            "row id {} is not unique",
            spec.row.id()
        );
    }
}

#[test]
fn every_row_admits_its_own_shape_on_its_own_list_and_nothing_else() {
    let w = world();
    for spec in &ROWS {
        let (value, sender, homes, plane) = fixture(&w, spec.row);
        let crossed = if spec.verb == Verb::Event {
            Class::CrossedEvent
        } else {
            Class::CrossedRequest
        };
        for relay in w.all() {
            let judgement = judge_one(&w.table, relay, sender.as_deref(), 10, &value);
            assert_holds_no_value(&format!("{:?}", judgement.findings), "a judgement's Debug");
            if homes.contains(&relay) {
                assert!(
                    judgement.findings.is_empty(),
                    "{} is refused on its own list: {:?}",
                    spec.row.id(),
                    judgement.findings
                );
                assert!(
                    judgement
                        .hits
                        .iter()
                        .map(|(&(r, row, _), &n)| (r, row, n))
                        .eq([(relay, spec.row, 1)]),
                    "{} admitted but not counted once on its relay",
                    spec.row.id()
                );
            } else {
                assert!(
                    judgement.findings.len() == 1
                        && judgement.findings[0].row == Some(spec.row)
                        && judgement.findings[0].class == crossed,
                    "{} on a relay off its list: {:?}",
                    spec.row.id(),
                    judgement.findings
                );
                assert!(
                    judgement.hits.is_empty(),
                    "{} counted on a relay off its list",
                    spec.row.id()
                );
            }
        }
        let first_home = judge_one(&w.table, homes[0], sender.as_deref(), 10, &value);
        assert!(
            first_home.hits.keys().all(|&(_, _, p)| p == plane),
            "{} admitted through the wrong plane",
            spec.row.id()
        );
    }
}

#[test]
fn a_445_for_one_circle_on_the_other_circles_relay_is_a_crossing() {
    let w = world();
    let location = json!([
        "EVENT",
        event(
            &id(20),
            &eph(4),
            445,
            1_000,
            &[&["h", &hy()], &["expiration", "1100"]]
        )
    ]);
    assert!(admitted(&w.table, w.loc_y, None, &location));
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &location),
        Some(Class::CrossedEvent)
    );
}

#[test]
fn a_1059_for_one_recipient_on_another_recipients_inbox_is_a_crossing() {
    let mut w = world();
    let c_inbox = w.table.add_relay("wss://carol-inbox.example").expect("url");
    w.table.add(List::InviteeInbox(&carol()), c_inbox, 0);
    let wrap = json!([
        "EVENT",
        event(&id(21), &eph(5), 1059, 1_000, &[&["p", &carol()]])
    ]);
    assert!(admitted(&w.table, c_inbox, None, &wrap));
    assert_eq!(
        class_of(&w.table, w.b_inbox, None, &wrap),
        Some(Class::CrossedEvent)
    );
}

#[test]
fn an_inbox_req_for_another_account_is_a_crossing_when_the_sender_is_known() {
    let w = world();
    let req = json!(["REQ", "sub-p", {"kinds": [1059], "#p": [bob()], "limit": 100}]);
    assert_eq!(
        class_of(&w.table, w.b_inbox, Some(&alice()), &req),
        Some(Class::CrossedRequest)
    );
    assert!(admitted(&w.table, w.b_inbox, Some(&bob()), &req));
}

/// `giftWrapIdsFor`: with no sender the binding is the `#p` value's own list,
/// never "self".
#[test]
fn the_gift_wrap_ids_shape_is_bound_to_the_value_s_own_list() {
    let w = world();
    let req = json!(["REQ", "sub-g", {"kinds": [1059], "#p": [bob()], "limit": 100}]);
    assert!(admitted(&w.table, w.b_inbox, None, &req));
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &req),
        Some(Class::CrossedRequest)
    );
}

#[test]
fn discovery_never_admits_an_event() {
    let w = world();
    for spec in ROWS.iter().filter(|spec| spec.verb == Verb::Event) {
        let (value, sender, _, _) = fixture(&w, spec.row);
        assert!(
            class_of(&w.table, w.disc, sender.as_deref(), &value).is_some(),
            "{} admitted on discovery",
            spec.row.id()
        );
    }
}

#[test]
fn a_profile_relay_admits_kind_0_its_lookup_and_its_retraction_only() {
    let w = world();
    let admitted_rows: Vec<Row> = ROWS
        .iter()
        .filter(|spec| {
            let (value, sender, _, _) = fixture(&w, spec.row);
            admitted(&w.table, w.prof, sender.as_deref(), &value)
        })
        .map(|spec| spec.row)
        .collect();
    assert_eq!(admitted_rows, [Row::Ev0, Row::Ev5, Row::Req0A]);
}

#[test]
fn a_kind_5_inherits_the_plane_of_every_kind_it_retracts() {
    let w = world();
    let a = alice();
    let retract = |n, tags: &[&[&str]]| json!(["EVENT", event(&id(n), &a, 5, 1_000, tags)]);
    let by_k = retract(30, &[&["k", "10050"]]);
    assert!(admitted(&w.table, w.a_inbox, None, &by_k));
    assert_eq!(
        class_of(&w.table, w.prof, None, &by_k),
        Some(Class::CrossedEvent)
    );
    let by_a = retract(31, &[&["a", &format!("30443:{a}:5107")], &["k", "30443"]]);
    assert!(admitted(&w.table, w.a_kp, None, &by_a));
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &by_a),
        Some(Class::CrossedEvent)
    );
    // `e` resolves through the index: a 10050 id with a 10050 coordinate.
    let by_e = retract(32, &[&["e", &id(3)], &["a", &format!("10050:{a}:")]]);
    assert!(admitted(&w.table, w.a_inbox, None, &by_e));
    // The UNION: an `e` naming a key package beside a 10050 coordinate fits
    // no relay, even though the coordinate alone would.
    let mixed_e = retract(33, &[&["e", &id(2)], &["a", &format!("10050:{a}:")]]);
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &mixed_e),
        Some(Class::CrossedEvent)
    );
    let mixed_k = retract(34, &[&["k", "0"], &["a", &format!("10050:{a}:")]]);
    for relay in w.all() {
        assert!(
            class_of(&w.table, relay, None, &mixed_k).is_some(),
            "a k/a union admitted"
        );
    }
    let unresolved = retract(35, &[&["e", &id(60)], &["k", "10050"]]);
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &unresolved),
        Some(Class::UnresolvedId)
    );
    let neither = retract(36, &[&["e", &id(3)]]);
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &neither),
        Some(Class::UnknownFrame)
    );
    let foreign_coordinate = retract(37, &[&["a", &format!("10050:{}:", bob())]]);
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &foreign_coordinate),
        Some(Class::UnknownFrame)
    );
    let slot_without_d = retract(38, &[&["a", &format!("30443:{a}:")]]);
    assert_eq!(
        class_of(&w.table, w.a_kp, None, &slot_without_d),
        Some(Class::UnknownFrame)
    );
}

#[test]
fn a_by_id_request_is_bound_through_the_event_index() {
    let w = world();
    let by_id = |ids: Vec<String>, limit: usize| json!(["REQ", "sub-i", {"ids": ids, "kinds": [445], "limit": limit}]);
    assert!(admitted(&w.table, w.loc_x, None, &by_id(vec![id(1)], 1)));
    assert_eq!(
        class_of(&w.table, w.loc_y, None, &by_id(vec![id(1)], 1)),
        Some(Class::CrossedRequest)
    );
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &by_id(vec![id(60)], 1)),
        Some(Class::UnresolvedId)
    );
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &by_id(vec![id(2)], 1)),
        Some(Class::CrossedRequest)
    );
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &by_id(vec![id(1)], 2)),
        Some(Class::UnknownFrame)
    );
    let with_h =
        json!(["REQ", "sub-i", {"ids": [id(1)], "kinds": [445], "limit": 1, "#h": [hy()]}]);
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &with_h),
        Some(Class::CrossedRequest)
    );
}

#[test]
fn a_relay_holding_two_planes_admits_their_union_only_when_declared() {
    let mut w = world();
    let shared = w.table.add_relay("wss://shared.example").expect("url");
    w.table.add(List::OwnInbox(&alice()), shared, 0);
    w.table.add_routing(&hx(), shared, 0);
    let inbox = json!(["REQ", "sub-p", {"kinds": [1059], "#p": [alice()]}]);
    let frame = frame(&inbox);
    let obs = || Observed {
        relay: shared,
        conn: 0,
        sender: None,
        at: 1,
        frame: &frame,
    };
    assert!(matches!(
        judge(&w.table, [obs()]),
        Err(Unusable::UndeclaredOverlap(
            Plane::OwnInbox,
            Plane::Location
        ))
    ));
    assert!(w.table.declare_overlap(Plane::Location, Plane::OwnInbox));
    assert!(admitted(&w.table, shared, None, &inbox));
    let location = json!([
        "EVENT",
        event(
            &id(40),
            &eph(6),
            445,
            1_000,
            &[&["h", &hx()], &["expiration", "1001"]]
        )
    ]);
    assert!(admitted(&w.table, shared, None, &location));
    assert_eq!(w.table.overlapping_relays(), 1);
}

#[test]
fn a_profile_or_location_discovery_overlap_is_unusable_and_cannot_be_declared() {
    let mut located = world();
    assert!(!located
        .table
        .declare_overlap(Plane::Location, Plane::Discovery));
    located.table.add(List::Discovery, located.loc_x, 0);
    let req = frame(&json!(["REQ", "sub-h", {"kinds": [445], "#h": [hx()]}]));
    let located_result = judge(
        &located.table,
        [Observed {
            relay: located.loc_x,
            conn: 0,
            sender: None,
            at: 1,
            frame: &req,
        }],
    );
    assert!(matches!(
        located_result,
        Err(Unusable::Undeclarable(Plane::Discovery, Plane::Location))
    ));
    let mut w = world();
    assert!(!w.table.declare_overlap(Plane::Profile, Plane::Discovery));
    assert!(!w
        .table
        .declare_overlap(Plane::OwnInbox, Plane::OwnKeyPackage));
    w.table.add(List::Discovery, w.prof, 0);
    let frame = frame(&json!(["REQ", "sub-0", {"kinds": [0], "authors": [bob()]}]));
    let result = judge(
        &w.table,
        [Observed {
            relay: w.prof,
            conn: 0,
            sender: None,
            at: 1,
            frame: &frame,
        }],
    );
    assert!(matches!(
        result,
        Err(Unusable::Undeclarable(Plane::Discovery, Plane::Profile))
    ));
    assert_holds_no_value(&format!("{:?}", result.err()), "an Unusable's Debug");
}

#[test]
fn a_prior_routing_stands_then_is_kept_then_is_gone() {
    let mut w = world();
    let loc_z = w.table.add_relay("wss://loc-z.example").expect("url");
    w.table.add_routing(&hx(), loc_z, 5);
    w.table.retire_routing(
        &hx(),
        w.loc_x,
        RoutingEnd {
            removed: 5,
            stands_until: Some(8),
            kept_until: Some(12),
            left_at_secs: Some(2_000),
        },
    );
    let t = &w.table;
    let live = json!(["REQ", "sub-h", {"kinds": [445], "#h": [hx()]}]);
    let at = |relay, n, value: &Value| only_class(&judge_one(t, relay, None, n, value));
    assert_eq!(
        at(w.loc_x, 7, &live),
        None,
        "a prior routing stands inside its window"
    );
    assert_eq!(at(w.loc_x, 8, &live), Some(Class::CrossedRequest));
    assert_eq!(
        at(loc_z, 4, &live),
        Some(Class::CrossedRequest),
        "a routing before it was staged"
    );
    assert_eq!(at(loc_z, 5, &live), None);
    let commit = json!([
        "EVENT",
        event(&id(41), &eph(7), 445, 3_000, &[&["h", &hx()]])
    ]);
    assert_eq!(
        at(w.loc_x, 11, &commit),
        None,
        "a commit's frozen targets include the routing it left"
    );
    assert_eq!(at(w.loc_x, 12, &commit), Some(Class::CrossedEvent));
    let sealed_before = json!([
        "EVENT",
        event(
            &id(42),
            &eph(8),
            445,
            2_000,
            &[&["h", &hx()], &["expiration", "2228"]]
        )
    ]);
    let sealed_after = json!([
        "EVENT",
        event(
            &id(43),
            &eph(9),
            445,
            2_001,
            &[&["h", &hx()], &["expiration", "2229"]]
        )
    ]);
    assert_eq!(
        at(w.loc_x, 6, &sealed_before),
        None,
        "a location sealed before the change"
    );
    assert_eq!(at(w.loc_x, 6, &sealed_after), Some(Class::CrossedEvent));
    assert_eq!(at(loc_z, 6, &sealed_after), None);
}

#[test]
fn after_removal_a_former_list_admits_only_the_kind_5_scrub_and_close() {
    let mut w = world();
    let a = alice();
    w.table.remove(List::OwnInbox(&a), w.a_inbox, 5);
    let mut viewed = world();
    viewed.table.add(List::InviteeInbox(&a), viewed.a_inbox, 0);
    assert!(viewed
        .table
        .declare_overlap(Plane::OwnInbox, Plane::InviteeInbox));
    viewed.table.remove(List::OwnInbox(&a), viewed.a_inbox, 5);
    let t = &w.table;
    let at = |n, value: &Value| only_class(&judge_one(t, w.a_inbox, None, n, value));
    let list = json!([
        "EVENT",
        event(&id(44), &a, 10050, 1_000, &[&["relay", A_INBOX]])
    ]);
    assert_eq!(at(4, &list), None);
    assert_eq!(at(5, &list), Some(Class::CrossedEvent));
    let inbox = json!(["REQ", "sub-p", {"kinds": [1059], "#p": [a]}]);
    assert_eq!(at(5, &inbox), Some(Class::CrossedRequest));
    // Another account's invitee view of Alice still names the dropped relay;
    // it never stands in for her own list on her own read.
    for sender in [None, Some(a.as_str())] {
        assert_eq!(
            only_class(&judge_one(&viewed.table, viewed.a_inbox, sender, 5, &inbox)),
            Some(Class::CrossedRequest),
            "a FORMER own inbox admitted through an invitee view"
        );
    }
    let scrub = json!([
        "EVENT",
        event(
            &id(45),
            &a,
            5,
            1_000,
            &[&["a", &format!("10050:{a}:")], &["k", "10050"]]
        )
    ]);
    assert_eq!(at(6, &scrub), None, "the scrub of the relay just removed");
    let kp_scrub = json!(["EVENT", event(&id(46), &a, 5, 1_000, &[&["k", "10002"]])]);
    assert_eq!(
        at(6, &kp_scrub),
        Some(Class::CrossedEvent),
        "a former inbox relay is no key-package relay"
    );
    // A Welcome staged while the relay was the account's inbox may still go.
    let wrap = json!([
        "EVENT",
        event(&id(47), &eph(10), 1059, 1_000, &[&["p", &a]])
    ]);
    assert_eq!(at(6, &wrap), None);
    let close_after_req = [
        frame(&json!(["REQ", "sub-p", {"kinds": [1059], "#p": [a]}])),
        frame(&json!(["CLOSE", "sub-p"])),
    ];
    let judgement = judge(
        t,
        close_after_req.iter().map(|frame| Observed {
            relay: w.a_inbox,
            conn: 0,
            sender: None,
            at: 6,
            frame,
        }),
    )
    .expect("usable");
    assert!(
        judgement.findings.len() == 1 && judgement.findings[0].verb == Verb::Req,
        "only the REQ crosses; its CLOSE is admitted: {:?}",
        judgement.findings
    );
}

#[test]
fn auth_count_and_unparsable_frames_are_unknown() {
    let w = world();
    for value in [
        json!(["AUTH", {"kind": 22242}]),
        json!(["COUNT", "sub-c", {"kinds": [445]}]),
        json!(["EVENT"]),
        json!([
            "EVENT",
            event(&id(48), &eph(11), 445, 1, &[&["h", &hx()]]),
            event(&id(49), &eph(12), 445, 1, &[&["h", &hx()]])
        ]),
        json!(["EVENT", {"id": id(50), "kind": "445"}]),
        json!(["REQ", "sub-x", "not a filter"]),
        json!(["REQ", "sub-x"]),
        json!({"not": "an array"}),
        Value::Null,
    ] {
        for relay in w.all() {
            assert_eq!(
                class_of(&w.table, relay, None, &value),
                Some(Class::UnknownFrame)
            );
        }
    }
    assert!(matches!(
        Frame::parse("not json"),
        Frame::Other(Verb::Other)
    ));
}

#[test]
fn a_filter_without_kinds_or_spanning_two_rows_is_unknown() {
    let w = world();
    for filter in [
        json!({"authors": [bob()]}),
        json!({"kinds": [], "authors": [bob()]}),
        json!({"kinds": [445, 1059], "#h": [hx()]}),
        json!({"kinds": [10002, 10050], "authors": [bob()]}),
        json!({"kinds": "445", "#h": [hx()]}),
    ] {
        let req = json!(["REQ", "sub-x", filter]);
        for relay in w.all() {
            assert_eq!(
                class_of(&w.table, relay, None, &req),
                Some(Class::UnknownFrame)
            );
        }
    }
}

#[test]
fn the_filters_of_one_req_must_land_on_one_plane() {
    let mut w = world();
    let shared = w.table.add_relay("wss://shared.example").expect("url");
    w.table.add(List::OwnInbox(&alice()), shared, 0);
    w.table.add(List::Discovery, shared, 0);
    assert!(w.table.declare_overlap(Plane::OwnInbox, Plane::Discovery));
    let inbox = json!({"kinds": [1059], "#p": [alice()]});
    let lookup = json!({"kinds": [10050], "authors": [bob()], "limit": 1});
    assert!(admitted(
        &w.table,
        shared,
        None,
        &json!(["REQ", "sub-p", inbox])
    ));
    assert!(admitted(
        &w.table,
        shared,
        None,
        &json!(["REQ", "sub-l", lookup])
    ));
    assert_eq!(
        class_of(
            &w.table,
            shared,
            None,
            &json!(["REQ", "sub-x", inbox, lookup])
        ),
        Some(Class::UnknownFrame)
    );
    let x = json!({"kinds": [445], "#h": [hx()]});
    let by_id = json!({"ids": [id(1)], "kinds": [445], "limit": 1});
    assert!(admitted(
        &w.table,
        w.loc_x,
        None,
        &json!(["REQ", "sub-h", x, by_id])
    ));
}

#[test]
fn close_and_neg_continuations_must_name_a_subscription_of_their_connection() {
    let w = world();
    let frames = [
        (
            0,
            frame(&json!(["REQ", "sub-h", {"kinds": [445], "#h": [hx()]}])),
        ),
        (
            0,
            frame(
                &json!(["NEG-OPEN", "sub-n", {"kinds": [445], "#h": [hx()], "since": 1, "until": 2, "limit": 16384}, "6100000200"]),
            ),
        ),
        (0, frame(&json!(["NEG-MSG", "sub-n", "6100"]))),
        (0, frame(&json!(["NEG-CLOSE", "sub-n"]))),
        (0, frame(&json!(["CLOSE", "sub-h"]))),
        (1, frame(&json!(["CLOSE", "sub-h"]))),
        (1, frame(&json!(["NEG-MSG", "sub-n", "6100"]))),
        (0, frame(&json!(["NEG-MSG", "sub-h", "6100"]))),
        (0, frame(&json!(["CLOSE", "sub-n"]))),
    ];
    let judgement = judge(
        &w.table,
        frames.iter().map(|(conn, frame)| Observed {
            relay: w.loc_x,
            conn: *conn,
            sender: None,
            at: 1,
            frame,
        }),
    )
    .expect("usable");
    let refused: Vec<(usize, Class)> = judgement
        .findings
        .iter()
        .map(|f| (f.index, f.class))
        .collect();
    assert_eq!(
        refused,
        [5, 6, 7, 8].map(|i| (i, Class::UnknownFrame)),
        "a continuation on another connection, or of the other kind of subscription"
    );
}

#[test]
fn a_neg_open_must_open_with_the_empty_set_on_one_circle() {
    let w = world();
    let neg = |h: Vec<String>, initial: &str| json!(["NEG-OPEN", "sub-n", {"kinds": [445], "#h": h, "since": 1, "until": 2, "limit": 16384}, initial]);
    assert!(admitted(
        &w.table,
        w.loc_x,
        None,
        &neg(vec![hx()], "6100000200")
    ));
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &neg(vec![hx()], "6100000201")),
        Some(Class::UnknownFrame)
    );
    assert_eq!(
        class_of(
            &w.table,
            w.loc_x,
            None,
            &neg(vec![hx(), hy()], "6100000200")
        ),
        Some(Class::UnknownFrame)
    );
    let without_until = json!(["NEG-OPEN", "sub-n", {"kinds": [445], "#h": [hx()], "since": 1, "limit": 16384}, "6100000200"]);
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &without_until),
        Some(Class::UnknownFrame)
    );
}

#[test]
fn a_binding_key_absent_matches_no_row() {
    let w = world();
    for value in [
        json!(["EVENT", event(&id(51), &eph(13), 445, 1_000, &[])]),
        json!(["EVENT", event(&id(52), &eph(14), 1059, 1_000, &[])]),
        json!(["REQ", "sub-x", {"kinds": [445], "since": 1}]),
        json!(["REQ", "sub-x", {"kinds": [1059], "since": 1}]),
        json!(["REQ", "sub-x", {"kinds": [30443], "limit": 1}]),
        json!(["REQ", "sub-x", {"kinds": [1059], "#p": []}]),
        json!(["REQ", "sub-x", {"kinds": [1059], "#p": [alice(), bob()]}]),
        json!(["REQ", "sub-x", {"kinds": [0], "authors": [alice(), bob()]}]),
    ] {
        for relay in w.all() {
            let class = class_of(&w.table, relay, None, &value);
            assert_eq!(class, Some(Class::UnknownFrame));
        }
    }
}

#[test]
fn a_stray_tag_or_key_matches_no_row() {
    let w = world();
    let a = alice();
    for value in [
        json!([
            "EVENT",
            event(
                &id(53),
                &a,
                10050,
                1_000,
                &[&["relay", A_INBOX], &["client", "haven"]]
            )
        ]),
        json!([
            "EVENT",
            event(&id(54), &eph(15), 445, 1_000, &[&["h", &hx()], &["p", &a]])
        ]),
        json!([
            "EVENT",
            event(
                &id(55),
                &eph(16),
                445,
                1_000,
                &[&["h", &hx()], &["h", &hy()]]
            )
        ]),
        json!([
            "EVENT",
            event(&id(56), &a, 0, 1_000, &[&["alt", "profile"]])
        ]),
        json!(["REQ", "sub-x", {"kinds": [0], "authors": [bob()], "search": "x"}]),
        json!(["REQ", "sub-x", {"kinds": [445], "#h": [hx()], "#g": ["u4pr"]}]),
        json!(["REQ", "sub-x", {"kinds": [10050], "authors": [bob()], "until": 2}]),
    ] {
        for relay in w.all() {
            assert_eq!(
                class_of(&w.table, relay, None, &value),
                Some(Class::UnknownFrame)
            );
        }
    }
    let mut tags = kp_tags();
    tags.push(vec!["relays", B_INBOX]);
    let tags: Vec<&[&str]> = tags.iter().map(Vec::as_slice).collect();
    let kp = json!(["EVENT", event(&id(57), &a, 30443, 1_000, &tags)]);
    assert_eq!(
        class_of(&w.table, w.a_kp, None, &kp),
        Some(Class::UnknownFrame)
    );
}

#[test]
fn an_ephemeral_row_authored_by_an_identity_or_a_reused_key_is_wrong_author() {
    let w = world();
    let by_account = json!([
        "EVENT",
        event(&id(58), &alice(), 445, 1_000, &[&["h", &hx()]])
    ]);
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &by_account),
        Some(Class::WrongAuthor)
    );
    let wrap_by_invitee = json!([
        "EVENT",
        event(&id(59), &bob(), 1059, 1_000, &[&["p", &bob()]])
    ]);
    assert_eq!(
        class_of(&w.table, w.b_inbox, None, &wrap_by_invitee),
        Some(Class::WrongAuthor)
    );
    let frames = [
        frame(&json!([
            "EVENT",
            event(&id(30), &eph(17), 445, 1_000, &[&["h", &hx()]])
        ])),
        frame(&json!([
            "EVENT",
            event(&id(30), &eph(17), 445, 1_000, &[&["h", &hx()]])
        ])),
        frame(&json!([
            "EVENT",
            event(&id(31), &eph(17), 445, 1_001, &[&["h", &hx()]])
        ])),
    ];
    let judgement = judge(
        &w.table,
        frames.iter().map(|frame| Observed {
            relay: w.loc_x,
            conn: 0,
            sender: None,
            at: 1,
            frame,
        }),
    )
    .expect("usable");
    let refused: Vec<(usize, Class)> = judgement
        .findings
        .iter()
        .map(|f| (f.index, f.class))
        .collect();
    assert_eq!(
        refused,
        [(2, Class::WrongAuthor)],
        "a byte-identical resend is fine, a second event is not"
    );
    let foreign_kp = json!(["EVENT", kp_event(&id(32), &alice())]);
    assert_eq!(
        class_of(&w.table, w.a_kp, Some(&bob()), &foreign_kp),
        Some(Class::WrongAuthor)
    );
}

#[test]
fn a_relay_list_naming_a_relay_of_another_plane_is_a_finding() {
    let w = world();
    let a = alice();
    let list = |n, named: &str| {
        json!([
            "EVENT",
            event(
                &id(n),
                &a,
                10050,
                1_000,
                &[&["relay", A_INBOX], &["relay", named]]
            )
        ])
    };
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &list(60, LOC_X)),
        Some(Class::ListNamesForeignPlane)
    );
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &list(61, PROF)),
        Some(Class::ListNamesForeignPlane)
    );
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &list(62, DISC)),
        Some(Class::ListNamesForeignPlane)
    );
    assert!(
        admitted(&w.table, w.a_inbox, None, &list(63, A_KP)),
        "the account's other list"
    );
    assert!(admitted(
        &w.table,
        w.a_inbox,
        None,
        &list(64, "wss://elsewhere.example")
    ));
    let empty = json!(["EVENT", event(&id(33), &a, 10002, 1_000, &[])]);
    assert!(
        admitted(&w.table, w.a_kp, None, &empty),
        "the unpublish tombstone"
    );
}

#[test]
fn a_location_outside_its_retention_bound_is_unknown() {
    let w = world();
    for expiration in ["1000", "1229", "999", "never"] {
        let location = json!([
            "EVENT",
            event(
                &id(34),
                &eph(18),
                445,
                1_000,
                &[&["h", &hx()], &["expiration", expiration]]
            )
        ]);
        assert_eq!(
            class_of(&w.table, w.loc_x, None, &location),
            Some(Class::UnknownFrame)
        );
    }
}

#[test]
fn a_known_sender_must_be_a_member_of_the_circle() {
    let mut w = world();
    let req = json!(["REQ", "sub-h", {"kinds": [445], "#h": [hx()]}]);
    assert!(admitted(&w.table, w.loc_x, Some(&alice()), &req));
    assert_eq!(
        class_of(&w.table, w.loc_x, Some(&bob()), &req),
        Some(Class::CrossedRequest)
    );
    w.table.remove_member(&hx(), &alice(), 5);
    assert_eq!(
        class_of(&w.table, w.loc_x, Some(&alice()), &req),
        Some(Class::CrossedRequest),
        "after the leave"
    );
    let location = json!([
        "EVENT",
        event(
            &id(35),
            &eph(19),
            445,
            1_000,
            &[&["h", &hx()], &["expiration", "1100"]]
        )
    ]);
    assert_eq!(
        class_of(&w.table, w.loc_x, Some(&bob()), &location),
        Some(Class::CrossedEvent)
    );
}

#[test]
fn a_limit_beyond_its_row_is_unknown() {
    let w = world();
    for value in [
        json!(["REQ", "sub-p", {"kinds": [1059], "#p": [alice()], "limit": 1001}]),
        json!(["REQ", "sub-k", {"kinds": [30443], "authors": [bob()], "limit": 65}]),
        json!(["REQ", "sub-0", {"kinds": [0], "authors": [bob()], "limit": 5}]),
        json!(["NEG-OPEN", "sub-n", {"kinds": [445], "#h": [hx()], "since": 1, "until": 2, "limit": 16385}, "6100000200"]),
    ] {
        for relay in w.all() {
            assert_eq!(
                class_of(&w.table, relay, None, &value),
                Some(Class::UnknownFrame)
            );
        }
    }
}

/// R4: the relay-status page asks every own relay for all three own kinds.
#[test]
fn the_status_probe_shape_is_admitted_on_either_own_list_only() {
    let w = world();
    let a = alice();
    for kind in [30443, 10002, 10050] {
        let probe = json!(["REQ", "sub-s", {"kinds": [kind], "authors": [a], "limit": 5}]);
        let other = json!(["REQ", "sub-s", {"kinds": [kind], "authors": [a], "limit": 4}]);
        for sender in [None, Some(a.as_str())] {
            assert!(admitted(&w.table, w.a_inbox, sender, &probe));
            assert!(admitted(&w.table, w.a_kp, sender, &probe));
            assert!(class_of(&w.table, w.b_inbox, sender, &probe).is_some());
        }
        let wrong_list = if kind == 10050 { w.a_kp } else { w.a_inbox };
        assert_eq!(
            class_of(&w.table, wrong_list, Some(&a), &other),
            Some(Class::CrossedRequest)
        );
    }
    let self_on_discovery =
        json!(["REQ", "sub-k", {"kinds": [30443], "authors": [a], "limit": 10}]);
    assert_eq!(
        class_of(&w.table, w.disc, Some(&a), &self_on_discovery),
        Some(Class::CrossedRequest)
    );
}

#[test]
fn a_binding_with_no_list_or_no_routing_has_no_ground_truth() {
    let mut w = world();
    // Carol is an account with an inbox list and no key-package list.
    let c = carol();
    w.table.add(List::OwnInbox(&c), w.a_inbox, 0);
    let carol_kp = json!(["EVENT", kp_event(&id(40), &c)]);
    assert_eq!(
        class_of(&w.table, w.a_kp, None, &carol_kp),
        Some(Class::NoGroundTruth)
    );
    let carol_lookup = json!(["REQ", "sub-k", {"kinds": [30443], "authors": [c], "limit": 10}]);
    for sender in [None, Some(c.as_str())] {
        assert_eq!(
            class_of(&w.table, w.a_kp, sender, &carol_lookup),
            Some(Class::NoGroundTruth),
            "a key-package lookup for an account with no key-package list"
        );
    }
    let d = dave();
    let wrap = json!([
        "EVENT",
        event(&id(36), &eph(20), 1059, 1_000, &[&["p", &d]])
    ]);
    assert_eq!(
        class_of(&w.table, w.b_inbox, None, &wrap),
        Some(Class::NoGroundTruth)
    );
    let inbox = json!(["REQ", "sub-p", {"kinds": [1059], "#p": [d]}]);
    assert_eq!(
        class_of(&w.table, w.a_inbox, None, &inbox),
        Some(Class::NoGroundTruth)
    );
    let kp = json!(["EVENT", kp_event(&id(37), &d)]);
    assert_eq!(
        class_of(&w.table, w.a_kp, None, &kp),
        Some(Class::NoGroundTruth)
    );
    let lookup = json!(["REQ", "sub-k", {"kinds": [30443], "authors": [d], "limit": 10}]);
    assert!(
        admitted(&w.table, w.disc, None, &lookup),
        "discovery needs no list of the author"
    );
    assert_eq!(
        class_of(&w.table, w.b_write, None, &lookup),
        Some(Class::NoGroundTruth)
    );
    let undeclared = json!([
        "EVENT",
        event(&id(38), &eph(21), 445, 1_000, &[&["h", &hw()]])
    ]);
    assert_eq!(
        class_of(&w.table, w.loc_x, None, &undeclared),
        Some(Class::UndeclaredCircle)
    );
}

#[test]
fn a_finding_renders_no_value() {
    let w = world();
    let mut frames = Vec::new();
    for spec in &ROWS {
        let (value, _, _, _) = fixture(&w, spec.row);
        frames.push(frame(&value));
    }
    frames.push(frame(&json!(["CLOSE", "sub-never"])));
    frames.push(frame(&json!([
        "EVENT",
        event(&id(39), &eph(22), 1059, 1_000, &[&["p", &dave()]])
    ])));
    let judgement = judge(
        &w.table,
        frames.iter().map(|frame| Observed {
            relay: w.b_write,
            conn: 0,
            sender: Some("a1a1a1a1a1a1a1a1"),
            at: 7_788,
            frame,
        }),
    )
    .expect("usable");
    assert!(
        judgement.findings.len() > ROWS.len() / 2,
        "the plant produced findings"
    );
    let mut rendered = format!("{:?}", judgement.findings);
    for finding in &judgement.findings {
        let _ = write!(
            rendered,
            "{finding:?} {:?} {:?}",
            finding.relay, finding.row
        );
    }
    for key in judgement.hits.keys() {
        let _ = write!(rendered, "{key:?}");
    }
    assert_holds_no_value(&rendered, "a finding's Debug");
    for finding in &judgement.findings {
        assert_holds_no_value(finding.class.name(), "a class name");
    }
}

// ---------------------------------------------------------------------------
// The matrix's two other copies
// ---------------------------------------------------------------------------

fn repo_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(relative)
}

#[test]
fn the_exported_matrix_is_current() {
    let out = Path::new(env!("CARGO_TARGET_TMPDIR")).join("relay_planes.export.json");
    let args = vec!["--export".to_owned(), out.display().to_string()];
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    assert_eq!(cli::run(&args, &mut stdout, &mut stderr), RC_CLEAN);
    let exported = std::fs::read(&out).expect("the export was written");
    let committed =
        std::fs::read(repo_path("../relay_planes.json")).expect("tooling/e2e/relay_planes.json");
    assert!(
        exported == committed,
        "tooling/e2e/relay_planes.json is stale: regenerate it with \
         `cargo run --bin haven-wire-planes -- --export ../relay_planes.json` (never hand-edit)"
    );
    let parsed: Value = serde_json::from_slice(&exported).expect("the export is JSON");
    assert_eq!(parsed["version"], 1);
    let location_kinds = parsed["roles"]["location"]["events"]
        .as_array()
        .expect("events");
    assert_eq!(location_kinds, &[json!(445)]);
    assert_eq!(parsed["roles"]["discovery"]["events"], json!([]));
}

#[test]
fn the_documented_matrix_is_the_policy() {
    let doc = std::fs::read_to_string(repo_path("../../../haven-core/SECURITY.md"))
        .expect("haven-core/SECURITY.md");
    let heading = "### The relay-plane allow matrix";
    let at = doc
        .find(heading)
        .expect("SECURITY.md has the matrix heading");
    let mut table = String::new();
    for line in doc[at..]
        .lines()
        .skip_while(|line| !line.starts_with('|'))
        .take_while(|line| line.starts_with('|'))
    {
        table.push_str(line);
        table.push('\n');
    }
    let rendered = render_markdown();
    if table != rendered {
        let out = Path::new(env!("CARGO_TARGET_TMPDIR")).join("relay_plane_matrix.md");
        let _ = std::fs::write(&out, &rendered);
        panic!(
            "the allow matrix in haven-core/SECURITY.md is not ROWS: the rendered table is at {}",
            out.display()
        );
    }
}

// ---------------------------------------------------------------------------
// The CLI (oracle C8), one journal per case
// ---------------------------------------------------------------------------

const RELAY_URL: &str = "ws://127.0.0.1:7777";
const HARNESS: &str = "harness-sock";
const APP_INBOX: &str = "app-inbox";
const APP_LOC: &str = "app-loc";
const APP_LOC_Y: &str = "app-loc-y";
const APP_DISC: &str = "app-disc";

#[derive(Default)]
struct J {
    lines: Vec<Value>,
}

impl J {
    fn push(&mut self, mut line: Value) {
        line["wire_seq"] = json!(self.lines.len());
        self.lines.push(line);
    }

    fn frame(&mut self, conn: &str, dir: &str, listen: &str, frame: Value) {
        let mut line = json!({
            "type": "frame", "conn_id": conn, "ts_ms": 1, "dir": dir,
            "relay_url": RELAY_URL, "listen": listen, "raw_len": 1,
        });
        line["frame"] = frame;
        self.push(line);
    }

    fn c2r(&mut self, conn: &str, port: u16, frame: Value) {
        self.frame(conn, "c2r", &format!("127.0.0.1:{port}"), frame);
    }

    fn r2c(&mut self, conn: &str, port: u16, frame: Value) {
        self.frame(conn, "r2c", &format!("127.0.0.1:{port}"), frame);
    }

    fn open(&mut self, conn: &str, port: u16) {
        self.push(json!({
            "type": "conn_open", "conn_id": conn, "ts_ms": 1,
            "relay_url": RELAY_URL, "listen": format!("127.0.0.1:{port}"),
        }));
    }

    fn routing(&mut self, n: u32, h: &str, ports: &[u16]) {
        let relays: Vec<String> = ports.iter().map(|p| format!("ws://10.0.2.2:{p}")).collect();
        self.c2r(
            HARNESS,
            7788,
            json!(["HAVEN_WIRE_SENTINEL", format!("HAVEN_WIRE_ROUTING:{n}"), {"h": h, "relays": relays}]),
        );
    }

    fn sentinel(&mut self) {
        self.c2r(HARNESS, 7788, json!(["HAVEN_WIRE_SENTINEL", TOKEN]));
    }

    fn text(&self) -> String {
        let mut text = String::new();
        for line in &self.lines {
            text.push_str(&line.to_string());
            text.push('\n');
        }
        text
    }
}

fn list_event(n: u32, author: &str, kind: u16, created_at: u64, entries: &[&[&str]]) -> Value {
    let tag = if kind == 10050 { "relay" } else { "r" };
    let tags: Vec<Vec<String>> = entries
        .iter()
        .map(|entry| {
            let mut tag_parts = vec![tag.to_owned(), format!("ws://10.0.2.2:{}", entry[0])];
            tag_parts.extend(entry[1..].iter().map(|s| (*s).to_owned()));
            tag_parts
        })
        .collect();
    json!(["EVENT", {
        "id": id(n), "pubkey": author, "kind": kind, "created_at": created_at,
        "tags": tags, "content": "", "sig": "00",
    }])
}

fn location(n: u32, author: u32, h: &str) -> Value {
    json!([
        "EVENT",
        event(
            &id(n),
            &eph(author),
            445,
            1_000,
            &[&["h", h], &["expiration", "1228"]]
        )
    ])
}

fn commit(n: u32, author: u32, h: &str) -> Value {
    json!([
        "EVENT",
        event(&id(n), &eph(author), 445, 1_000, &[&["h", h]])
    ])
}

/// The healthy lane, or one with a role's witness left out, its discovery
/// read on another listen or its first circle undeclared.
struct Lane {
    without: Option<Role>,
    discovery_port: u16,
    declare_x: bool,
}

const FULL: Lane = Lane {
    without: None,
    discovery_port: 7790,
    declare_x: true,
};

/// The healthy multi-plane journal: harness routings and lists, then the app
/// on each plane. `before_lists` runs before the harness's lists, `before_sentinel` before the
/// sentinel.
fn journal(
    lane: &Lane,
    before_lists: impl FnOnce(&mut J),
    before_sentinel: impl FnOnce(&mut J),
) -> J {
    let has = |role| lane.without != Some(role);
    let (a, b, c) = (alice(), bob(), carol());
    let mut j = J::default();
    j.open(HARNESS, 7788);
    j.c2r(
        HARNESS,
        7788,
        json!(["HAVEN_WIRE_SENTINEL", "HAVEN_WIRE_CONN"]),
    );
    if lane.declare_x {
        j.routing(1, &hx(), &[7789]);
    }
    j.routing(2, &hy(), &[7793]);
    before_lists(&mut j);
    j.c2r(HARNESS, 7788, list_event(1, &b, 10050, 200, &[&["7788"]]));
    j.c2r(
        HARNESS,
        7788,
        list_event(2, &b, 10002, 200, &[&["7788"], &["7792", "read"]]),
    );
    j.c2r(HARNESS, 7788, list_event(3, &c, 10050, 200, &[&["7791"]]));
    j.c2r(HARNESS, 7788, list_event(4, &c, 10002, 200, &[&["7792"]]));
    j.open(APP_INBOX, 7788);
    j.c2r(APP_INBOX, 7788, list_event(5, &a, 10050, 200, &[&["7788"]]));
    j.c2r(APP_INBOX, 7788, list_event(6, &a, 10002, 200, &[&["7788"]]));
    if has(Role::KeyPackage) {
        j.c2r(APP_INBOX, 7788, json!(["EVENT", kp_event(&id(7), &a)]));
    }
    if has(Role::Inbox) {
        j.c2r(
            APP_INBOX,
            7788,
            json!(["REQ", "sub-inbox", {"kinds": [1059], "#p": [a], "since": 1}]),
        );
        j.c2r(
            APP_INBOX,
            7788,
            json!(["EVENT", event(&id(8), &eph(1), 1059, 1_000, &[&["p", &b]])]),
        );
    }
    j.c2r(
        APP_INBOX,
        7788,
        json!(["REQ", "sub-kp", {"kinds": [30443], "authors": [b], "limit": 10}]),
    );
    if has(Role::Discovery) {
        let port = lane.discovery_port;
        j.open(APP_DISC, port);
        j.c2r(
            APP_DISC,
            port,
            json!(["REQ", "sub-disc", {"kinds": [10050], "authors": [c], "limit": 1}]),
        );
    }
    j.open(APP_LOC, 7789);
    if has(Role::Location) {
        j.c2r(APP_LOC, 7789, location(9, 2, &hx()));
        j.c2r(APP_LOC, 7789, commit(10, 3, &hx()));
    }
    j.c2r(
        APP_LOC,
        7789,
        json!(["REQ", "sub-h", {"kinds": [445], "#h": [hx()], "since": 1}]),
    );
    j.c2r(
        APP_LOC,
        7789,
        json!(["NEG-OPEN", "sub-neg", {"kinds": [445], "#h": [hx()], "since": 1, "until": 2, "limit": 16384}, "6100000200"]),
    );
    j.c2r(APP_LOC, 7789, json!(["NEG-MSG", "sub-neg", "6100000200"]));
    j.c2r(APP_LOC, 7789, json!(["NEG-CLOSE", "sub-neg"]));
    j.c2r(APP_LOC, 7789, json!(["CLOSE", "sub-h"]));
    j.open(APP_LOC_Y, 7793);
    if has(Role::Location) {
        j.c2r(APP_LOC_Y, 7793, location(11, 4, &hy()));
    }
    before_sentinel(&mut j);
    j.sentinel();
    j
}

fn healthy(before_sentinel: impl FnOnce(&mut J)) -> J {
    journal(&FULL, |_| {}, before_sentinel)
}

const PLANES: &[&str] = &[
    "inbox=127.0.0.1:7788",
    "keypackage=127.0.0.1:7788",
    "location=127.0.0.1:7789",
    "discovery=127.0.0.1:7790",
    "inbox=127.0.0.1:7791",
    "keypackage=127.0.0.1:7792",
    "location=127.0.0.1:7793",
];

/// What a case hands the CLI.
enum Input {
    /// A journal written to a file, with the lane's `--plane` list and these
    /// extra arguments.
    Journal(String, Vec<String>),
    /// The healthy journal with the lane's arguments and these extra ones.
    Extra(Vec<String>),
    /// These arguments alone.
    Bare(Vec<String>),
    /// The healthy lane's arguments against a path that does not exist.
    Absent,
}

struct Case {
    name: &'static str,
    input: Input,
    rc: i32,
    says: &'static [&'static str],
}

fn extra(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| (*s).to_owned()).collect()
}

fn case(name: &'static str, j: &J, more: &[&str], rc: i32, says: &'static [&'static str]) -> Case {
    Case {
        name,
        input: Input::Journal(j.text(), extra(more)),
        rc,
        says,
    }
}

fn raw(name: &'static str, args: &[&str], rc: i32, says: &'static [&'static str]) -> Case {
    Case {
        name,
        input: Input::Extra(extra(args)),
        rc,
        says,
    }
}

fn bare(name: &'static str, args: &[&str], rc: i32, says: &'static [&'static str]) -> Case {
    Case {
        name,
        input: Input::Bare(extra(args)),
        rc,
        says,
    }
}

/// A named fixture and the lines it plants before the sentinel.
type Plant = (&'static str, Box<dyn FnOnce(&mut J)>);

const C81: &[&str] = &["C8.1 VIOLATION"];
const C82: &[&str] = &["C8.2 VIOLATION"];
const C83: &[&str] = &["C8.3 VIOLATION"];
const NONE: &[&str] = &[];

#[allow(clippy::too_many_lines)]
fn cases() -> Vec<Case> {
    let (a, b) = (alice(), bob());
    let mut cases = vec![
        // Positive controls.
        case(
            "P1 a healthy multi-plane journal",
            &healthy(|_| {}),
            &[],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
        case(
            "P2 a declared profile listen takes kind 0 and its lookup",
            &healthy(|j| {
                j.c2r(
                    APP_INBOX,
                    7794,
                    json!(["EVENT", event(&id(20), &alice(), 0, 1_000, &[])]),
                );
                j.c2r(
                    APP_INBOX,
                    7794,
                    json!(["REQ", "sub-prof", {"kinds": [0], "authors": [bob()], "limit": 4}]),
                );
            }),
            &["--plane", "profile=127.0.0.1:7794"],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
        case(
            "P3 a Welcome to a relay only an earlier inbox list named (frozen targets)",
            &journal(
                &FULL,
                |j| {
                    j.c2r(
                        HARNESS,
                        7788,
                        list_event(21, &bob(), 10050, 100, &[&["7791"]]),
                    );
                    j.c2r(
                        HARNESS,
                        7788,
                        list_event(22, &bob(), 10050, 300, &[&["7788"]]),
                    );
                },
                |j| {
                    j.c2r(
                        APP_INBOX,
                        7791,
                        json!([
                            "EVENT",
                            event(&id(23), &eph(5), 1059, 1_000, &[&["p", &bob()]])
                        ]),
                    );
                },
            ),
            &[],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
        case(
            "P4 the lanes' shape: discovery on the inbox listen, the overlaps declared",
            &journal(
                &Lane {
                    discovery_port: 7788,
                    ..FULL
                },
                |_| {},
                |_| {},
            ),
            &[
                "--plane",
                "discovery=127.0.0.1:7788",
                "--declare-overlap",
                "inbox:discovery",
                "--declare-overlap",
                "keypackage:discovery",
            ],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
    ];
    // C8.1 — EVENT placement.
    let c81: [Plant; 15] = [
        (
            "C8.1 a 445 on the inbox listen",
            Box::new(|j: &mut J| j.c2r(APP_INBOX, 7788, commit(30, 6, &hx()))),
        ),
        (
            "C8.1 a 445 on the other circle's listen",
            Box::new(|j: &mut J| j.c2r(APP_LOC_Y, 7793, commit(31, 7, &hx()))),
        ),
        (
            "C8.1 one 445 body fanned out to its routing and the inbox",
            Box::new(|j: &mut J| j.c2r(APP_INBOX, 7788, location(9, 2, &hx()))),
        ),
        (
            "C8.1 a 1059 on a location listen",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_LOC,
                    7789,
                    json!([
                        "EVENT",
                        event(&id(32), &eph(8), 1059, 1_000, &[&["p", &bob()]])
                    ]),
                );
            }),
        ),
        (
            "C8.1 a 1059 on an inbox the recipient never named",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_INBOX,
                    7791,
                    json!([
                        "EVENT",
                        event(&id(33), &eph(9), 1059, 1_000, &[&["p", &bob()]])
                    ]),
                );
            }),
        ),
        (
            "C8.1 a 30443 outside the author's key-package list",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_INBOX,
                    7792,
                    json!(["EVENT", kp_event(&id(7), &alice())]),
                );
            }),
        ),
        (
            "C8.1 a 30443 on a location listen",
            Box::new(|j: &mut J| {
                j.c2r(APP_LOC, 7789, json!(["EVENT", kp_event(&id(7), &alice())]));
            }),
        ),
        (
            "C8.1 a 10050 on a key-package-only listen",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_INBOX,
                    7792,
                    list_event(5, &alice(), 10050, 200, &[&["7788"]]),
                );
            }),
        ),
        (
            "C8.1 a 10002 naming one listen sent to another",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_INBOX,
                    7792,
                    list_event(6, &alice(), 10002, 200, &[&["7788"]]),
                );
            }),
        ),
        (
            "C8.1 a 10050 on discovery",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_DISC,
                    7790,
                    list_event(5, &alice(), 10050, 200, &[&["7788"]]),
                );
            }),
        ),
        (
            "C8.1 a kind 0 with no profile listen declared",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_INBOX,
                    7788,
                    json!(["EVENT", event(&id(34), &alice(), 0, 1_000, &[])]),
                );
            }),
        ),
        (
            "C8.1 a kind 5 on discovery",
            Box::new(|j: &mut J| {
                let a = alice();
                j.c2r(
                    APP_DISC,
                    7790,
                    json!([
                        "EVENT",
                        event(
                            &id(35),
                            &a,
                            5,
                            1_000,
                            &[&["k", "10050"], &["a", &format!("10050:{a}:")]]
                        )
                    ]),
                );
            }),
        ),
        (
            "C8.1 a relay list naming a location listen",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_INBOX,
                    7788,
                    list_event(36, &alice(), 10050, 250, &[&["7788"], &["7789"]]),
                );
            }),
        ),
        (
            "C8.1 a 445 authored by an account",
            Box::new(|j: &mut J| {
                j.c2r(
                    APP_LOC,
                    7789,
                    json!([
                        "EVENT",
                        event(&id(37), &alice(), 445, 1_000, &[&["h", &hx()]])
                    ]),
                );
            }),
        ),
        (
            "C8.1 an ephemeral key used for a second 445",
            Box::new(|j: &mut J| j.c2r(APP_LOC, 7789, commit(38, 2, &hx()))),
        ),
    ];
    for (name, late) in c81 {
        cases.push(case(name, &healthy(late), &[], RC_VIOLATION, C81));
    }
    // C8.2 — REQ placement (and every other non-EVENT, non-NEG frame).
    let c82: [(&'static str, u16, &'static str, Value); 12] = [
        (
            "C8.2 an inbox REQ on a location listen",
            7789,
            APP_LOC,
            json!(["REQ", "sub-x", {"kinds": [1059], "#p": [a]}]),
        ),
        (
            "C8.2 an inbox REQ on a listen the recipient's list does not name",
            7791,
            APP_INBOX,
            json!(["REQ", "sub-x", {"kinds": [1059], "#p": [b]}]),
        ),
        (
            "C8.2 an #h REQ on the inbox listen",
            7788,
            APP_INBOX,
            json!(["REQ", "sub-x", {"kinds": [445], "#h": [hx()]}]),
        ),
        (
            "C8.2 an #h REQ on the other circle's listen",
            7793,
            APP_LOC_Y,
            json!(["REQ", "sub-x", {"kinds": [445], "#h": [hx()]}]),
        ),
        (
            "C8.2 one #h REQ for two circles on one circle's listen",
            7789,
            APP_LOC,
            json!(["REQ", "sub-x", {"kinds": [445], "#h": [hx(), hy()]}]),
        ),
        (
            "C8.2 a kind-0 REQ with no profile listen declared",
            7788,
            APP_INBOX,
            json!(["REQ", "sub-x", {"kinds": [0], "authors": [b], "limit": 4}]),
        ),
        (
            "C8.2 a key-package lookup on a read-only entry of the author's list",
            7792,
            APP_INBOX,
            json!(["REQ", "sub-x", {"kinds": [30443], "authors": [b], "limit": 10}]),
        ),
        (
            "C8.2 a REQ with no kinds",
            7788,
            APP_INBOX,
            json!(["REQ", "sub-x", {"authors": [b]}]),
        ),
        (
            "C8.2 a kind-445 REQ on discovery",
            7790,
            APP_DISC,
            json!(["REQ", "sub-x", {"kinds": [445], "#h": [hx()]}]),
        ),
        (
            "C8.2 a by-id 445 REQ on the inbox listen",
            7788,
            APP_INBOX,
            json!(["REQ", "sub-x", {"ids": [id(9)], "kinds": [445], "limit": 1}]),
        ),
        (
            "C8.2 a COUNT",
            7789,
            APP_LOC,
            json!(["COUNT", "sub-x", {"kinds": [445]}]),
        ),
        (
            "C8.2 a CLOSE naming another connection's subscription",
            7790,
            APP_DISC,
            json!(["CLOSE", "sub-h"]),
        ),
    ];
    for (name, port, conn, frame) in c82 {
        cases.push(case(
            name,
            &healthy(|j| j.c2r(conn, port, frame)),
            &[],
            RC_VIOLATION,
            C82,
        ));
    }
    // C8.3 — NEG-OPEN placement.
    let neg = |h: String, initial: &str| json!(["NEG-OPEN", "sub-y", {"kinds": [445], "#h": [h], "since": 1, "until": 2, "limit": 16384}, initial]);
    for (name, port, conn, frame) in [
        (
            "C8.3 a NEG-OPEN on the inbox listen",
            7788,
            APP_INBOX,
            neg(hx(), "6100000200"),
        ),
        (
            "C8.3 a NEG-OPEN on the other circle's listen",
            7793,
            APP_LOC_Y,
            neg(hx(), "6100000200"),
        ),
        (
            "C8.3 a NEG-OPEN advertising a holding",
            7789,
            APP_LOC,
            neg(hx(), "61000002ff"),
        ),
    ] {
        cases.push(case(
            name,
            &healthy(|j| j.c2r(conn, port, frame)),
            &[],
            RC_VIOLATION,
            C83,
        ));
    }
    // C8.4 / C8.5 — routings and circles.
    cases.extend([
        case(
            "C8.4 a circle routed to the inbox listen",
            &healthy(|j| j.routing(3, &hz(), &[7788])),
            &[],
            RC_VIOLATION,
            &["C8.4 VIOLATION", "declared circle #3"],
        ),
        case(
            "C8.4 a circle routed to a port no listen declares",
            &healthy(|j| j.routing(3, &hz(), &[7799])),
            &[],
            RC_META_FLOOR,
            &["C8.4 META-FLOOR"],
        ),
        case(
            "C8.4 a malformed routing declaration",
            &healthy(|j| j.routing(3, &hz().to_uppercase(), &[7789])),
            &[],
            RC_UNUSABLE,
            NONE,
        ),
        case(
            "C8.5 a 445 for a circle never declared",
            &healthy(|j| j.c2r(APP_LOC, 7789, commit(40, 10, &hw()))),
            &[],
            RC_META_FLOOR,
            &["C8.5 META-FLOOR"],
        ),
    ]);
    let mut above = journal(
        &Lane {
            declare_x: false,
            ..FULL
        },
        |_| {},
        |_| {},
    );
    above.routing(1, &hx(), &[7789]);
    cases.push(case(
        "C8.5 a circle declared only above the sentinel",
        &above,
        &[],
        RC_META_FLOOR,
        &["C8.5 META-FLOOR"],
    ));
    // C8.6 — binding ground truth.
    for (name, port, conn, frame) in [
        (
            "C8.6 a 1059 to a recipient with no inbox list",
            7788,
            APP_INBOX,
            json!([
                "EVENT",
                event(&id(41), &eph(11), 1059, 1_000, &[&["p", &dave()]])
            ]),
        ),
        (
            "C8.6 a 30443 by an author with no list",
            7788,
            APP_INBOX,
            json!(["EVENT", kp_event(&id(42), &dave())]),
        ),
        (
            "C8.6 an inbox REQ for a pubkey with no inbox list",
            7788,
            APP_INBOX,
            json!(["REQ", "sub-x", {"kinds": [1059], "#p": [dave()]}]),
        ),
        (
            "C8.6 a by-id REQ for an id the journal never carried",
            7789,
            APP_LOC,
            json!(["REQ", "sub-x", {"ids": [id(63)], "kinds": [445], "limit": 1}]),
        ),
    ] {
        cases.push(case(
            name,
            &healthy(|j| j.c2r(conn, port, frame)),
            &[],
            RC_META_FLOOR,
            &["C8.6 META-FLOOR"],
        ));
    }
    // C8.7 — vacuity.
    for (name, lane, says) in [
        (
            "C8.7 no location witness",
            Lane {
                without: Some(Role::Location),
                ..FULL
            },
            &["C8.7 META-FLOOR: the declared role location"][..],
        ),
        (
            "C8.7 no inbox witness",
            Lane {
                without: Some(Role::Inbox),
                ..FULL
            },
            &["C8.7 META-FLOOR: the declared role inbox"][..],
        ),
        (
            "C8.7 no key-package witness",
            Lane {
                without: Some(Role::KeyPackage),
                ..FULL
            },
            &["C8.7 META-FLOOR: the declared role keypackage"][..],
        ),
        (
            "C8.7 no discovery witness",
            Lane {
                without: Some(Role::Discovery),
                ..FULL
            },
            &["C8.7 META-FLOOR: the declared role discovery"][..],
        ),
    ] {
        cases.push(Case {
            name,
            input: Input::Journal(journal(&lane, |_| {}, |_| {}).text(), Vec::new()),
            rc: RC_META_FLOOR,
            says,
        });
    }
    let mut only_harness = J::default();
    only_harness.c2r(
        HARNESS,
        7788,
        json!(["HAVEN_WIRE_SENTINEL", "HAVEN_WIRE_CONN"]),
    );
    only_harness.sentinel();
    cases.push(case(
        "C8.7 a snapshot holding only the harness",
        &only_harness,
        &[],
        RC_META_FLOOR,
        NONE,
    ));
    // C8.8 — listens.
    cases.extend([
        case(
            "C8.8 traffic on a listen no --plane declares",
            &healthy(|j| {
                j.c2r(
                    APP_INBOX,
                    7795,
                    json!(["REQ", "sub-x", {"kinds": [1059], "#p": [alice()]}]),
                );
            }),
            &[],
            RC_META_FLOOR,
            &["C8.8 META-FLOOR"],
        ),
        case(
            "C8.8 a line with no listen and no conn_open, never read off relay_url",
            &healthy(|j| {
                j.frame(
                    "app-orphan",
                    "c2r",
                    "",
                    json!(["REQ", "sub-x", {"kinds": [1059], "#p": [alice()]}]),
                );
            }),
            &[],
            RC_META_FLOOR,
            &["C8.8 META-FLOOR"],
        ),
        case(
            "C8.8 a line with no listen takes its connection's conn_open",
            &healthy(|j| {
                j.open("app-late", 7788);
                j.frame(
                    "app-late",
                    "c2r",
                    "",
                    json!(["REQ", "sub-x", {"kinds": [1059], "#p": [alice()]}]),
                );
            }),
            &[],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
    ]);
    cases.push(raw(
        "C8.8 two --plane listens sharing a port",
        &["--plane", "location=127.0.0.2:7789"],
        RC_USAGE,
        NONE,
    ));
    // Exclusion, direction, anchoring.
    cases.extend([
        case(
            "a harness socket's 445 on the inbox listen is not the app's",
            &healthy(|j| j.c2r(HARNESS, 7788, commit(43, 12, &hx()))),
            &[],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
        case(
            "an excluded connection's 445 on the inbox listen is not the app's",
            &healthy(|j| j.c2r("probe-sock", 7788, commit(44, 13, &hx()))),
            &["--exclude-conn", "probe-sock"],
            RC_CLEAN,
            &["C8.1-C8.8 hold"],
        ),
        case(
            "the same connection without --exclude-conn is judged",
            &healthy(|j| j.c2r("probe-sock", 7788, commit(44, 13, &hx()))),
            &[],
            RC_VIOLATION,
            C81,
        ),
        case(
            "an inbound 445 on the inbox listen is advisory only",
            &healthy(|j| {
                j.r2c(
                    APP_INBOX,
                    7788,
                    json!([
                        "EVENT",
                        "sub-inbox",
                        event(&id(45), &eph(14), 445, 1_000, &[&["h", &hx()]])
                    ]),
                );
            }),
            &[],
            RC_CLEAN,
            &[
                "advisory: inbound kinds seen on listens carrying inbox: [445]",
                "C8.1-C8.8 hold",
            ],
        ),
    ]);
    let mut beyond = healthy(|_| {});
    beyond.c2r(APP_INBOX, 7788, commit(46, 15, &hx()));
    cases.push(case(
        "a violation above the sentinel is outside the snapshot",
        &beyond,
        &[],
        RC_CLEAN,
        &["C8.1-C8.8 hold"],
    ));
    let mut unanchored = healthy(|j| {
        j.c2r(APP_INBOX, 7788, json!(["EVENT", {"id": id(47), "pubkey": eph(16), "kind": 1059, "created_at": 1, "tags": [["p", bob()]], "content": TOKEN, "sig": "00"}]));
    });
    unanchored.lines.pop();
    cases.push(case(
        "the token only inside event content anchors nothing",
        &unanchored,
        &[],
        RC_META_FLOOR,
        &["never as a sentinel marker frame"],
    ));
    // Usability and usage.
    let mut gapped = healthy(|_| {});
    gapped.lines[3]["wire_seq"] = json!(99);
    let mut lifecycle_frame = healthy(|_| {});
    lifecycle_frame.lines[0]["frame"] = json!(["REQ", "sub-x", {"kinds": [3]}]);
    cases.extend([
        Case {
            name: "an absent journal",
            input: Input::Absent,
            rc: RC_UNUSABLE,
            says: NONE,
        },
        Case {
            name: "an empty journal",
            input: Input::Journal(String::new(), Vec::new()),
            rc: RC_UNUSABLE,
            says: NONE,
        },
        Case {
            name: "a line that is not JSON",
            input: Input::Journal(
                format!("{}{{\"wire_seq\":\n", healthy(|_| {}).text()),
                Vec::new(),
            ),
            rc: RC_UNUSABLE,
            says: NONE,
        },
        case("a wire_seq gap", &gapped, &[], RC_UNUSABLE, NONE),
        case(
            "a lifecycle record carrying a frame",
            &lifecycle_frame,
            &[],
            RC_UNUSABLE,
            NONE,
        ),
        bare(
            "no --plane",
            &["--journal", "{journal}", "--sentinel", TOKEN],
            RC_USAGE,
            NONE,
        ),
        raw(
            "an unknown role",
            &["--plane", "relay=127.0.0.1:7796"],
            RC_USAGE,
            NONE,
        ),
        raw(
            "a listen with a scheme",
            &["--plane", "inbox=ws://127.0.0.1:7796"],
            RC_USAGE,
            NONE,
        ),
        raw(
            "a listen naming a host",
            &["--plane", "inbox=localhost:7796"],
            RC_USAGE,
            NONE,
        ),
        bare(
            "no --sentinel",
            &["--journal", "{journal}", "--plane", "inbox=127.0.0.1:7788"],
            RC_USAGE,
            NONE,
        ),
        raw(
            "one role and listen declared twice",
            &["--plane", "inbox=127.0.0.1:7788"],
            RC_USAGE,
            NONE,
        ),
        raw("two journals", &["--journal", "{journal}"], RC_USAGE, NONE),
        raw(
            "a profile overlap declared",
            &["--declare-overlap", "profile:inbox"],
            RC_USAGE,
            NONE,
        ),
        raw(
            "an overlap that needs no declaration",
            &["--declare-overlap", "inbox:keypackage"],
            RC_USAGE,
            NONE,
        ),
        raw("an unknown flag", &["--verbose", "1"], RC_USAGE, NONE),
        raw(
            "--export beside a judgement",
            &["--export", "{journal}.out"],
            RC_USAGE,
            NONE,
        ),
        case(
            "two roles on one listen with no declaration",
            &healthy(|_| {}),
            &["--plane", "location=127.0.0.1:7788"],
            RC_UNUSABLE,
            NONE,
        ),
        case(
            "the profile role sharing a listen",
            &healthy(|_| {}),
            &["--plane", "profile=127.0.0.1:7788"],
            RC_UNUSABLE,
            NONE,
        ),
        case(
            "the location role sharing a listen with discovery",
            &healthy(|_| {}),
            &["--plane", "discovery=127.0.0.1:7789"],
            RC_UNUSABLE,
            NONE,
        ),
        raw(
            "a location and discovery overlap declared",
            &["--declare-overlap", "location:discovery"],
            RC_USAGE,
            NONE,
        ),
        case(
            "C8.6 a 30443 by an account with an inbox list and no key-package list",
            &journal(
                &FULL,
                |j| {
                    j.c2r(
                        HARNESS,
                        7788,
                        list_event(48, &dave(), 10050, 200, &[&["7788"]]),
                    );
                },
                |j| {
                    j.c2r(
                        APP_INBOX,
                        7788,
                        json!(["EVENT", kp_event(&id(49), &dave())]),
                    );
                },
            ),
            &[],
            RC_META_FLOOR,
            &["C8.6 META-FLOOR"],
        ),
    ]);
    cases
}

/// The lane's own arguments around `extra`.
fn lane_args(journal: &Path, extra: &[String]) -> Vec<String> {
    let mut args = vec![
        "--journal".to_owned(),
        journal.display().to_string(),
        "--sentinel".to_owned(),
        TOKEN.to_owned(),
    ];
    for plane in PLANES {
        args.push("--plane".to_owned());
        args.push((*plane).to_owned());
    }
    args.extend(extra.iter().cloned());
    args
}

/// The number of C8 fixtures. Moving it is the only way to add or remove one.
const CLI_CASES: usize = 79;

#[test]
fn the_c8_fixture_suite() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("wire-planes-cases");
    std::fs::create_dir_all(&dir).expect("a temp dir");
    let healthy_path = dir.join("healthy.ndjson");
    std::fs::write(&healthy_path, healthy(|_| {}).text()).expect("write");
    let cases = cases();
    let mut failed = Vec::new();
    for (n, case) in cases.iter().enumerate() {
        let args = match &case.input {
            Input::Journal(text, more) => {
                let path = dir.join(format!("case-{n}.ndjson"));
                std::fs::write(&path, text).expect("write");
                lane_args(&path, more)
            }
            Input::Bare(args) => args.clone(),
            Input::Extra(more) => lane_args(&healthy_path, more),
            Input::Absent => lane_args(&dir.join("never-written.ndjson"), &[]),
        };
        let args: Vec<String> = args
            .into_iter()
            .map(|a| a.replace("{journal}", &healthy_path.display().to_string()))
            .collect();
        let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
        let rc = cli::run(&args, &mut stdout, &mut stderr);
        let stdout = String::from_utf8(stdout).expect("utf-8");
        let stderr = String::from_utf8(stderr).expect("utf-8");
        let output = format!("{stdout}{stderr}");
        assert_holds_no_value(&output, case.name);
        let banner = stdout.contains("C8.1-C8.8 hold");
        let ok = rc == case.rc
            && case.says.iter().all(|s| output.contains(s))
            && (banner == (rc == RC_CLEAN));
        if !ok {
            failed.push(format!("{} (want rc {}, got rc {rc})", case.name, case.rc));
        }
    }
    assert!(failed.is_empty(), "C8 fixtures failed: {failed:#?}");
    assert_eq!(
        cases.len(),
        CLI_CASES,
        "a C8 fixture was added or removed without moving the pin"
    );
}
