//! O7 — relay-plane containment: every frame a device sent reached only a
//! relay whose plane admits it.
//!
//! The subject is the world's cumulative plane record (`relay/ledger.rs`),
//! judged by the relay-plane judge every layer of the proof calls
//! (`haven_local_relay::planes`) against the ground truth the RIG decided:
//! which plane each relay is, each device's own lists, and every routing it
//! staged, with the instant it staged it. Nothing here waits.
//!
//! # The ground truth
//!
//! - **Location**: each circle's routing — the world's location planes and
//!   the addresses no plane serves that a change named, each its own relay —
//!   from the instant the rig staged it. A relay a change leaves stays
//!   admissible for what its circle may still send there: commits frozen to
//!   it, `#h` REQs within the prior routing's 24-hour standing
//!   (`PRIOR_ROUTING_STANDS_SECS`, longer than any soak world; the
//!   `routing_retained_epochs` half of the standing is not graded), and a
//!   location from
//!   a member that has not applied the change yet. The rig knows when that
//!   last member applies it for no member but the one that staged it, so the
//!   location rule's seal instant is unbounded here; L1a, with one sender,
//!   grades it exactly.
//! - **Account**: every device's inbox on the first account plane, its key
//!   package on the second when there are two.
//! - **Profile**: every profile plane.
//! - **Discovery**: none. A soak process points discovery at a dead port, so
//!   a frame for it is refused before it is a frame.
//!
//! A device's own and alias endpoints carry its pubkey as the sender, so the
//! per-identity bindings hold; the canonical endpoint (catch-up sweeps, the
//! rig's inbox reads) is judged with the union rules.
//!
//! # Rule 15
//!
//! The table, the frames and the judge's evidence hold pubkeys, routing ids,
//! event ids and URLs. None of them leaves this module: a finding is the rig's
//! own handles, a matrix row id and a judge class literal.

use std::collections::BTreeSet;

use haven_local_relay::planes::frame::Frame;
use haven_local_relay::planes::judge::{judge, Class, Observed};
use haven_local_relay::planes::policy::Row;
use haven_local_relay::planes::table::{List, PlaneTable, RelayIx, RelayMatch, RoutingEnd};

use crate::oracle::{Finding, Verdict};
use crate::relay::{EndpointId, PlaneFrame};
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RelayTag, RigError, SimWorld, TimelineSink};

/// A plane's role, as O7 names one it found too little traffic on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaneRole {
    /// A circle's routing.
    Location,
    /// A device's own lists.
    Account,
    /// The profile pool.
    Profile,
}

impl PlaneRole {
    /// The word a finding renders.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Location => "location",
            Self::Account => "account",
            Self::Profile => "profile",
        }
    }
}

/// One frame ready for the judge, and where it came from.
struct Seen {
    relay: RelayIx,
    plane: RelayTag,
    device: Option<DeviceTag>,
    frame: PlaneFrame,
}

/// The ground truth and the frames, built once per grading.
struct Evidence {
    table: PlaneTable,
    seen: Vec<Seen>,
    senders: Vec<(DeviceTag, String)>,
    full: Option<RelayTag>,
    roles: Vec<(RelayIx, PlaneRole)>,
}

/// Grades O7 over everything `world` recorded so far.
///
/// # Errors
///
/// [`RigError::ShapeMismatch`] if the world's own planes hold roles the
/// policy never lets one relay share: the rig built that world, so the rig is
/// broken.
pub fn plane_containment<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
) -> Result<Verdict, RigError> {
    let evidence = evidence(world);
    let sender = |device: Option<DeviceTag>| {
        device.and_then(|device| {
            evidence
                .senders
                .iter()
                .find(|(tag, _)| *tag == device)
                .map(|(_, pubkey)| pubkey.as_str())
        })
    };
    let frames: Vec<Frame> = evidence
        .seen
        .iter()
        .map(|seen| Frame::parse(&seen.frame.text))
        .collect();
    let judgement = judge(
        &evidence.table,
        evidence
            .seen
            .iter()
            .zip(&frames)
            .map(|(seen, frame)| Observed {
                relay: seen.relay,
                conn: seen.frame.conn,
                sender: sender(seen.device),
                at: seen.frame.at,
                frame,
            }),
    )
    .map_err(|_| RigError::ShapeMismatch)?;

    if let Some(found) = judgement.findings.first() {
        let seen = &evidence.seen[found.index];
        return Ok(Verdict::Failed(crossing(
            seen.plane,
            seen.device,
            found.row,
            found.class,
        )));
    }
    if let Some(relay) = evidence.full {
        return Ok(Verdict::Failed(Finding::PlaneRecordFull { relay }));
    }
    let hit = |role: PlaneRole, row: Row| {
        judgement.hits.keys().any(|(relay, hit, _)| {
            *hit == row
                && evidence
                    .roles
                    .iter()
                    .any(|(ix, plane_role)| ix == relay && *plane_role == role)
        })
    };
    let mut owed = vec![
        (PlaneRole::Location, Row::Req445H),
        (PlaneRole::Account, Row::Req1059P),
    ];
    if world.profile_exercised() {
        owed.extend([
            (PlaneRole::Profile, Row::Ev0),
            (PlaneRole::Profile, Row::Req0A),
        ]);
    }
    for (role, row) in owed {
        if !hit(role, row) {
            return Ok(Verdict::Failed(Finding::PlaneUnobserved { role }));
        }
    }
    Ok(Verdict::Holds)
}

/// How many relays of `world` hold more than one plane — advisory, for
/// `coverage.log`: an overlap is never a crossing, and containment cannot
/// grade what one relay sees across two roles.
#[must_use]
pub fn overlapping_relays<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
) -> usize {
    evidence(world).table.overlapping_relays()
}

/// The judge's finding, as the rig's own: its handles, the row's id and the
/// judge's class literal, nothing the judge's types render.
fn crossing(relay: RelayTag, device: Option<DeviceTag>, row: Option<Row>, class: Class) -> Finding {
    let row = row.map_or("-", Row::id);
    let rule = class.name();
    match class {
        Class::CrossedRequest => Finding::PlaneCrossedRequest { relay, device, row },
        Class::CrossedEvent | Class::WrongAuthor | Class::ListNamesForeignPlane => {
            Finding::PlaneCrossedEvent {
                relay,
                device,
                row,
                rule,
            }
        }
        Class::UnknownFrame
        | Class::UnresolvedId
        | Class::NoGroundTruth
        | Class::UndeclaredCircle => Finding::PlaneUnknownFrame {
            relay,
            device,
            rule,
        },
    }
}

fn evidence<R: RelayPlane, T: TimelineSink, L: LogDrain>(world: &SimWorld<R, T, L>) -> Evidence {
    let mut table = PlaneTable::new(RelayMatch::Authority);
    let mut roles = Vec::new();
    let mut planes = Vec::new();
    for (role, set) in [
        (PlaneRole::Location, world.relays()),
        (PlaneRole::Account, world.account_relays()),
        (PlaneRole::Profile, world.profile_relays()),
    ] {
        for plane in set {
            if let Some(ix) = table.add_relay(plane.url()) {
                roles.push((ix, role));
                planes.push((plane, ix));
            }
        }
    }
    let senders: Vec<(DeviceTag, String)> = world
        .devices()
        .iter()
        .map(|device| (device.tag, device.pubkey_hex()))
        .collect();
    lists(world, &mut table, &senders);
    routings(world, &mut table, &mut roles, &senders);
    let (seen, full) = frames(world, &mut table, planes);
    Evidence {
        table,
        seen,
        senders,
        full,
        roles,
    }
}

/// The relay `url` names, registered as one of its own when nothing else is.
fn ix_of(table: &mut PlaneTable, url: &str) -> Option<RelayIx> {
    table.resolve(url).or_else(|| table.add_relay(url))
}

/// Every device's own lists, and the profile pool.
fn lists<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    table: &mut PlaneTable,
    senders: &[(DeviceTag, String)],
) {
    let account = world.account_relays();
    let inbox = account.first().and_then(|plane| table.resolve(plane.url()));
    let key_package = account
        .get(1)
        .or_else(|| account.first())
        .and_then(|plane| table.resolve(plane.url()));
    for (_, pubkey) in senders {
        table.add_account(pubkey);
        if let Some(inbox) = inbox {
            table.add(List::OwnInbox(pubkey), inbox, 0);
        }
        if let Some(key_package) = key_package {
            table.add(List::OwnKeyPackage(pubkey), key_package, 0);
        }
    }
    for plane in world.profile_relays() {
        if let Some(ix) = table.resolve(plane.url()) {
            table.add(List::Profile, ix, 0);
        }
    }
}

/// Every routing the rig decided, every device a member of each, and every
/// relay a routing named a location one.
fn routings<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    table: &mut PlaneTable,
    roles: &mut Vec<(RelayIx, PlaneRole)>,
    senders: &[(DeviceTag, String)],
) {
    let history = world.routing_history();
    let circles: BTreeSet<&str> = history.iter().map(|span| span.h.as_str()).collect();
    // Every circle the rig builds holds every device; a circle built over a
    // subset must name its own members here, or the membership binding is
    // vacuous for it.
    for h in circles {
        for (_, pubkey) in senders {
            table.add_member(h, pubkey, 0);
        }
    }
    for span in &history {
        let Some(ix) = ix_of(table, &span.relay) else {
            continue;
        };
        table.add_routing(&span.h, ix, span.added);
        if let Some(removed) = span.removed {
            table.retire_routing(
                &span.h,
                ix,
                RoutingEnd {
                    removed,
                    stands_until: None,
                    kept_until: None,
                    left_at_secs: Some(u64::MAX),
                },
            );
        }
        if !roles.iter().any(|(known, _)| *known == ix) {
            roles.push((ix, PlaneRole::Location));
        }
    }
}

/// Every plane's recorded frames, each on the relay it was sent to — an alias
/// endpoint's on the address its slot stands for — in arrival order, with the
/// plane's indexed events, and the first plane whose record is full.
fn frames<R: RelayPlane, T: TimelineSink, L: LogDrain>(
    world: &SimWorld<R, T, L>,
    table: &mut PlaneTable,
    planes: Vec<(&R, RelayIx)>,
) -> (Vec<Seen>, Option<RelayTag>) {
    let mut seen = Vec::new();
    let mut full = None;
    for (plane, ix) in planes {
        let Some(ledger) = plane.plane_ledger() else {
            continue;
        };
        let record = ledger.plane_record();
        if record.full && full.is_none() {
            full = Some(plane.tag());
        }
        for (id, kind, h) in &record.events {
            table.index_event(id, *kind, h.as_deref());
        }
        for frame in record.frames {
            let relay = match frame.endpoint {
                EndpointId::Canonical | EndpointId::Own(_) => Some(ix),
                EndpointId::Alias(device, slot) => world
                    .device(device)
                    .ok()
                    .and_then(|owner| owner.alias_address(slot))
                    .or_else(|| plane.alias_urls_for(device).get(usize::from(slot)).cloned())
                    .and_then(|address| ix_of(table, &address)),
            };
            if let Some(relay) = relay {
                seen.push(Seen {
                    relay,
                    plane: plane.tag(),
                    device: frame.endpoint.device(),
                    frame,
                });
            }
        }
    }
    seen.sort_by_key(|seen| seen.frame.at);
    (seen, full)
}

#[cfg(test)]
mod tests {
    use super::*;
    use haven_local_relay::planes::judge::Class;

    #[test]
    fn every_judge_class_maps_to_an_o7_finding_that_renders_handles_and_literals() {
        let relay = RelayTag::new(3);
        let device = Some(DeviceTag::new(1));
        let expected = [
            (Class::CrossedEvent, "plane-crossed-event"),
            (Class::CrossedRequest, "plane-crossed-request"),
            (Class::UnknownFrame, "plane-unknown-frame"),
            (Class::WrongAuthor, "plane-crossed-event"),
            (Class::ListNamesForeignPlane, "plane-crossed-event"),
            (Class::UnresolvedId, "plane-unknown-frame"),
            (Class::NoGroundTruth, "plane-unknown-frame"),
            (Class::UndeclaredCircle, "plane-unknown-frame"),
        ];
        for (class, o7) in expected {
            let finding = crossing(relay, device, Some(Row::Ev0), class);
            assert_eq!(finding.class(), o7);
            assert_eq!(finding.rc(), crate::rc::Rc::ViolationOrLeak);
            assert_eq!(finding.handles(), vec!["simrelay#3", "simdev#1"]);
        }
        assert!(
            crossing(relay, None, None, Class::CrossedRequest)
                .to_string()
                .contains("simrelay#3"),
            "a canonical-endpoint frame names the plane alone"
        );
    }

    #[test]
    fn a_role_renders_one_fixed_word() {
        for (role, word) in [
            (PlaneRole::Location, "location"),
            (PlaneRole::Account, "account"),
            (PlaneRole::Profile, "profile"),
        ] {
            assert_eq!(role.label(), word);
            assert_eq!(
                Finding::PlaneUnobserved { role }.rc(),
                crate::rc::Rc::ProvesTooLittle
            );
        }
    }
}
