//! Building a real circle, and the one Rule-13 publish path the rig has.
//!
//! # Rule 13 is structural here
//!
//! `create_circle` stages the group and hands back gift-wrapped welcomes plus a
//! `PendingStateRef`; the group only becomes real when that ref is confirmed.
//! haven-core's own doc is unambiguous that "acked" means a relay returned
//! `OK` — never merely "sent" — so the rig confirms only after a relay plane's
//! client-facing stream witnessed one, and rolls back otherwise. There is
//! exactly one function in this crate that resolves a pending state
//! ([`publish_and_resolve`]), which is what makes the invariant checkable by
//! reading rather than by hoping.

use std::fmt;
use std::sync::atomic::AtomicUsize;
use std::sync::Arc;
use std::time::Duration;

use haven_core::circle::{CircleConfig, MemberKeyPackage};
use haven_core::nostr::mls::types::{GroupId, PendingStateRef};
use haven_core::relay::live_sync::CircleSpec;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use nostr::{Event, TagKind};

use crate::rig::plane::RelayPlane;
use crate::rig::world::PendingGuard;
use crate::rig::{poll_until, sim_magnitude, CircleTag, DeviceTag, RigError, SimDevice, Step};

/// How long a publish waits for a relay plane to witness its `OK`.
///
/// The publish call has already awaited the relay's acknowledgement itself, so
/// this bounds only the plane ledger's own observation lag. It is a harness
/// bound, not a product one: no scenario EXPECTATION is derived from it — but
/// a scenario that deliberately withholds an ack (S18) pays it in full per
/// publish, so an arm's DEADLINE must price it, which is why it is public.
pub const WITNESS_BOUND: Duration = Duration::from_secs(10);

/// How often the witness condition is re-read.
const WITNESS_POLL: Duration = Duration::from_millis(20);

/// How a staged commit was resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PublishVerdict {
    /// A relay witnessed the `OK`, so the staged state was confirmed and the
    /// epoch may advance.
    Confirmed,
    /// No relay witnessed an `OK`, so the staged state was rolled back. The
    /// epoch MUST NOT have advanced.
    RolledBack,
}

impl PublishVerdict {
    /// The literal the timeline records.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Confirmed => "confirmed",
            Self::RolledBack => "rolled-back",
        }
    }
}

/// One circle in the world.
pub struct SimCircle {
    /// This circle's handle.
    pub tag: CircleTag,
    name: String,
    mls_group_id: GroupId,
    nostr_group_id: [u8; 32],
    group_id_hex: String,
    admin: DeviceTag,
    members: Vec<DeviceTag>,
    origin_epoch: u64,
}

impl SimCircle {
    /// The circle's name, as the MLS group data carries it.
    ///
    /// Kept so the run can DECLARE it to the needle manifest: a circle name is
    /// an identifier, and a value the rig minted but never declared is one the
    /// scanner cannot search for.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The real MLS group id. Never published, never rendered (Rule 4).
    #[must_use]
    pub const fn mls_group_id(&self) -> &GroupId {
        &self.mls_group_id
    }

    /// The pseudonymous routing id.
    #[must_use]
    pub const fn nostr_group_id(&self) -> &[u8; 32] {
        &self.nostr_group_id
    }

    /// The routing id as the `#h` tag spells it.
    #[must_use]
    pub fn group_id_hex(&self) -> &str {
        &self.group_id_hex
    }

    /// The device that created the circle.
    #[must_use]
    pub const fn admin(&self) -> DeviceTag {
        self.admin
    }

    /// Every member, admin included.
    #[must_use]
    pub fn members(&self) -> &[DeviceTag] {
        &self.members
    }

    /// The epoch the circle started at. Every epoch the rig renders is a delta
    /// from this, because an absolute epoch is an identifier.
    #[must_use]
    pub const fn origin_epoch(&self) -> u64 {
        self.origin_epoch
    }

    /// The subscription spec for this circle over `relays`.
    #[must_use]
    pub fn spec(&self, relays: &[String]) -> CircleSpec {
        CircleSpec {
            group_id_hex: self.group_id_hex.clone(),
            relays: relays.to_vec(),
        }
    }
}

// Presence-only: both group ids and the roster are identifiers.
impl fmt::Debug for SimCircle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SimCircle")
            .field("tag", &self.tag)
            .field("admin", &self.admin)
            .field("members", &sim_magnitude(self.members.len()))
            .finish_non_exhaustive()
    }
}

/// Whether `event` is an application message, which production publishes
/// through its own plane.
///
/// The discriminator is the wire's own and the product's: the engine stamps a
/// NIP-40 `expiration` on kind-445 APPLICATION messages and never on a commit
/// or a proposal (`haven-core/src/nostr/mls/manager.rs`, the
/// `message-retention.v1` component), and a welcome is a kind-1059 gift wrap
/// with no expiration at all. Reading the tag rather than asking the caller is
/// what keeps the two planes from diverging: whatever the rig publishes, it
/// goes out the way production would send it.
fn is_application_message(event: &Event) -> bool {
    event.tags.find(TagKind::Expiration).is_some()
}

/// Publishes `events` and waits, bounded, for a relay plane to witness an `OK`
/// for at least one of them.
///
/// A publish that errors is NOT an error here: an unreachable relay is the
/// commonest thing a schedule asks for, and the caller's question is only ever
/// "was it acked", which the witness answers.
///
/// # Errors
///
/// [`RigError`] only if the witness condition itself could not be read.
pub async fn publish_witnessed<R: RelayPlane>(
    device: &SimDevice,
    relays: &[R],
    events: &[Event],
) -> Result<Option<Duration>, RigError> {
    let urls: Vec<String> = relays.iter().map(|r| r.url().to_string()).collect();
    for event in events {
        // The publish plane is haven-core's own, and so is the CHOICE of
        // ladder: a location takes `publish_location_event`'s single bounded
        // attempt and a commit or a welcome takes `publish_event`'s retrying
        // one (Security Rule 13). Sending every probe down the commit ladder
        // would measure O1 against a publish path the product does not have.
        let _ = if is_application_message(event) {
            device.relays.publish_location_event(event, &urls).await
        } else {
            device.relays.publish_event(event, &urls).await
        };
    }
    poll_until(WITNESS_BOUND, WITNESS_POLL, || async {
        Ok(events
            .iter()
            .any(|event| relays.iter().any(|relay| relay.witnessed_ok(&event.id))))
    })
    .await
}

/// Publishes `events` and resolves `pending` on the outcome: confirm on a
/// witnessed ack, roll back otherwise.
///
/// The latency is the witness measurement, and it is `None` on the rollback
/// path because there was nothing to measure: reporting the bound the wait
/// spent would put a constant of this module's choosing where a reader reads a
/// duration the world took.
///
/// # Errors
///
/// [`RigError::Core`] if haven-core refuses the confirm or the rollback — a
/// pending that is neither confirmed nor rolled back forks the group, so it is
/// never left dangling.
pub async fn publish_and_resolve<R: RelayPlane>(
    device: &SimDevice,
    relays: &[R],
    pending: PendingStateRef,
    events: &[Event],
) -> Result<(PublishVerdict, Option<Duration>), RigError> {
    let witnessed = publish_witnessed(device, relays, events).await?;
    let manager = device.manager()?;
    if let Some(latency) = witnessed {
        manager
            .confirm_published(pending)
            .await
            .map_err(|_| RigError::Core(Step::ConfirmPublished))?;
        Ok((PublishVerdict::Confirmed, Some(latency)))
    } else {
        manager
            .publish_failed(pending)
            .await
            .map_err(|_| RigError::Core(Step::RollBackPublish))?;
        Ok((PublishVerdict::RolledBack, None))
    }
}

/// Creates one circle: the admin device invites every other device, the
/// welcomes are published, the pending state is resolved per Rule 13, and each
/// member joins from its own welcome.
///
/// `outstanding` is the world's staged-commit counter, held for exactly as long
/// as the create's own `PendingStateRef` is unresolved. A create is a staged
/// commit like any other — the one a world builds an extra circle with runs
/// while the quiescence predicate is reading — and a counter that ignored it
/// would let the world call itself settled with an unpublished commit staged.
///
/// # Errors
///
/// [`RigError::WelcomeNeverAcked`] if no welcome was ever acked (the create is
/// rolled back first), or [`RigError::Core`] naming the step that failed.
pub async fn build_circle<R: RelayPlane>(
    tag: CircleTag,
    devices: &[SimDevice],
    relays: &[R],
    urls: &[String],
    outstanding: &Arc<AtomicUsize>,
) -> Result<SimCircle, RigError> {
    let (admin, invited) = devices.split_first().ok_or(RigError::ShapeMismatch)?;

    let mut members = Vec::with_capacity(invited.len());
    for device in invited {
        let kp = build_kp_maintenance_events(device.session()?, &device.keys, urls, None, None)
            .await
            .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
        members.push(MemberKeyPackage {
            key_package_event: kp.event,
            // Explicit, always: an empty relay set falls back to the PRODUCTION
            // default pool, which would take the world off its own relay and
            // onto the public network.
            inbox_relays: urls.to_vec(),
            nip65_relays: Vec::new(),
        });
    }

    // Deliberately not a rig handle: if a circle name ever reached a log, a
    // name that looked like `simcircle#0` would be indistinguishable from the
    // sanctioned handle and the leak would be invisible.
    let name = format!("soak-circle-{}", tag.ordinal());
    let config = CircleConfig::new(&name).with_relays(urls.to_vec());
    let result = admin
        .manager()?
        .create_circle(&admin.keys, members, &config, urls)
        .await
        .map_err(|_| RigError::Core(Step::CreateCircle))?;

    let mls_group_id = result.circle.mls_group_id.clone();
    let nostr_group_id = result.circle.nostr_group_id;
    let welcomes: Vec<Event> = result
        .welcome_events
        .iter()
        .map(|welcome| welcome.event.clone())
        .collect();

    let staged = PendingGuard::staged(outstanding);
    let (verdict, _) = publish_and_resolve(admin, relays, result.pending, &welcomes).await?;
    drop(staged);
    if verdict == PublishVerdict::RolledBack {
        return Err(RigError::WelcomeNeverAcked);
    }

    for welcome in &result.welcome_events {
        let member = devices
            .iter()
            .find(|device| device.pubkey_hex() == welcome.recipient_pubkey)
            .ok_or(RigError::UnknownTarget)?;
        member
            .manager()?
            .process_gift_wrapped_invitation(&member.keys, &welcome.event)
            .await
            .map_err(|_| RigError::Core(Step::ProcessInvitation))?;
        member
            .manager()?
            .accept_invitation(&welcome.event.id)
            .await
            .map_err(|_| RigError::Core(Step::AcceptInvitation))?;
    }

    let origin_epoch = admin
        .manager()?
        .group_epoch(&mls_group_id)
        .await
        .map_err(|_| RigError::Core(Step::ReadEpoch))?;

    Ok(SimCircle {
        tag,
        name,
        group_id_hex: hex::encode(nostr_group_id),
        mls_group_id,
        nostr_group_id,
        admin: admin.tag,
        members: devices.iter().map(|device| device.tag).collect(),
        origin_epoch,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rig::doubles::TestRelay;
    use crate::rig::{install_process_globals, RelayTag};
    use haven_core::nostr::mls::types::GroupId;
    use std::sync::atomic::Ordering;

    fn needle_circle() -> SimCircle {
        let nostr_group_id = [0xCD_u8; 32];
        SimCircle {
            tag: CircleTag::new(2),
            name: "soak-circle-2".to_owned(),
            mls_group_id: GroupId::new(vec![0xAB; 32]),
            nostr_group_id,
            group_id_hex: hex::encode(nostr_group_id),
            admin: DeviceTag::new(0),
            members: vec![DeviceTag::new(0), DeviceTag::new(1)],
            origin_epoch: 41,
        }
    }

    #[test]
    fn a_circles_debug_renders_handles_and_neither_group_id() {
        let circle = needle_circle();
        let rendered = format!("{circle:?}");
        assert!(rendered.contains("simcircle#2"), "{rendered}");
        assert!(rendered.contains("simdev#0"), "{rendered}");
        assert!(!rendered.contains("abab"), "{rendered}");
        assert!(!rendered.contains("cdcd"), "{rendered}");
        assert!(!rendered.contains("epoch"), "{rendered}");
        assert!(!rendered.contains("41"), "{rendered}");
        assert!(
            !rendered.contains(circle.name()),
            "a circle name is an identifier: {rendered}"
        );
    }

    #[test]
    fn a_spec_carries_the_routing_id_and_never_the_mls_one() {
        let circle = needle_circle();
        let spec = circle.spec(&["ws://127.0.0.1:1".to_string()]);
        assert_eq!(spec.group_id_hex, hex::encode([0xCD_u8; 32]));
        assert_ne!(spec.group_id_hex, hex::encode([0xAB_u8; 32]));
        assert_eq!(spec.relays.len(), 1);
        assert_eq!(circle.origin_epoch(), 41);
        assert_eq!(circle.admin(), DeviceTag::new(0));
        assert_eq!(circle.members().len(), 2);
        assert_eq!(circle.nostr_group_id(), &[0xCD_u8; 32]);
        assert_eq!(circle.mls_group_id().as_slice(), &[0xAB_u8; 32]);
    }

    #[test]
    fn a_publish_verdict_is_a_literal() {
        assert_eq!(PublishVerdict::Confirmed.label(), "confirmed");
        assert_eq!(PublishVerdict::RolledBack.label(), "rolled-back");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_create_is_counted_as_a_staged_commit_until_it_resolves() {
        install_process_globals().expect("the loopback opt-in installs");
        let outstanding = Arc::new(AtomicUsize::new(0));
        // The plane samples the counter as it is consulted, which happens
        // inside the create's own publish — the only window in which the count
        // is non-zero, and one no second task could observe without racing it.
        let relay = TestRelay::start_watching(RelayTag::new(0), Arc::clone(&outstanding)).await;
        let urls = vec![relay.url().to_string()];
        let devices = vec![
            SimDevice::open(DeviceTag::new(0), &urls).expect("alice opens"),
            SimDevice::open(DeviceTag::new(1), &urls).expect("bob opens"),
        ];

        let circle = build_circle(
            CircleTag::new(0),
            &devices,
            std::slice::from_ref(&relay),
            &urls,
            &outstanding,
        )
        .await
        .expect("the circle is created");

        assert_eq!(circle.members().len(), devices.len());
        assert!(
            relay.observed().iter().any(|&staged| staged >= 1),
            "a create stages a commit, and quiescence must not be able to hold while one is \
             unresolved"
        );
        assert_eq!(
            outstanding.load(Ordering::Acquire),
            0,
            "the create resolved its own staged commit"
        );
    }
}
