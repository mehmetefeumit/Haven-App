//! The relay-plane allow matrix: what each relay role may receive from Haven.
//!
//! [`ROWS`] is the normative policy. Every layer of the relay-plane proof —
//! haven-core's and `rust_builder`'s tests, the soak rig, the E2E journal
//! consumer — reads it through one [`super::judge::judge`], so there is no
//! second interpretation to drift. The
//! table in `haven-core/SECURITY.md` ("The relay-plane allow matrix") is
//! [`render_markdown`] verbatim and `tooling/e2e/relay_planes.json` is
//! [`export_json`] verbatim; a test pins each.
//!
//! A row is a SHAPE (verb, kinds, exact tag or key set, author class) plus the
//! binding that decides which relays may receive it. A frame no row's shape
//! admits is unknown; a frame a row's shape admits on a relay its binding does
//! not is a crossing.

use std::fmt::Write as _;

/// One row of the matrix.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Row {
    /// A kind-445 commit or proposal.
    Ev445Commit,
    /// A kind-445 application message (a location).
    Ev445Location,
    /// A kind-1059 gift wrap (a Welcome).
    Ev1059,
    /// A kind-30443 key package.
    Ev30443,
    /// A kind-10002 relay list (the key-package list).
    Ev10002,
    /// A kind-10050 relay list (the inbox list).
    Ev10050,
    /// A kind-0 profile.
    Ev0,
    /// A kind-5 retraction.
    Ev5,
    /// A `#h` REQ for kind 445.
    Req445H,
    /// A by-id REQ for kind 445.
    Req445Ids,
    /// The inbox REQ: kind 1059 by `#p`.
    Req1059P,
    /// A key-package lookup by author.
    Req30443A,
    /// A key-package-list lookup by author.
    Req10002A,
    /// An inbox-list lookup by author.
    Req10050A,
    /// A profile lookup by author.
    Req0A,
    /// A NIP-77 NEG-OPEN over one circle's kind 445.
    Neg445H,
}

impl Row {
    /// The row id the matrix, SECURITY.md and every judge report use.
    #[must_use]
    pub const fn id(self) -> &'static str {
        match self {
            Self::Ev445Commit => "EV-445C",
            Self::Ev445Location => "EV-445A",
            Self::Ev1059 => "EV-1059",
            Self::Ev30443 => "EV-30443",
            Self::Ev10002 => "EV-10002",
            Self::Ev10050 => "EV-10050",
            Self::Ev0 => "EV-0",
            Self::Ev5 => "EV-5",
            Self::Req445H => "REQ-445-H",
            Self::Req445Ids => "REQ-445-IDS",
            Self::Req1059P => "REQ-1059-P",
            Self::Req30443A => "REQ-30443-A",
            Self::Req10002A => "REQ-10002-A",
            Self::Req10050A => "REQ-10050-A",
            Self::Req0A => "REQ-0-A",
            Self::Neg445H => "NEG-445-H",
        }
    }

    /// This row's entry in [`ROWS`], which lists the rows in declaration
    /// order (pinned by a test).
    #[must_use]
    pub const fn spec(self) -> &'static RowSpec {
        &ROWS[self as usize]
    }
}

/// The verb of a client→relay frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Verb {
    /// `EVENT`.
    Event,
    /// `REQ`.
    Req,
    /// `NEG-OPEN` (NIP-77).
    NegOpen,
    /// `CLOSE`.
    Close,
    /// `NEG-MSG`.
    NegMsg,
    /// `NEG-CLOSE`.
    NegClose,
    /// Anything else: `COUNT`, `AUTH`, an unknown verb, not a frame at all.
    Other,
}

impl Verb {
    /// The wire spelling, or `other`.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Event => "EVENT",
            Self::Req => "REQ",
            Self::NegOpen => "NEG-OPEN",
            Self::Close => "CLOSE",
            Self::NegMsg => "NEG-MSG",
            Self::NegClose => "NEG-CLOSE",
            Self::Other => "other",
        }
    }
}

/// A relay role as a lane declares it (`--plane <role>=…`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Role {
    /// Inbox relays (kind 10050, the gift wraps).
    Inbox,
    /// Key-package relays (kind 10002, the key packages).
    KeyPackage,
    /// Discovery (lookup) relays: asked about any account, and sent an
    /// account's own relay lists and nothing else (owner-directed 2026-11-12).
    Discovery,
    /// Profile relays (kind 0).
    Profile,
    /// Location relays (a circle's routing).
    Location,
}

impl Role {
    /// Every role, in report order.
    pub const ALL: [Self; 5] = [
        Self::Inbox,
        Self::KeyPackage,
        Self::Discovery,
        Self::Profile,
        Self::Location,
    ];

    /// The CLI and report spelling.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Inbox => "inbox",
            Self::KeyPackage => "keypackage",
            Self::Discovery => "discovery",
            Self::Profile => "profile",
            Self::Location => "location",
        }
    }

    /// The role a CLI spelling names.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|role| role.name() == name)
    }
}

/// A relay's plane as the table records it: a role, and for the account
/// roles whose list it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Plane {
    /// An account's own inbox list.
    OwnInbox,
    /// An account's own key-package list.
    OwnKeyPackage,
    /// An invitee's inbox list, as the inviter learnt it.
    InviteeInbox,
    /// An invitee's NIP-65 write relays.
    InviteeNip65Write,
    /// The discovery plane.
    Discovery,
    /// The profile plane.
    Profile,
    /// A circle's routing.
    Location,
}

impl Plane {
    /// The role this plane is part of.
    #[must_use]
    pub const fn role(self) -> Role {
        match self {
            Self::OwnInbox | Self::InviteeInbox => Role::Inbox,
            Self::OwnKeyPackage | Self::InviteeNip65Write => Role::KeyPackage,
            Self::Discovery => Role::Discovery,
            Self::Profile => Role::Profile,
            Self::Location => Role::Location,
        }
    }
}

/// How two planes one relay holds are judged by the table's validation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OverlapRule {
    /// Allowed without a declaration: one plane, or one account's two lists.
    Allowed,
    /// Allowed only when the table declares the pair.
    Declared,
    /// Never allowed: the table is unusable.
    Never,
}

/// The overlap rule for one relay holding both `a` and `b`.
///
/// One plane, or an account's own two lists, need no declaration. The
/// declarable pairs are a closed list: an own list with a location or the
/// discovery plane, and an invitee's list with anything but the profile
/// plane. The rest never share a relay — the profile plane (the product
/// subtracts every other plane from it), and the location pool with discovery
/// (no built-in list shares a host with the location pool).
#[must_use]
pub fn overlap_rule(a: Plane, b: Plane) -> OverlapRule {
    let own = |p| matches!(p, Plane::OwnInbox | Plane::OwnKeyPackage);
    let invitee = |p| matches!(p, Plane::InviteeInbox | Plane::InviteeNip65Write);
    let own_with = |x, y| own(x) && matches!(y, Plane::Location | Plane::Discovery);
    if a == b || (own(a) && own(b)) {
        OverlapRule::Allowed
    } else if a == Plane::Profile || b == Plane::Profile {
        OverlapRule::Never
    } else if invitee(a) || invitee(b) || own_with(a, b) || own_with(b, a) {
        OverlapRule::Declared
    } else {
        OverlapRule::Never
    }
}

/// Who may author an event row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Author {
    /// A key that is no identity the table knows.
    Ephemeral,
    /// [`Author::Ephemeral`], and used for this event only.
    EphemeralOnce,
    /// An account of the table (the sender itself, when it is known).
    Account,
    /// Not an event row.
    NotAnEvent,
}

/// The `limit` a filter row accepts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Limit {
    /// Any value, or none.
    Any,
    /// None, or at most this many.
    AtMost(u64),
    /// Exactly as many as the filter names ids.
    IdsLen,
}

/// One row: its shape and where it may land.
#[derive(Debug)]
pub struct RowSpec {
    /// The row.
    pub row: Row,
    /// `EVENT`, `REQ` or `NEG-OPEN`.
    pub verb: Verb,
    /// The kinds: an event's kind, or a filter's `kinds` set exactly.
    pub kinds: &'static [u16],
    /// EVENT: tag names present exactly once each. REQ / NEG-OPEN: filter keys
    /// that must be present.
    pub required: &'static [&'static str],
    /// EVENT: tag names that may repeat. REQ / NEG-OPEN: filter keys that may
    /// be present. Nothing outside `required` and `optional` is admitted.
    pub optional: &'static [&'static str],
    /// The `limit` the filter may carry.
    pub limit: Limit,
    /// Who may author it.
    pub author: Author,
    /// The roles a relay receiving it may hold.
    pub roles: &'static [Role],
    /// The binding, as the documented matrix states it.
    pub admitted_on: &'static str,
}

/// The opening message of every NEG-OPEN Haven sends: the empty set, so the
/// relay learns the filter alone (NIP-77 version 0x61, one `IdList` range of
/// length 0).
pub const NEG_INITIAL_MESSAGE: &str = "6100000200";

/// The longest `expiration − created_at` a location may carry (group
/// component 0x8005, `RetentionBoundPeeler`).
pub const LOCATION_RETENTION_MAX_SECS: u64 = 228;

/// The `limit` of the relay-status probe, the one lookup shape admitted on
/// either own list (`check_event_on_relay`).
pub const STATUS_PROBE_LIMIT: u64 = 5;

/// Haven's key-package tags, each exactly once (MDK's publication template).
const KEY_PACKAGE_TAGS: &[&str] = &[
    "d",
    "mls_protocol_version",
    "i",
    "mls_ciphersuite",
    "mls_extensions",
    "mls_proposals",
    "app_components",
];

/// The matrix.
pub static ROWS: [RowSpec; 16] = [
    RowSpec {
        row: Row::Ev445Commit,
        verb: Verb::Event,
        kinds: &[445],
        required: &["h"],
        optional: &[],
        limit: Limit::Any,
        author: Author::EphemeralOnce,
        roles: &[Role::Location],
        admitted_on: "a relay of the `h` circle's routing kept at the instant (the targets frozen at staging, a routing the change leaves included)",
    },
    RowSpec {
        row: Row::Ev445Location,
        verb: Verb::Event,
        kinds: &[445],
        required: &["h", "expiration"],
        optional: &[],
        limit: Limit::Any,
        author: Author::EphemeralOnce,
        roles: &[Role::Location],
        admitted_on: "a relay of the `h` circle's routing current at the instant, or one it left at or after the event's `created_at`; `0 < expiration - created_at <= 228`",
    },
    RowSpec {
        row: Row::Ev1059,
        verb: Verb::Event,
        kinds: &[1059],
        required: &["p"],
        optional: &[],
        limit: Limit::Any,
        author: Author::Ephemeral,
        roles: &[Role::Inbox],
        admitted_on: "a relay an inbox list of the `p` recipient named at or before the instant",
    },
    RowSpec {
        row: Row::Ev30443,
        verb: Verb::Event,
        kinds: &[30443],
        required: KEY_PACKAGE_TAGS,
        optional: &[],
        limit: Limit::Any,
        author: Author::Account,
        roles: &[Role::KeyPackage],
        admitted_on: "the author's own key-package list",
    },
    RowSpec {
        row: Row::Ev10002,
        verb: Verb::Event,
        kinds: &[10002],
        required: &[],
        optional: &["r"],
        limit: Limit::Any,
        author: Author::Account,
        roles: &[Role::KeyPackage, Role::Discovery],
        admitted_on: "the author's own key-package list, or a discovery relay; no relay it names holds the location, profile or discovery role without holding one of the author's own lists",
    },
    RowSpec {
        row: Row::Ev10050,
        verb: Verb::Event,
        kinds: &[10050],
        required: &[],
        optional: &["relay"],
        limit: Limit::Any,
        author: Author::Account,
        roles: &[Role::Inbox, Role::Discovery],
        admitted_on: "the author's own inbox list, or a discovery relay; no relay it names holds the location, profile or discovery role without holding one of the author's own lists",
    },
    RowSpec {
        row: Row::Ev0,
        verb: Verb::Event,
        kinds: &[0],
        required: &[],
        optional: &[],
        limit: Limit::Any,
        author: Author::Account,
        roles: &[Role::Profile],
        admitted_on: "a profile relay",
    },
    RowSpec {
        row: Row::Ev5,
        verb: Verb::Event,
        kinds: &[5],
        required: &[],
        optional: &["e", "a", "k"],
        limit: Limit::Any,
        author: Author::Account,
        roles: &[Role::Inbox, Role::KeyPackage, Role::Discovery, Role::Profile],
        admitted_on: "a relay admitting EVERY kind it retracts (each `k`, each `a` coordinate's kind, each `e` id's kind; at least one `k` or `a`): 0 on a profile relay, 10050 / 10002 on the author's own inbox / key-package list current or former or on a discovery relay, 30443 on the current key-package list",
    },
    RowSpec {
        row: Row::Req445H,
        verb: Verb::Req,
        kinds: &[445],
        required: &["kinds", "#h"],
        optional: &["since", "until", "limit"],
        limit: Limit::Any,
        author: Author::NotAnEvent,
        roles: &[Role::Location],
        admitted_on: "a relay where every `#h` circle's routing stands",
    },
    RowSpec {
        row: Row::Req445Ids,
        verb: Verb::Req,
        kinds: &[445],
        required: &["ids", "kinds", "limit"],
        optional: &["#h"],
        limit: Limit::IdsLen,
        author: Author::NotAnEvent,
        roles: &[Role::Location],
        admitted_on: "a relay where the routing of every id's circle (the event index) and of every `#h` circle is kept; `limit` = the number of ids",
    },
    RowSpec {
        row: Row::Req1059P,
        verb: Verb::Req,
        kinds: &[1059],
        required: &["kinds", "#p"],
        optional: &["since", "limit"],
        limit: Limit::AtMost(1000),
        author: Author::NotAnEvent,
        roles: &[Role::Inbox],
        admitted_on: "the inbox list of the one `#p` value, which is the sender when the sender is known",
    },
    RowSpec {
        row: Row::Req30443A,
        verb: Verb::Req,
        kinds: &[30443],
        required: &["kinds", "authors"],
        optional: &["limit"],
        limit: Limit::AtMost(64),
        author: Author::NotAnEvent,
        roles: &[Role::Inbox, Role::KeyPackage, Role::Discovery],
        admitted_on: "one author: the sender's own key-package list when it is the sender; otherwise a discovery relay or the author's key-package or NIP-65 write list; `limit` 5 (the status probe) also either own list of an account",
    },
    RowSpec {
        row: Row::Req10002A,
        verb: Verb::Req,
        kinds: &[10002],
        required: &["kinds", "authors"],
        optional: &["limit"],
        limit: Limit::AtMost(64),
        author: Author::NotAnEvent,
        roles: &[Role::Inbox, Role::KeyPackage, Role::Discovery],
        admitted_on: "one author: the sender's own key-package list or a discovery relay when it is the sender; otherwise a discovery relay or the author's key-package or NIP-65 write list; `limit` 5 (the status probe) also either own list of an account",
    },
    RowSpec {
        row: Row::Req10050A,
        verb: Verb::Req,
        kinds: &[10050],
        required: &["kinds", "authors"],
        optional: &["limit"],
        limit: Limit::AtMost(64),
        author: Author::NotAnEvent,
        roles: &[Role::Inbox, Role::KeyPackage, Role::Discovery],
        admitted_on: "one author: the sender's own inbox list or a discovery relay when it is the sender; otherwise a discovery relay or the author's inbox list; `limit` 5 (the status probe) also either own list of an account",
    },
    RowSpec {
        row: Row::Req0A,
        verb: Verb::Req,
        kinds: &[0],
        required: &["kinds", "authors"],
        optional: &["limit"],
        limit: Limit::AtMost(4),
        author: Author::NotAnEvent,
        roles: &[Role::Profile],
        admitted_on: "one author, a profile relay",
    },
    RowSpec {
        row: Row::Neg445H,
        verb: Verb::NegOpen,
        kinds: &[445],
        required: &["kinds", "#h", "since", "until", "limit"],
        optional: &[],
        limit: Limit::AtMost(16_384),
        author: Author::NotAnEvent,
        roles: &[Role::Location],
        admitted_on: "one `#h` circle whose routing stands; opening message `6100000200`",
    },
];

fn code_list(items: &[&str]) -> String {
    if items.is_empty() {
        return "none".to_owned();
    }
    items
        .iter()
        .map(|item| format!("`{item}`"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn kinds_list(kinds: &[u16]) -> String {
    kinds
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

const fn author_text(author: Author) -> &'static str {
    match author {
        Author::Ephemeral => "ephemeral (no known identity)",
        Author::EphemeralOnce => "ephemeral (no known identity), used once",
        Author::Account => "an account",
        Author::NotAnEvent => "-",
    }
}

fn limit_text(limit: Limit) -> String {
    match limit {
        Limit::Any => "any".to_owned(),
        Limit::AtMost(n) => format!("at most {n}"),
        Limit::IdsLen => "= ids".to_owned(),
    }
}

/// The matrix as the Markdown table `haven-core/SECURITY.md` carries.
#[must_use]
pub fn render_markdown() -> String {
    let mut out = String::from(
        "| Row | Frame | Kinds | Exactly once / required | May repeat / optional | Limit | Author | Admitted on |\n\
         |---|---|---|---|---|---|---|---|\n",
    );
    for spec in &ROWS {
        let limit = if spec.verb == Verb::Event {
            "-".to_owned()
        } else {
            limit_text(spec.limit)
        };
        let _ = writeln!(
            out,
            "| `{}` | {} | {} | {} | {} | {} | {} | {} |",
            spec.row.id(),
            spec.verb.name(),
            kinds_list(spec.kinds),
            code_list(spec.required),
            code_list(spec.optional),
            limit,
            author_text(spec.author),
            spec.admitted_on,
        );
    }
    out
}

fn json_str(text: &str) -> String {
    serde_json::Value::String(text.to_owned()).to_string()
}

fn json_list(items: &[&str]) -> String {
    let quoted: Vec<String> = items.iter().map(|item| json_str(item)).collect();
    format!("[{}]", quoted.join(", "))
}

const README: &[&str] = &[
    "GENERATED by `haven-wire-planes --export` from tooling/e2e/local-relay/src/planes/policy.rs ROWS. Never hand-edit:",
    "the crate test the_exported_matrix_is_current fails until this file is regenerated.",
    "Its only reader is the Dart mirror test (role -> event kinds); every judge reads ROWS itself.",
    "Per role: the event kinds a relay holding it may receive, and the REQ / NEG-OPEN shapes (kinds,",
    "required keys, optional keys) it may receive. Bindings are in haven-core/SECURITY.md",
    "\"The relay-plane allow matrix\".",
];

/// The matrix as `tooling/e2e/relay_planes.json` carries it.
///
/// Written by hand rather than through a serde map so the key order is the
/// matrix's own and cannot move with a dependency's feature flags.
#[must_use]
pub fn export_json() -> String {
    let mut out = String::from("{\n  \"_readme\": [\n");
    for (i, line) in README.iter().enumerate() {
        let sep = if i + 1 == README.len() { "" } else { "," };
        let _ = writeln!(out, "    {}{sep}", json_str(line));
    }
    out.push_str("  ],\n  \"version\": 1,\n  \"roles\": {\n");
    for (r, role) in Role::ALL.iter().enumerate() {
        let rows: Vec<&RowSpec> = ROWS
            .iter()
            .filter(|spec| spec.roles.contains(role))
            .collect();
        let mut kinds: Vec<u16> = Vec::new();
        for spec in rows.iter().filter(|spec| spec.verb == Verb::Event) {
            for kind in spec.kinds {
                if !kinds.contains(kind) {
                    kinds.push(*kind);
                }
            }
        }
        let _ = writeln!(out, "    {}: {{", json_str(role.name()));
        let _ = writeln!(out, "      \"events\": [{}],", kinds_list(&kinds));
        for (verb, key, last) in [(Verb::Req, "reqs", false), (Verb::NegOpen, "neg", true)] {
            let shapes: Vec<String> = rows
                .iter()
                .filter(|spec| spec.verb == verb)
                .map(|spec| {
                    format!(
                        "        {{\"row\": {}, \"kinds\": [{}], \"required\": {}, \"optional\": {}}}",
                        json_str(spec.row.id()),
                        kinds_list(spec.kinds),
                        json_list(spec.required),
                        json_list(spec.optional),
                    )
                })
                .collect();
            let sep = if last { "" } else { "," };
            if shapes.is_empty() {
                let _ = writeln!(out, "      \"{key}\": []{sep}");
            } else {
                let _ = writeln!(
                    out,
                    "      \"{key}\": [\n{}\n      ]{sep}",
                    shapes.join(",\n")
                );
            }
        }
        let sep = if r + 1 == Role::ALL.len() { "" } else { "," };
        let _ = writeln!(out, "    }}{sep}");
    }
    out.push_str("  }\n}\n");
    out
}
