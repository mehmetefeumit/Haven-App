//! The ground truth a judgement is made against: which relay held which plane,
//! for whom, and when.
//!
//! Every membership is an interval `[added, removed)` in a caller-local
//! ordinal — L1's step counter, the soak ledger's instant, the journal's
//! `wire_seq` — so a frame is judged against the planes its relay held when it
//! was sent. A circle's routing is recorded at STAGING, the sender's own
//! decision, never at confirmation.
//!
//! The table holds pubkeys, routing ids, event ids and relay URLs, so it has
//! no `Debug`: nothing about it may reach a log or a test failure message
//! (Security Rule 15).

use std::collections::{BTreeMap, BTreeSet};

use super::policy::{overlap_rule, OverlapRule, Plane};

/// A relay of the table, by position. Carries no URL.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RelayIx(pub u32);

/// How a relay URL named inside an event (a relay-list entry, a routing
/// declaration) is matched to a relay of the table.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RelayMatch {
    /// By lowercased host and port.
    Authority,
    /// By port alone: every relay of a hermetic lane is a distinct loopback
    /// port, and the app names it by an address the recorder never sees
    /// (`10.0.2.2`, `localhost`).
    Port,
}

/// Which list a membership is on.
#[derive(Clone, Copy)]
pub enum List<'a> {
    /// The account's own inbox list.
    OwnInbox(&'a str),
    /// The account's own key-package list.
    OwnKeyPackage(&'a str),
    /// The invitee's inbox list as the inviter learnt it.
    InviteeInbox(&'a str),
    /// The invitee's NIP-65 write relays.
    InviteeNip65Write(&'a str),
    /// The discovery plane.
    Discovery,
    /// The profile plane.
    Profile,
}

impl List<'_> {
    const fn parts(&self) -> (Plane, Option<&str>) {
        match *self {
            Self::OwnInbox(pk) => (Plane::OwnInbox, Some(pk)),
            Self::OwnKeyPackage(pk) => (Plane::OwnKeyPackage, Some(pk)),
            Self::InviteeInbox(pk) => (Plane::InviteeInbox, Some(pk)),
            Self::InviteeNip65Write(pk) => (Plane::InviteeNip65Write, Some(pk)),
            Self::Discovery => (Plane::Discovery, None),
            Self::Profile => (Plane::Profile, None),
        }
    }
}

/// How a routing entry ends. No `Debug`: it holds an absolute instant.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RoutingEnd {
    /// The ordinal from which the relay is no longer the circle's current
    /// routing.
    pub removed: u64,
    /// The ordinal from which its `#h` REQs and NEG passes stop standing
    /// (`PRIOR_ROUTING_STANDS_SECS` and `routing_retained_epochs`); `None`:
    /// not within the run.
    pub stands_until: Option<u64>,
    /// The ordinal from which by-id fetches and commit resends stop being kept;
    /// `None`: not within the run.
    pub kept_until: Option<u64>,
    /// The change instant in unix seconds: a location whose `created_at` is at
    /// or before it was sealed for this routing. `None`: no location sealed
    /// before the change may follow it.
    pub left_at_secs: Option<u64>,
}

#[derive(Clone, Copy)]
struct Span {
    added: u64,
    removed: Option<u64>,
}

impl Span {
    fn current(self, at: u64) -> bool {
        self.added <= at && self.removed.is_none_or(|removed| at < removed)
    }

    const fn known(self, at: u64) -> bool {
        self.added <= at
    }

    fn former(self, at: u64) -> bool {
        self.removed.is_some_and(|removed| removed <= at)
    }
}

struct Entry {
    plane: Plane,
    owner: Option<String>,
    relay: RelayIx,
    span: Span,
}

struct Routing {
    h: String,
    relay: RelayIx,
    span: Span,
    end: Option<RoutingEnd>,
}

struct Member {
    h: String,
    pubkey: String,
    span: Span,
}

/// Why a table cannot be judged against.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unusable {
    /// A relay holds two planes that may never share one
    /// ([`OverlapRule::Never`]).
    Undeclarable(Plane, Plane),
    /// A relay holds two planes no declaration admits together.
    UndeclaredOverlap(Plane, Plane),
}

/// The ground truth. Built by the caller, judged by [`super::judge::judge`].
pub struct PlaneTable {
    matching: RelayMatch,
    relays: Vec<(String, u16)>,
    accounts: BTreeSet<String>,
    entries: Vec<Entry>,
    routings: Vec<Routing>,
    members: Vec<Member>,
    events: BTreeMap<String, (u16, Option<String>)>,
    declared: BTreeSet<(Plane, Plane)>,
}

/// `(lowercased host, explicit port, the scheme's default port)` of a
/// `ws://` / `wss://` URL.
fn split(url: &str) -> Option<(String, Option<u16>, u16)> {
    let lower = url.trim().to_ascii_lowercase();
    let (rest, default_port) = match lower.split_once("://")? {
        ("wss", rest) => (rest, 443),
        ("ws", rest) => (rest, 80),
        _ => return None,
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let hostport = &rest[..end];
    let (host, port) = if let Some(bracketed) = hostport.strip_prefix('[') {
        let (host, tail) = bracketed.split_once(']')?;
        match tail {
            "" => (host, None),
            tail => (host, Some(tail.strip_prefix(':')?)),
        }
    } else {
        match hostport.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (hostport, None),
        }
    };
    if host.is_empty() {
        return None;
    }
    let port = match port {
        Some(port) => Some(port.parse().ok()?),
        None => None,
    };
    Some((host.to_owned(), port, default_port))
}

/// `(lowercased host, port)` of a `ws://` / `wss://` URL: the explicit port,
/// else the scheme's default.
#[must_use]
pub fn authority(url: &str) -> Option<(String, u16)> {
    split(url).map(|(host, port, default_port)| (host, port.unwrap_or(default_port)))
}

/// The port a `ws://` / `wss://` URL names explicitly, `None` when it names
/// none.
#[must_use]
pub fn explicit_port(url: &str) -> Option<u16> {
    split(url)?.1
}

impl PlaneTable {
    /// An empty table whose relay URLs match by `matching`.
    #[must_use]
    pub const fn new(matching: RelayMatch) -> Self {
        Self {
            matching,
            relays: Vec::new(),
            accounts: BTreeSet::new(),
            entries: Vec::new(),
            routings: Vec::new(),
            members: Vec::new(),
            events: BTreeMap::new(),
            declared: BTreeSet::new(),
        }
    }

    /// Registers a relay by its URL; `None` when it is not a `ws(s)://` URL.
    pub fn add_relay(&mut self, url: &str) -> Option<RelayIx> {
        let key = authority(url)?;
        let ix = RelayIx(u32::try_from(self.relays.len()).ok()?);
        self.relays.push(key);
        Some(ix)
    }

    /// The relay a URL named inside an event matches, if any.
    #[must_use]
    pub fn resolve(&self, url: &str) -> Option<RelayIx> {
        let (host, port) = authority(url)?;
        let position = self
            .relays
            .iter()
            .position(|(h, p)| *p == port && (self.matching == RelayMatch::Port || *h == host))?;
        u32::try_from(position).ok().map(RelayIx)
    }

    /// `pubkey` is an account of the run even while its own lists name no
    /// relay of the table. Being on an own list makes it one too.
    pub fn add_account(&mut self, pubkey: &str) {
        self.accounts.insert(pubkey.to_owned());
    }

    /// `relay` joins `list` at `at`. Idempotent while the membership is open.
    pub fn add(&mut self, list: List<'_>, relay: RelayIx, at: u64) {
        let (plane, owner) = list.parts();
        if self.open_entry(plane, owner, relay).is_some() {
            return;
        }
        self.entries.push(Entry {
            plane,
            owner: owner.map(str::to_owned),
            relay,
            span: Span {
                added: at,
                removed: None,
            },
        });
    }

    /// `relay` leaves `list` at `at`; nothing when it is not on it.
    pub fn remove(&mut self, list: List<'_>, relay: RelayIx, at: u64) {
        let (plane, owner) = list.parts();
        if let Some(i) = self.open_entry(plane, owner, relay) {
            self.entries[i].span.removed = Some(at);
        }
    }

    fn open_entry(&self, plane: Plane, owner: Option<&str>, relay: RelayIx) -> Option<usize> {
        self.entries.iter().position(|e| {
            e.plane == plane
                && e.owner.as_deref() == owner
                && e.relay == relay
                && e.span.removed.is_none()
        })
    }

    /// `relay` joins circle `h`'s routing at `at` — the instant it was staged.
    pub fn add_routing(&mut self, h: &str, relay: RelayIx, at: u64) {
        if self.open_routing(h, relay).is_some() {
            return;
        }
        self.routings.push(Routing {
            h: h.to_owned(),
            relay,
            span: Span {
                added: at,
                removed: None,
            },
            end: None,
        });
    }

    /// `relay` leaves circle `h`'s routing as `end` says; nothing when it is
    /// not on it.
    pub fn retire_routing(&mut self, h: &str, relay: RelayIx, end: RoutingEnd) {
        if let Some(i) = self.open_routing(h, relay) {
            self.routings[i].span.removed = Some(end.removed);
            self.routings[i].end = Some(end);
        }
    }

    fn open_routing(&self, h: &str, relay: RelayIx) -> Option<usize> {
        self.routings
            .iter()
            .position(|r| r.h == h && r.relay == relay && r.span.removed.is_none())
    }

    /// `pubkey` is a member of circle `h` from `at`.
    pub fn add_member(&mut self, h: &str, pubkey: &str, at: u64) {
        self.members.push(Member {
            h: h.to_owned(),
            pubkey: pubkey.to_owned(),
            span: Span {
                added: at,
                removed: None,
            },
        });
    }

    /// `pubkey` stops being a member of circle `h` at `at`.
    pub fn remove_member(&mut self, h: &str, pubkey: &str, at: u64) {
        if let Some(member) = self
            .members
            .iter_mut()
            .find(|m| m.h == h && m.pubkey == pubkey && m.span.removed.is_none())
        {
            member.span.removed = Some(at);
        }
    }

    /// Records an event the run saw: its kind and its `h`, if it has one.
    pub fn index_event(&mut self, id: &str, kind: u16, h: Option<&str>) {
        self.events
            .entry(id.to_owned())
            .or_insert_with(|| (kind, h.map(str::to_owned)));
    }

    /// Admits one relay holding both `a` and `b`. Only a pair whose
    /// [`overlap_rule`] is [`OverlapRule::Declared`] can be declared; this
    /// returns `false` for any other.
    pub fn declare_overlap(&mut self, a: Plane, b: Plane) -> bool {
        if overlap_rule(a, b) != OverlapRule::Declared {
            return false;
        }
        self.declared.insert(if a <= b { (a, b) } else { (b, a) });
        true
    }

    fn relay_ixs(&self) -> impl Iterator<Item = RelayIx> {
        (0..).map(RelayIx).take(self.relays.len())
    }

    fn planes_of(&self, relay: RelayIx) -> BTreeSet<Plane> {
        let mut planes: BTreeSet<Plane> = self
            .entries
            .iter()
            .filter(|e| e.relay == relay)
            .map(|e| e.plane)
            .collect();
        if self.routings.iter().any(|r| r.relay == relay) {
            planes.insert(Plane::Location);
        }
        planes
    }

    /// Checks every relay's planes, over the whole run, against
    /// [`overlap_rule`] and the declarations.
    ///
    /// # Errors
    ///
    /// The first relay holding two planes that may never share one, or two
    /// no declaration admits.
    pub fn validate(&self) -> Result<(), Unusable> {
        for relay in self.relay_ixs() {
            let planes = self.planes_of(relay);
            for &a in &planes {
                for &b in planes.range(a..).skip(1) {
                    match overlap_rule(a, b) {
                        OverlapRule::Allowed => {}
                        OverlapRule::Never => return Err(Unusable::Undeclarable(a, b)),
                        OverlapRule::Declared if self.declared.contains(&(a, b)) => {}
                        OverlapRule::Declared => return Err(Unusable::UndeclaredOverlap(a, b)),
                    }
                }
            }
        }
        Ok(())
    }

    /// How many relays hold more than one plane — advisory, for coverage.
    #[must_use]
    pub fn overlapping_relays(&self) -> usize {
        self.relay_ixs()
            .filter(|&relay| self.planes_of(relay).len() > 1)
            .count()
    }

    pub(super) fn is_identity(&self, pubkey: &str) -> bool {
        self.accounts.contains(pubkey)
            || self
                .entries
                .iter()
                .any(|e| e.owner.as_deref() == Some(pubkey))
    }

    pub(super) fn is_account(&self, pubkey: &str) -> bool {
        self.accounts.contains(pubkey)
            || self.entries.iter().any(|e| {
                matches!(e.plane, Plane::OwnInbox | Plane::OwnKeyPackage)
                    && e.owner.as_deref() == Some(pubkey)
            })
    }

    pub(super) fn has_list(&self, plane: Plane, owner: &str) -> bool {
        self.entries
            .iter()
            .any(|e| e.plane == plane && e.owner.as_deref() == Some(owner))
    }

    fn entry_where(
        &self,
        plane: Plane,
        owner: Option<&str>,
        relay: RelayIx,
        held: impl Fn(Span) -> bool,
    ) -> bool {
        self.entries.iter().any(|e| {
            e.plane == plane && e.owner.as_deref() == owner && e.relay == relay && held(e.span)
        })
    }

    /// `relay` is on the list at `at`.
    pub(super) fn current(
        &self,
        plane: Plane,
        owner: Option<&str>,
        relay: RelayIx,
        at: u64,
    ) -> bool {
        self.entry_where(plane, owner, relay, |span| span.current(at))
    }

    /// `relay` was put on the list at or before `at`, whether or not it has
    /// left since — the targets a send frozen at staging may still hold.
    pub(super) fn known(&self, plane: Plane, owner: Option<&str>, relay: RelayIx, at: u64) -> bool {
        self.entry_where(plane, owner, relay, |span| span.known(at))
    }

    /// `relay` left the list at or before `at`.
    pub(super) fn former(
        &self,
        plane: Plane,
        owner: Option<&str>,
        relay: RelayIx,
        at: u64,
    ) -> bool {
        self.entry_where(plane, owner, relay, |span| span.former(at))
    }

    pub(super) fn has_routing(&self, h: &str) -> bool {
        self.routings.iter().any(|r| r.h == h)
    }

    fn routing_where(&self, h: &str, relay: RelayIx, held: impl Fn(&Routing) -> bool) -> bool {
        self.routings
            .iter()
            .any(|r| r.h == h && r.relay == relay && held(r))
    }

    pub(super) fn routing_current(&self, h: &str, relay: RelayIx, at: u64) -> bool {
        self.routing_where(h, relay, |r| r.span.current(at))
    }

    pub(super) fn routing_standing(&self, h: &str, relay: RelayIx, at: u64) -> bool {
        self.routing_where(h, relay, |r| {
            r.span.known(at) && r.end.and_then(|e| e.stands_until).is_none_or(|s| at < s)
        })
    }

    pub(super) fn routing_kept(&self, h: &str, relay: RelayIx, at: u64) -> bool {
        self.routing_where(h, relay, |r| {
            r.span.known(at) && r.end.and_then(|e| e.kept_until).is_none_or(|k| at < k)
        })
    }

    /// A location created at `created_at` was sealed before `relay` left
    /// circle `h`'s routing, and the routing is still kept.
    pub(super) fn routing_left_after(
        &self,
        h: &str,
        relay: RelayIx,
        at: u64,
        created_at: u64,
    ) -> bool {
        self.routing_kept(h, relay, at)
            && self.routing_where(h, relay, |r| {
                r.end
                    .and_then(|e| e.left_at_secs)
                    .is_some_and(|left| created_at <= left)
            })
    }

    pub(super) fn any_routing_current(&self, relay: RelayIx, at: u64) -> bool {
        self.routings
            .iter()
            .any(|r| r.relay == relay && r.span.current(at))
    }

    pub(super) fn member(&self, h: &str, pubkey: &str, at: u64) -> bool {
        self.members
            .iter()
            .any(|m| m.h == h && m.pubkey == pubkey && m.span.current(at))
    }

    pub(super) fn event(&self, id: &str) -> Option<(u16, Option<&str>)> {
        self.events.get(id).map(|(kind, h)| (*kind, h.as_deref()))
    }
}
