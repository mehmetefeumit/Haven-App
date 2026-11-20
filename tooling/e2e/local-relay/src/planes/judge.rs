//! The one judge: every observed client→relay frame against [`ROWS`] and the
//! [`PlaneTable`].
//!
//! A frame is first matched to a row by SHAPE alone (verb, kinds, exact tag or
//! key set, limit); no row → [`Class::UnknownFrame`]. The row's binding then
//! decides whether the relay may receive it at that instant; no → a crossing.
//! A relay holding several planes admits their union. With the sender known
//! (soak devices, L1b fronts) the per-identity bindings are enforced; with it
//! unknown (L1a, the E2E journal) the union over every account applies.
//!
//! [`ROWS`]: super::policy::ROWS

use std::collections::{BTreeMap, HashMap, HashSet};

use super::frame::{Event, Filter, Frame};
use super::policy::{
    Author, Limit, Plane, Row, Verb, LOCATION_RETENTION_MAX_SECS, NEG_INITIAL_MESSAGE, ROWS,
};
use super::table::{PlaneTable, RelayIx, Unusable};

/// One frame as a relay received it.
pub struct Observed<'a> {
    /// The relay that received it.
    pub relay: RelayIx,
    /// The connection it came on, an opaque caller-chosen number: `NEG-MSG`
    /// and `NEG-CLOSE` must name a session opened on it. A `CLOSE` must name a
    /// subscription opened on its relay: the SDK sends one pending at a
    /// reconnect on the new socket, which tells that relay nothing new.
    pub conn: u64,
    /// The identity that sent it, when the caller knows.
    pub sender: Option<&'a str>,
    /// When, in the table's ordinal.
    pub at: u64,
    /// The frame.
    pub frame: &'a Frame,
}

/// What is wrong with a frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Class {
    /// An event on a relay its row does not admit.
    CrossedEvent,
    /// A REQ or NEG-OPEN filter on a relay its row does not admit.
    CrossedRequest,
    /// A frame no row admits: unknown verb, `COUNT`, an unparsable
    /// frame, a stray tag or key, a filter spanning two rows, a REQ whose
    /// filters land on different planes, a `CLOSE` naming a subscription its
    /// relay was never sent, a `NEG-*` naming a session its connection never
    /// opened.
    UnknownFrame,
    /// An ephemeral row authored by a known identity or a reused key, or an
    /// identity row authored by someone other than the known sender.
    WrongAuthor,
    /// A relay list naming a relay of another plane
    /// (`RELAY_LIST_NAMES_FOREIGN_PLANE`).
    ListNamesForeignPlane,
    /// An `e` or `ids` value the event index does not hold.
    UnresolvedId,
    /// A binding needs a list the table holds none of for that pubkey.
    NoGroundTruth,
    /// An `h` no routing of the table names.
    UndeclaredCircle,
    /// A frame on a connection that answered a NIP-42 challenge which is not
    /// a gift-wrap read of the answering key's own or its `CLOSE`, or an
    /// answer under a second key: the answer ties the identity to whatever
    /// that connection carries.
    AuthOnSharedConnection,
}

impl Class {
    /// The report spelling.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::CrossedEvent => "plane-crossed-event",
            Self::CrossedRequest => "plane-crossed-request",
            Self::UnknownFrame => "plane-unknown-frame",
            Self::WrongAuthor => "plane-wrong-author",
            Self::ListNamesForeignPlane => "relay-list-names-foreign-plane",
            Self::UnresolvedId => "plane-unresolved-id",
            Self::NoGroundTruth => "plane-no-ground-truth",
            Self::UndeclaredCircle => "plane-undeclared-circle",
            Self::AuthOnSharedConnection => "plane-auth-shared-connection",
        }
    }
}

/// One finding. Positions and fieldless enums only: its `Debug` is safe to
/// print anywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Finding {
    /// The frame's position in the input.
    pub index: usize,
    /// The relay that received it.
    pub relay: RelayIx,
    /// The frame's verb.
    pub verb: Verb,
    /// The row its shape matched, when one did.
    pub row: Option<Row>,
    /// What is wrong.
    pub class: Class,
}

/// Every finding, in `(relay, input)` order, and how often each row was
/// admitted on each relay through each plane. No `Debug`: the hits are exact
/// counts (Security Rule 15); print the findings.
#[derive(Default)]
pub struct Judgement {
    /// The findings.
    pub findings: Vec<Finding>,
    /// Admitted frames (a REQ counts once per filter).
    pub hits: BTreeMap<(RelayIx, Row, Plane), u32>,
}

/// Why a frame was not admitted: the row its shape matched, if one did, and
/// the class.
type Reject = (Option<Row>, Class);

type Verdict = Result<Plane, Reject>;

struct Judge<'t> {
    table: &'t PlaneTable,
    reqs: HashMap<RelayIx, HashSet<String>>,
    negs: HashMap<u64, HashSet<String>>,
    ephemeral: HashMap<String, String>,
    conns: BTreeMap<u64, Carried>,
    /// Each relay's `auth-required:` demands, by event id: the earliest
    /// instant.
    demanded: HashMap<(RelayIx, &'t str), u64>,
    /// Each admitted kind-1059 or kind-445 event, by relay and id: the plane
    /// it was admitted on.
    resendable: HashMap<(RelayIx, String), Plane>,
}

/// What one connection carried, for [`Row::Auth22242`]'s binding: its
/// answers; the answers off the author's own inbox list, with what each
/// would be refused as if no resend licenses it; and every frame other than
/// an answer or a `CLOSE`, with the key whose own gift wraps it reads, if it
/// is such a read, and the event it publishes, if it is an `EVENT`.
#[derive(Default)]
struct Carried {
    answers: Vec<Answer>,
    deferred: Vec<(usize, RelayIx, Class)>,
    others: Vec<Other>,
}

/// One frame of a connection other than an answer or a `CLOSE`.
struct Other {
    index: usize,
    relay: RelayIx,
    verb: Verb,
    /// The key whose own gift wraps it reads, if it is such a read.
    read: Option<String>,
    /// The event it publishes, if it is an `EVENT`.
    published: Option<String>,
}

/// One answer to a challenge on a connection.
struct Answer {
    index: usize,
    relay: RelayIx,
    key: String,
    at: u64,
}

/// A relay's `OK false` with the `auth-required:` prefix for an event.
///
/// What licenses one write-only authenticated resend of that event to that
/// relay (owner decisions D1b and D1c). Read off the relay→client stream,
/// which the judge's frames do not carry.
#[derive(Clone, Copy)]
pub struct AuthDemand<'a> {
    /// The relay that answered.
    pub relay: RelayIx,
    /// When, in the table's ordinal.
    pub at: u64,
    /// The event id it refused for want of authentication.
    pub id: &'a str,
}

/// Judges `frames` against `table`.
///
/// # Errors
///
/// The table is unusable ([`PlaneTable::validate`]): a profile relay shares a
/// plane, or an overlap is undeclared. Nothing is judged then.
pub fn judge<'a>(
    table: &PlaneTable,
    frames: impl IntoIterator<Item = Observed<'a>>,
) -> Result<Judgement, Unusable> {
    judge_answered(table, frames, &[])
}

/// [`judge`], with the relays' `auth-required:` demands.
///
/// An answer to a challenge off the author's own inbox list is admitted only
/// as the one write-only resend such a demand licenses ([`Row::Auth22242`]).
///
/// # Errors
///
/// As [`judge`].
pub fn judge_answered<'a>(
    table: &PlaneTable,
    frames: impl IntoIterator<Item = Observed<'a>>,
    demands: &[AuthDemand<'_>],
) -> Result<Judgement, Unusable> {
    table.validate()?;
    let mut demanded: HashMap<(RelayIx, &str), u64> = HashMap::new();
    for demand in demands {
        let at = demanded
            .entry((demand.relay, demand.id))
            .or_insert(demand.at);
        *at = (*at).min(demand.at);
    }
    let mut judge = Judge {
        table,
        reqs: HashMap::new(),
        negs: HashMap::new(),
        ephemeral: HashMap::new(),
        conns: BTreeMap::new(),
        demanded,
        resendable: HashMap::new(),
    };
    let mut out = Judgement::default();
    for (index, obs) in frames.into_iter().enumerate() {
        judge.carry(index, &obs);
        match judge.frame(index, &obs) {
            Ok(admitted) => {
                for (row, plane) in admitted {
                    *out.hits.entry((obs.relay, row, plane)).or_default() += 1;
                }
            }
            Err((row, class)) => out.findings.push(Finding {
                index,
                relay: obs.relay,
                verb: obs.frame.verb(),
                row,
                class,
            }),
        }
    }
    let (findings, resends) = judge.shared_answers();
    out.findings.extend(findings);
    for (relay, plane) in resends {
        *out.hits.entry((relay, Row::Auth22242, plane)).or_default() += 1;
    }
    out.findings.sort_by_key(|f| (f.relay, f.index));
    Ok(out)
}

const UNKNOWN: Reject = (None, Class::UnknownFrame);

const fn require(ok: bool, row: Row, class: Class) -> Result<(), Reject> {
    if ok {
        Ok(())
    } else {
        Err((Some(row), class))
    }
}

/// The row whose tag shape an event `verb` carries has, if any: each required
/// tag exactly once, optional tags any number of times, nothing else.
fn event_row(event: &Event, verb: Verb) -> Option<Row> {
    ROWS.iter()
        .filter(|spec| spec.verb == verb && spec.kinds.contains(&event.kind))
        .find(|spec| {
            let names = || {
                event
                    .tags
                    .iter()
                    .map(|tag| tag.first().map_or("", String::as_str))
            };
            spec.required
                .iter()
                .all(|req| names().filter(|name| name == req).count() == 1)
                && names()
                    .all(|name| spec.required.contains(&name) || spec.optional.contains(&name))
        })
        .map(|spec| spec.row)
}

/// The row whose key shape a filter has: its `kinds` set exactly the row's,
/// every required key present, nothing outside required and optional.
fn filter_row(filter: &Filter, verb: Verb) -> Option<Row> {
    if filter.malformed {
        return None;
    }
    let kinds = filter.kinds.as_ref()?;
    let mut matched = ROWS.iter().filter(|spec| {
        spec.verb == verb
            && kinds.len() == spec.kinds.len()
            && spec.kinds.iter().all(|kind| kinds.contains(kind))
            && spec
                .required
                .iter()
                .all(|key| filter.keys.iter().any(|k| k == key))
            && filter.keys.iter().all(|key| {
                spec.required.contains(&key.as_str()) || spec.optional.contains(&key.as_str())
            })
    });
    let row = matched.next()?.row;
    matched.next().is_none().then_some(row)
}

fn one(values: Option<&Vec<String>>) -> Option<&str> {
    match values.map(Vec::as_slice) {
        Some([value]) => Some(value.as_str()),
        _ => None,
    }
}

fn opened(open: Option<&HashSet<String>>, sub: &str) -> Result<Vec<(Row, Plane)>, Reject> {
    if open.is_some_and(|open| open.contains(sub)) {
        Ok(Vec::new())
    } else {
        Err(UNKNOWN)
    }
}

impl Judge<'_> {
    fn frame(&mut self, index: usize, obs: &Observed<'_>) -> Result<Vec<(Row, Plane)>, Reject> {
        match obs.frame {
            Frame::Event(event) => {
                let row = event_row(event, Verb::Event).ok_or(UNKNOWN)?;
                let plane = self.event(row, event, obs)?;
                if matches!(event.kind, 445 | 1059) {
                    self.resendable
                        .entry((obs.relay, event.id.clone()))
                        .or_insert(plane);
                }
                Ok(vec![(row, plane)])
            }
            Frame::Req { sub, filters } => {
                self.reqs.entry(obs.relay).or_default().insert(sub.clone());
                let mut admitted = Vec::with_capacity(filters.len());
                for filter in filters {
                    let row = filter_row(filter, Verb::Req).ok_or(UNKNOWN)?;
                    admitted.push((row, self.filter(row, filter, obs)?));
                }
                let first = admitted.first().ok_or(UNKNOWN)?.1;
                if admitted.iter().any(|(_, plane)| *plane != first) {
                    return Err(UNKNOWN);
                }
                Ok(admitted)
            }
            Frame::NegOpen {
                sub,
                filter,
                initial,
            } => {
                self.negs.entry(obs.conn).or_default().insert(sub.clone());
                let row = filter_row(filter, Verb::NegOpen).ok_or(UNKNOWN)?;
                require(initial == NEG_INITIAL_MESSAGE, row, Class::UnknownFrame)?;
                Ok(vec![(row, self.filter(row, filter, obs)?)])
            }
            Frame::Close(sub) => opened(self.reqs.get(&obs.relay), sub),
            Frame::NegMsg(sub) | Frame::NegClose(sub) => opened(self.negs.get(&obs.conn), sub),
            Frame::Auth(event) => {
                let row = event_row(event, Verb::Auth).ok_or(UNKNOWN)?;
                self.account_author(row, event, obs)?;
                if self.table.has_list(Plane::OwnInbox, &event.pubkey)
                    && self.own(Plane::OwnInbox, &event.pubkey, obs)
                {
                    return Ok(vec![(row, Plane::OwnInbox)]);
                }
                // Off the author's own inbox list, an answer stands only as a
                // write-only resend, decided with its whole connection
                // (`shared_answers`).
                let refused = if self.table.has_list(Plane::OwnInbox, &event.pubkey) {
                    Class::CrossedEvent
                } else {
                    Class::NoGroundTruth
                };
                self.conns
                    .entry(obs.conn)
                    .or_default()
                    .deferred
                    .push((index, obs.relay, refused));
                Ok(Vec::new())
            }
            Frame::Other(_) => Err(UNKNOWN),
        }
    }

    /// Notes what `obs` adds to its connection's [`Carried`].
    fn carry(&mut self, index: usize, obs: &Observed<'_>) {
        let carried = self.conns.entry(obs.conn).or_default();
        match obs.frame {
            Frame::Auth(event) => carried.answers.push(Answer {
                index,
                relay: obs.relay,
                key: event.pubkey.clone(),
                at: obs.at,
            }),
            Frame::Close(_) => {}
            frame => {
                let own_read = match frame {
                    Frame::Req { filters, .. } => {
                        let mut keys = filters.iter().map(|filter| {
                            (filter_row(filter, Verb::Req) == Some(Row::Req1059P))
                                .then(|| one(filter.p.as_ref()))
                                .flatten()
                        });
                        let first = keys.next().flatten();
                        first
                            .filter(|first| keys.all(|key| key == Some(*first)))
                            .map(str::to_owned)
                    }
                    _ => None,
                };
                let published = match frame {
                    Frame::Event(event) => Some(event.id.clone()),
                    _ => None,
                };
                carried.others.push(Other {
                    index,
                    relay: obs.relay,
                    verb: frame.verb(),
                    read: own_read,
                    published,
                });
            }
        }
    }

    /// [`Row::Auth22242`]'s connection binding, over every connection once
    /// all of it is seen: a frame a connection carried before its answer
    /// counts as much as one after it. A connection is an own inbox read, or
    /// one write-only resend ([`Self::resend`]); anything else is a crossing.
    /// Returns the findings, and each resend's relay and the plane its event
    /// was admitted on.
    fn shared_answers(&self) -> (Vec<Finding>, Vec<(RelayIx, Plane)>) {
        let finding = |(index, relay, verb): (usize, RelayIx, Verb)| Finding {
            index,
            relay,
            verb,
            row: Some(Row::Auth22242),
            class: Class::AuthOnSharedConnection,
        };
        let mut out = Vec::new();
        let mut resends = Vec::new();
        for carried in self.conns.values() {
            let Some(first) = carried.answers.first() else {
                continue;
            };
            let one_key = carried.answers.iter().all(|answer| answer.key == first.key);
            if let Some(plane) = self.resend(carried).filter(|_| one_key) {
                resends.push((first.relay, plane));
                continue;
            }
            out.extend(
                carried
                    .deferred
                    .iter()
                    .map(|(index, relay, class)| Finding {
                        index: *index,
                        relay: *relay,
                        verb: Verb::Auth,
                        row: Some(Row::Auth22242),
                        class: *class,
                    }),
            );
            if !one_key {
                out.extend(
                    carried
                        .answers
                        .iter()
                        .map(|answer| finding((answer.index, answer.relay, Verb::Auth))),
                );
                continue;
            }
            out.extend(
                carried
                    .others
                    .iter()
                    .filter(|other| other.read.as_ref() != Some(&first.key))
                    .map(|other| finding((other.index, other.relay, other.verb))),
            );
        }
        (out, resends)
    }

    /// Whether `carried` is one write-only authenticated resend (owner
    /// decisions D1b and D1c), and the plane its event was admitted on: its
    /// relay answered `auth-required:` for a kind-1059 or kind-445 event this
    /// judge admitted there, at or before the connection's first answer; and
    /// the connection carried nothing but answers and that one event. With a
    /// journal that keeps one copy of each event per relay, the event may
    /// appear on the connection that first sent it alone.
    fn resend(&self, carried: &Carried) -> Option<Plane> {
        let first = carried.answers.first()?;
        if carried
            .answers
            .iter()
            .any(|answer| answer.relay != first.relay)
        {
            return None;
        }
        let mut published = carried.others.iter().map(|other| {
            (other.verb == Verb::Event && other.relay == first.relay)
                .then_some(other.published.as_deref())
                .flatten()
        });
        let licensed = |id: &str| {
            self.demanded
                .get(&(first.relay, id))
                .is_some_and(|at| *at <= first.at)
                .then(|| self.resendable.get(&(first.relay, id.to_owned())).copied())
                .flatten()
        };
        match published.next() {
            Some(Some(id)) => {
                if published.any(|other| other != Some(id)) {
                    return None;
                }
                licensed(id)
            }
            Some(None) => None,
            None => {
                if carried.deferred.is_empty() {
                    return None;
                }
                self.demanded
                    .keys()
                    .filter(|(relay, _)| *relay == first.relay)
                    .find_map(|(_, id)| licensed(id))
            }
        }
    }

    /// The circle checks every `h`-bound row shares: a routing exists, and a
    /// known sender is a member at the instant.
    fn circle(&self, row: Row, h: &str, obs: &Observed<'_>, crossed: Class) -> Result<(), Reject> {
        require(self.table.has_routing(h), row, Class::UndeclaredCircle)?;
        if let Some(sender) = obs.sender {
            require(self.table.member(h, sender, obs.at), row, crossed)?;
        }
        Ok(())
    }

    fn ephemeral_author(&mut self, row: Row, event: &Event) -> Result<(), Reject> {
        require(
            !self.table.is_identity(&event.pubkey),
            row,
            Class::WrongAuthor,
        )?;
        if row.spec().author != Author::EphemeralOnce {
            return Ok(());
        }
        let first = self
            .ephemeral
            .entry(event.pubkey.clone())
            .or_insert_with(|| event.id.clone());
        require(*first == event.id, row, Class::WrongAuthor)
    }

    fn account_author(&self, row: Row, event: &Event, obs: &Observed<'_>) -> Result<(), Reject> {
        if let Some(sender) = obs.sender {
            require(event.pubkey == sender, row, Class::WrongAuthor)?;
        }
        require(
            self.table.is_account(&event.pubkey),
            row,
            Class::NoGroundTruth,
        )
    }

    fn own(&self, plane: Plane, author: &str, obs: &Observed<'_>) -> bool {
        self.table.current(plane, Some(author), obs.relay, obs.at)
    }

    fn event(&mut self, row: Row, event: &Event, obs: &Observed<'_>) -> Verdict {
        let (relay, at) = (obs.relay, obs.at);
        match row {
            Row::Ev445Commit | Row::Ev445Location => {
                self.ephemeral_author(row, event)?;
                let h = event
                    .tag_values("h")
                    .next()
                    .ok_or((Some(row), Class::UnknownFrame))?;
                self.circle(row, h, obs, Class::CrossedEvent)?;
                if row == Row::Ev445Commit {
                    require(
                        self.table.routing_kept(h, relay, at),
                        row,
                        Class::CrossedEvent,
                    )?;
                } else {
                    let expiration = event
                        .tag_values("expiration")
                        .next()
                        .and_then(|value| value.parse::<u64>().ok())
                        .and_then(|exp| exp.checked_sub(event.created_at));
                    require(
                        expiration.is_some_and(|ttl| ttl > 0 && ttl <= LOCATION_RETENTION_MAX_SECS),
                        row,
                        Class::UnknownFrame,
                    )?;
                    require(
                        self.table.routing_current(h, relay, at)
                            || self
                                .table
                                .routing_left_after(h, relay, at, event.created_at),
                        row,
                        Class::CrossedEvent,
                    )?;
                }
                Ok(Plane::Location)
            }
            Row::Ev1059 => {
                self.ephemeral_author(row, event)?;
                let p = event
                    .tag_values("p")
                    .next()
                    .ok_or((Some(row), Class::UnknownFrame))?;
                self.list_of(row, p, obs, (Plane::OwnInbox, Plane::InviteeInbox), false)
            }
            Row::Ev30443 => {
                self.account_author(row, event, obs)?;
                require(
                    self.table.has_list(Plane::OwnKeyPackage, &event.pubkey),
                    row,
                    Class::NoGroundTruth,
                )?;
                require(
                    self.own(Plane::OwnKeyPackage, &event.pubkey, obs),
                    row,
                    Class::CrossedEvent,
                )?;
                Ok(Plane::OwnKeyPackage)
            }
            Row::Ev10002 | Row::Ev10050 => {
                self.account_author(row, event, obs)?;
                let (own, tag) = if row == Row::Ev10002 {
                    (Plane::OwnKeyPackage, "r")
                } else {
                    (Plane::OwnInbox, "relay")
                };
                // The lookup relays carry an account's own lists too, so an
                // inviter holding only a pubkey finds them (2026-11-12).
                let plane = if self.own(own, &event.pubkey, obs) {
                    own
                } else if self.table.current(Plane::Discovery, None, relay, at) {
                    Plane::Discovery
                } else {
                    return Err((Some(row), Class::CrossedEvent));
                };
                for named in event.tag_values(tag) {
                    require(
                        !self.foreign_plane(named, &event.pubkey, at),
                        row,
                        Class::ListNamesForeignPlane,
                    )?;
                }
                Ok(plane)
            }
            Row::Ev0 => {
                self.account_author(row, event, obs)?;
                require(
                    self.table.current(Plane::Profile, None, relay, at),
                    row,
                    Class::CrossedEvent,
                )?;
                Ok(Plane::Profile)
            }
            Row::Ev5 => {
                self.account_author(row, event, obs)?;
                self.retraction(event, obs)
            }
            _ => Err(UNKNOWN),
        }
    }

    /// A relay a list names lies on another plane: it holds the location,
    /// profile or discovery role at the instant and none of the author's own
    /// lists.
    fn foreign_plane(&self, url: &str, author: &str, at: u64) -> bool {
        let Some(named) = self.table.resolve(url) else {
            return false;
        };
        let own = [Plane::OwnInbox, Plane::OwnKeyPackage]
            .into_iter()
            .any(|plane| self.table.current(plane, Some(author), named, at));
        let foreign = self.table.any_routing_current(named, at)
            || self.table.current(Plane::Profile, None, named, at)
            || self.table.current(Plane::Discovery, None, named, at);
        foreign && !own
    }

    fn retraction(&self, event: &Event, obs: &Observed<'_>) -> Verdict {
        let row = Row::Ev5;
        let mut kinds = Vec::new();
        let mut named = false;
        for value in event.tag_values("k") {
            kinds.push(
                value
                    .parse::<u16>()
                    .map_err(|_| (Some(row), Class::UnknownFrame))?,
            );
            named = true;
        }
        for value in event.tag_values("a") {
            let mut parts = value.splitn(3, ':');
            let (Some(kind), Some(pubkey), Some(d)) = (parts.next(), parts.next(), parts.next())
            else {
                return Err((Some(row), Class::UnknownFrame));
            };
            let kind = kind
                .parse::<u16>()
                .map_err(|_| (Some(row), Class::UnknownFrame))?;
            require(
                pubkey == event.pubkey && (kind == 30443) != d.is_empty(),
                row,
                Class::UnknownFrame,
            )?;
            kinds.push(kind);
            named = true;
        }
        require(named, row, Class::UnknownFrame)?;
        for id in event.tag_values("e") {
            let (kind, _) = self
                .table
                .event(id)
                .ok_or((Some(row), Class::UnresolvedId))?;
            kinds.push(kind);
        }
        let author = Some(event.pubkey.as_str());
        let (relay, at) = (obs.relay, obs.at);
        let own_or_former = |plane| {
            self.table.current(plane, author, relay, at)
                || self.table.former(plane, author, relay, at)
        };
        let mut first = None;
        for kind in kinds {
            let plane = match kind {
                0 if self.table.current(Plane::Profile, None, relay, at) => Plane::Profile,
                10050 if own_or_former(Plane::OwnInbox) => Plane::OwnInbox,
                10002 if own_or_former(Plane::OwnKeyPackage) => Plane::OwnKeyPackage,
                10050 | 10002 if self.table.current(Plane::Discovery, None, relay, at) => {
                    Plane::Discovery
                }
                30443 if self.table.current(Plane::OwnKeyPackage, author, relay, at) => {
                    Plane::OwnKeyPackage
                }
                _ => return Err((Some(row), Class::CrossedEvent)),
            };
            first.get_or_insert(plane);
        }
        first.ok_or((Some(row), Class::UnknownFrame))
    }

    /// `relay` is on `pubkey`'s list of the `(own, invitee)` pair: an
    /// account's own list (current for its own read, ever named for anyone
    /// else's use, whose targets were frozen when chosen), else the invitee's
    /// list as the inviter learnt it.
    fn list_of(
        &self,
        row: Row,
        pubkey: &str,
        obs: &Observed<'_>,
        (own, invitee): (Plane, Plane),
        own_read: bool,
    ) -> Verdict {
        let (relay, at) = (obs.relay, obs.at);
        let owner = Some(pubkey);
        let own_held = if own_read {
            self.table.current(own, owner, relay, at)
        } else {
            self.table.known(own, owner, relay, at)
        };
        if own_held {
            return Ok(own);
        }
        // An own read binds to the account's own list alone once it has one: an
        // invitee view naming a relay the account has since dropped (FORMER)
        // must not readmit it.
        let own_list = self.table.has_list(own, pubkey);
        if !(own_read && own_list) && self.table.known(invitee, owner, relay, at) {
            return Ok(invitee);
        }
        let crossed = if obs.frame.verb() == Verb::Event {
            Class::CrossedEvent
        } else {
            Class::CrossedRequest
        };
        let any = own_list || self.table.has_list(invitee, pubkey);
        Err((Some(row), if any { crossed } else { Class::NoGroundTruth }))
    }

    fn filter(&self, row: Row, filter: &Filter, obs: &Observed<'_>) -> Verdict {
        let spec = row.spec();
        let limit_ok = match spec.limit {
            Limit::Any => true,
            Limit::AtMost(max) => filter.limit.is_none_or(|limit| limit <= max),
            Limit::IdsLen => {
                let ids = filter.ids.as_ref().map_or(0, Vec::len);
                filter
                    .limit
                    .is_some_and(|limit| usize::try_from(limit).is_ok_and(|l| l == ids))
            }
        };
        require(limit_ok, row, Class::UnknownFrame)?;
        let (relay, at) = (obs.relay, obs.at);
        let crossed = Class::CrossedRequest;
        match row {
            Row::Req445H | Row::Neg445H => {
                let hs = filter.h.as_deref().unwrap_or_default();
                require(
                    !hs.is_empty() && (row == Row::Req445H || hs.len() == 1),
                    row,
                    Class::UnknownFrame,
                )?;
                for h in hs {
                    self.circle(row, h, obs, crossed)?;
                    require(self.table.routing_standing(h, relay, at), row, crossed)?;
                }
                Ok(Plane::Location)
            }
            Row::Req445Ids => {
                let ids = filter.ids.as_deref().unwrap_or_default();
                require(!ids.is_empty(), row, Class::UnknownFrame)?;
                let mut hs: Vec<&str> = filter.h.iter().flatten().map(String::as_str).collect();
                for id in ids {
                    let (kind, h) = self
                        .table
                        .event(id)
                        .ok_or((Some(row), Class::UnresolvedId))?;
                    let h = h.filter(|_| kind == 445).ok_or((Some(row), crossed))?;
                    hs.push(h);
                }
                for h in hs {
                    self.circle(row, h, obs, crossed)?;
                    require(self.table.routing_kept(h, relay, at), row, crossed)?;
                }
                Ok(Plane::Location)
            }
            Row::Req1059P => {
                let p = one(filter.p.as_ref()).ok_or((Some(row), Class::UnknownFrame))?;
                if let Some(sender) = obs.sender {
                    require(p == sender, row, crossed)?;
                }
                self.list_of(row, p, obs, (Plane::OwnInbox, Plane::InviteeInbox), true)
            }
            Row::Req30443A | Row::Req10002A | Row::Req10050A => self.lookup(row, filter, obs),
            Row::Req0A => {
                one(filter.authors.as_ref()).ok_or((Some(row), Class::UnknownFrame))?;
                require(
                    self.table.current(Plane::Profile, None, relay, at),
                    row,
                    crossed,
                )?;
                Ok(Plane::Profile)
            }
            _ => Err(UNKNOWN),
        }
    }

    fn lookup(&self, row: Row, filter: &Filter, obs: &Observed<'_>) -> Verdict {
        let author = one(filter.authors.as_ref()).ok_or((Some(row), Class::UnknownFrame))?;
        let lists = if row == Row::Req10050A {
            (Plane::OwnInbox, Plane::InviteeInbox)
        } else {
            (Plane::OwnKeyPackage, Plane::InviteeNip65Write)
        };
        match obs.sender {
            Some(sender) if sender == author => {
                require(self.table.is_account(author), row, Class::NoGroundTruth)?;
                if self.own(lists.0, author, obs) {
                    return Ok(lists.0);
                }
                // An account's own lists are kept on the lookup relays too, and
                // asked there for the heal; its key package never is.
                if row != Row::Req30443A
                    && self
                        .table
                        .current(Plane::Discovery, None, obs.relay, obs.at)
                {
                    return Ok(Plane::Discovery);
                }
                let class = if self.table.has_list(lists.0, author) {
                    Class::CrossedRequest
                } else {
                    Class::NoGroundTruth
                };
                Err((Some(row), class))
            }
            sender => {
                if self
                    .table
                    .current(Plane::Discovery, None, obs.relay, obs.at)
                {
                    return Ok(Plane::Discovery);
                }
                self.list_of(row, author, obs, lists, sender.is_none())
            }
        }
    }
}
