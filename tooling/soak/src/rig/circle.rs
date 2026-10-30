//! Building a real circle, and the one publish path the rig has: the
//! product's own driver.
//!
//! # Rule 13 is the product's here
//!
//! Every commit the rig makes is staged and sent by haven-core's durable-fanout
//! driver (`haven_core::relay::fanout::Publishing`), the same entries the app
//! calls: the commit is recorded before a byte leaves the device, confirmed on a
//! relay's `OK`, rolled back only when every relay proved it refused, and kept
//! pending — and sent again, byte for byte, on its relays' schedule — when
//! nothing is proven. The rig resolves no pending state itself. [`DeviceDriver`]
//! is one device's driver; what it sent is read back off its transport, never
//! re-derived.

use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::time::Duration;

use haven_core::circle::{CircleConfig, MemberKeyPackage};
use haven_core::nostr::mls::types::{GroupId, TransportMessage};
use haven_core::nostr::mls::SessionManager;
use haven_core::relay::fanout::UnrecordedPublisher;
use haven_core::relay::fanout::{
    Claimed, EvolutionStatus, FanoutClock, FanoutSend, FanoutTargetOutcome, Publishing,
    RelayMappedFanout, Taken, RESUME_BUDGET_MS,
};
use haven_core::relay::live_sync::CircleSpec;
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::{FanoutTransport, PublishResult, RelayManager, RelayResult};
use nostr::Event;

use crate::nemesis::types::DropClass;
use crate::rig::plane::RelayPlane;
use crate::rig::{poll_until, sim_magnitude, CircleTag, DeviceTag, RigError, SimDevice, Step};

/// How long a publish waits for a relay plane to witness its `OK`.
///
/// The publish call has already awaited the relay's acknowledgement itself, so
/// this bounds only the plane ledger's own observation lag. It is a harness
/// bound, not a product one: no scenario EXPECTATION is derived from it — but
/// a scenario that deliberately withholds an ack pays it in full per publish,
/// so an arm's DEADLINE must price it, which is why it is public.
pub const WITNESS_BOUND: Duration = Duration::from_secs(10);

/// How often the witness condition is re-read.
const WITNESS_POLL: Duration = Duration::from_millis(20);

/// How often, and for how long each time, an invitee's inbox is read for a
/// Welcome another drive delivered.
const INBOX_POLL: Duration = Duration::from_millis(500);

/// Where a change the product's driver made stands when its call returns: the
/// driver's own answer ([`EvolutionStatus`]), one for one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PublishVerdict {
    /// A relay acknowledged the commit and the engine applied it.
    Confirmed,
    /// The circle already was as the change asks: nothing was staged.
    AlreadySo,
    /// Recorded and sent, and no relay acknowledged it yet: it stays pending
    /// and is sent again on its relays' schedule.
    Unresolved,
    /// Every relay proved it refused the commit and none may hold it: the
    /// engine discarded it. The epoch MUST NOT have advanced.
    RolledBack,
    /// The engine queued the change behind what the circle is resolving.
    Queued,
    /// The engine set the commit aside by a path of its own.
    Stale,
    /// Staged and neither recordable nor undoable; never sent.
    Unrecorded,
}

impl PublishVerdict {
    /// The literal the timeline records.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Confirmed => "confirmed",
            Self::AlreadySo => "already-so",
            Self::Unresolved => "unresolved",
            Self::RolledBack => "rolled-back",
            Self::Queued => "queued",
            Self::Stale => "stale",
            Self::Unrecorded => "unrecorded",
        }
    }

    /// Every verdict, for the tests that hold the timeline's vocabulary.
    pub const ALL: [Self; 7] = [
        Self::Confirmed,
        Self::AlreadySo,
        Self::Unresolved,
        Self::RolledBack,
        Self::Queued,
        Self::Stale,
        Self::Unrecorded,
    ];
}

impl From<EvolutionStatus> for PublishVerdict {
    fn from(status: EvolutionStatus) -> Self {
        match status {
            EvolutionStatus::Confirmed => Self::Confirmed,
            EvolutionStatus::AlreadySo => Self::AlreadySo,
            EvolutionStatus::Unresolved => Self::Unresolved,
            EvolutionStatus::RolledBack => Self::RolledBack,
            EvolutionStatus::Queued => Self::Queued,
            EvolutionStatus::Stale => Self::Stale,
            EvolutionStatus::Unrecorded => Self::Unrecorded,
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

    /// The subscription spec `device`'s ENGINE takes for this circle: the same
    /// routing id over the device's own endpoint on every plane.
    ///
    /// Per (device, circle), and the only place the engine's endpoint is
    /// chosen — nothing here reaches storage, which keeps the canonical
    /// endpoint (see [`build_circle`]).
    #[must_use]
    pub fn spec_for<R: RelayPlane>(&self, device: DeviceTag, relays: &[R]) -> CircleSpec {
        let urls: Vec<String> = relays
            .iter()
            .map(|relay| relay.url_for(device).to_owned())
            .collect();
        self.spec(&urls)
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

/// Publishes `events` from `device`'s own endpoint on every plane and waits,
/// bounded, for a relay plane to witness an `OK` for at least one of them.
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
    let urls: Vec<String> = relays
        .iter()
        .map(|relay| relay.url_for(device.tag).to_owned())
        .collect();
    for event in events {
        // The publish plane is haven-core's own, and so is the CHOICE of
        // ladder: a location takes `publish_location_event`'s single bounded
        // attempt and a commit or a welcome takes `publish_event`'s retrying
        // one (Security Rule 13). Sending every probe down the commit ladder
        // would measure O1 against a publish path the product does not have.
        // The class is read off the wire by the same discriminator the proxy
        // drops by, so whatever the rig publishes goes out the way production
        // would send it.
        let _ = if DropClass::of(event) == Some(DropClass::Application) {
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

/// The fanout driver's pacing clock: the wall, plus a scenario's steps.
///
/// A POLICY clock: it decides only whether a relay's wait has passed, and is
/// compared with nothing a relay or a peer produced.
#[derive(Default)]
pub struct PacingClock {
    ahead_ms: std::sync::atomic::AtomicU64,
}

impl PacingClock {
    /// Steps the clock `ms` further ahead of the wall.
    pub fn step(&self, ms: u64) {
        self.ahead_ms
            .fetch_add(ms, std::sync::atomic::Ordering::AcqRel);
    }
}

impl FanoutClock for PacingClock {
    fn now_ms(&self) -> u64 {
        haven_core::relay::fanout::WallClock
            .now_ms()
            .saturating_add(self.ahead_ms.load(std::sync::atomic::Ordering::Acquire))
    }
}

/// The product's durable-fanout transport, recording every event it is asked
/// to send.
///
/// A pass-through: every call goes to the product's own transport unchanged,
/// and the record is the frozen event the driver handed it — read back, never
/// re-derived from what the rig asked for.
pub struct Recording<T> {
    inner: T,
    sent: Mutex<Vec<Event>>,
}

impl<T> Recording<T> {
    /// Records what `inner` is asked to send.
    pub const fn new(inner: T) -> Self {
        Self {
            inner,
            sent: Mutex::new(Vec::new()),
        }
    }

    fn note(&self, event: Event) {
        let mut sent = self
            .sent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !sent.iter().any(|seen| seen.id == event.id) {
            sent.push(event);
        }
    }

    /// Every distinct event sent so far, first sent first.
    #[must_use]
    pub fn sent(&self) -> Vec<Event> {
        self.sent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

#[async_trait::async_trait]
impl<T: FanoutSend> FanoutSend for Recording<T> {
    async fn take(&self, target: &str) -> Option<Taken> {
        self.inner.take(target).await
    }

    async fn publish(
        &self,
        target: &str,
        message: &TransportMessage,
        taken: Taken,
    ) -> FanoutTargetOutcome {
        if let Ok(event) = SessionManager::transport_message_to_event(message) {
            self.note(event);
        }
        self.inner.publish(target, message, taken).await
    }

    async fn publish_location(
        &self,
        event: &Event,
        targets: &[String],
    ) -> RelayResult<PublishResult> {
        self.note(event.clone());
        self.inner.publish_location(event, targets).await
    }
}

/// The publish ladder for what the driver sends without a record.
///
/// A Welcome, or a proposal it could not record, goes out on the device's own
/// publish plane, each stored address dialled at the device's own endpoint,
/// as the engine's own publisher is.
pub struct MappedPublisher<'a> {
    relays: &'a RelayManager,
    map: Box<dyn Fn(&str) -> String + Send + Sync + 'a>,
    sent: Mutex<Vec<Event>>,
}

impl UnrecordedPublisher for MappedPublisher<'_> {
    fn publish_unrecorded<'b>(
        &'b self,
        event: &'b Event,
        relays: &'b [String],
    ) -> Pin<Box<dyn Future<Output = bool> + Send + 'b>> {
        Box::pin(async move {
            self.sent
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(event.clone());
            let mapped: Vec<String> = relays.iter().map(|relay| (self.map)(relay)).collect();
            self.relays.publish_unrecorded(event, &mapped).await
        })
    }
}

/// One device's product driver, built as the bridge builds its own.
///
/// Its durable-fanout transport and its publisher are both on its own
/// endpoints; like `haven/rust_builder/src/api.rs` `Driving` it drives in the
/// mode its caller's word and the live plane's standing make, under a call's
/// budget.
pub struct DeviceDriver<'a> {
    transport: Recording<RelayMappedFanout<FanoutTransport>>,
    publisher: MappedPublisher<'a>,
    clock: &'a dyn FanoutClock,
    mode: Claimed<'a>,
}

impl<'a> DeviceDriver<'a> {
    /// `device`'s driver, pacing its relays on `clock`, its caller saying the
    /// app is in front of its user.
    ///
    /// # Errors
    ///
    /// [`RigError::SessionNotLive`] if the device has no manager.
    pub fn new(device: &'a SimDevice, clock: &'a dyn FanoutClock) -> Result<Self, RigError> {
        Ok(Self {
            transport: Recording::new(device.fanout_transport()),
            publisher: MappedPublisher {
                relays: &device.relays,
                map: Box::new(device.endpoint_route()),
                sent: Mutex::new(Vec::new()),
            },
            clock,
            mode: Claimed::new(device.manager()?, true),
        })
    }

    /// The product's driver over this device's planes.
    #[must_use]
    pub fn publishing(
        &self,
    ) -> haven_core::relay::fanout::Publishing<'_, Recording<RelayMappedFanout<FanoutTransport>>>
    {
        Publishing {
            fanout: &self.transport,
            publisher: &self.publisher,
            clock: self.clock,
            deadline_ms: Some(self.clock.now_ms().saturating_add(RESUME_BUDGET_MS)),
            mode: &self.mode,
        }
    }

    /// Every distinct event the driver sent under a record, first sent first.
    #[must_use]
    pub fn recorded(&self) -> Vec<Event> {
        self.transport.sent()
    }

    /// Every event the driver published without a record (Welcomes among
    /// them), first published first.
    #[must_use]
    pub fn unrecorded(&self) -> Vec<Event> {
        self.publisher
            .sent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

/// Creates one circle: the admin device invites every other device through
/// its driver's create, which sends each founding Welcome from its record,
/// and each member joins from its own welcome.
///
/// A founding create is canonical the moment it returns (MDK v0.10.4
/// `PublishWork::FoundingGroupCreated`): it stages no commit, so there is
/// nothing to confirm or roll back and nothing for the world's staged-commit
/// counter to hold.
///
/// `urls` are the planes' CANONICAL endpoints, and everything here that
/// reaches storage keeps them: `CircleConfig::with_relays`, a member's stored
/// `inbox_relays` and `create_circle`'s relay argument. haven-core's
/// `resync_circle_relays_from_mdk` rewrites the stored relay row from the
/// engine's routing component after any group update, and
/// `run_catchup_all_circles` reads its list out of storage — so a catch-up
/// sweep dials the canonical endpoint for every circle, a catch-up-plane fault
/// stays relay-global, and a scenario that partitions a device's ENGINE
/// endpoint must not run a sweep during the partition or the withheld commit
/// arrives by the other path. Only the engine — its group REQs
/// ([`SimCircle::spec_for`]), its inbox REQ (`SimDevice::open`) and its own
/// fanout drives, mapped from the stored address (`rig/address_map.rs`) — and
/// the publish plane ([`publish_witnessed`]) dial a device's own endpoint.
///
/// # Errors
///
/// [`RigError::WelcomeNeverAcked`] if no welcome was ever acked (the circle
/// exists on the admin's device and nobody else's), or [`RigError::Core`]
/// naming the step that failed.
pub async fn build_circle(
    tag: CircleTag,
    devices: &[SimDevice],
    urls: &[String],
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
    // The app's own create: each founding Welcome goes from the record the
    // create writes, through the admin's driver, to its invitee's inbox at
    // the admin's own endpoint — never published a second time, and never to
    // an address the device does not dial.
    // What each invitee's inbox already holds, while the admin's live plane
    // runs: the Welcome that plane may deliver for this create is the one
    // not among them (`take_welcome_from_inbox`).
    let mut held_before = Vec::with_capacity(invited.len());
    for device in invited {
        held_before.push(if admin.engine().is_ok() {
            Some(inbox_wraps(device, urls).await)
        } else {
            None
        });
    }
    let clock = PacingClock::default();
    let driver = DeviceDriver::new(admin, &clock)?;
    let created = driver
        .publishing()
        .create_circle(admin.manager()?, &admin.keys, members, &config)
        .await
        .map_err(|_| RigError::Core(Step::CreateCircle))?;
    let mls_group_id = created.circle.mls_group_id.clone();
    let nostr_group_id = created.circle.nostr_group_id;
    let welcomes = driver.unrecorded();
    // The admin's live plane, if it runs, may take a founding Welcome's
    // record before this create's own drive reaches it and deliver it
    // itself: this create then sent nothing for that invitee, who takes the
    // Welcome from its inbox relays as the app's invitation poll would.
    let mut joined = Vec::new();
    for (device, before) in invited.iter().zip(&held_before) {
        let sent = welcomes.iter().any(|welcome| {
            welcome
                .tags
                .public_keys()
                .any(|key| key.to_hex() == device.pubkey_hex())
        });
        let Some(before) = before.as_deref() else {
            continue;
        };
        if !sent && take_welcome_from_inbox(device, urls, &mls_group_id, before).await? {
            joined.push(device.tag);
        }
    }
    if created.welcomes_sent == 0 && joined.is_empty() {
        return Err(RigError::WelcomeNeverAcked);
    }
    for welcome in welcomes {
        let Some(recipient) = welcome
            .tags
            .public_keys()
            .next()
            .map(nostr::PublicKey::to_hex)
        else {
            return Err(RigError::UnknownTarget);
        };
        let member = devices
            .iter()
            .find(|device| device.pubkey_hex() == recipient)
            .ok_or(RigError::UnknownTarget)?;
        member
            .manager()?
            .process_gift_wrapped_invitation(&member.keys, &welcome)
            .await
            .map_err(|_| RigError::Core(Step::ProcessInvitation))?;
        member
            .manager()?
            .accept_invitation(&welcome.id)
            .await
            .map_err(|_| RigError::Core(Step::AcceptInvitation))?;
    }

    // Each joiner makes the one post-join self-update MDK recorded at its
    // join, through the product's full resume, and every device takes it in
    // before any scenario measures anything: a joiner's first caught-up
    // foreground drive would otherwise make it in the middle of one.
    for joiner in invited {
        settle_post_join(joiner, devices, &mls_group_id).await?;
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

/// The gift wraps `urls` hold for `device`, by id.
async fn inbox_wraps(device: &SimDevice, urls: &[String]) -> Vec<nostr::EventId> {
    let filter = nostr::Filter::new()
        .kind(nostr::Kind::GiftWrap)
        .pubkey(device.keys.public_key());
    device
        .relays
        .fetch_events(filter, urls, Some(INBOX_POLL))
        .await
        .map(|wraps| wraps.into_iter().map(|wrap| wrap.id).collect())
        .unwrap_or_default()
}

/// Fetches `device`'s gift wraps from `urls` until one that was not among
/// `before` arrives, and accepts it: whether that joined it to `group`
/// within [`WITNESS_BOUND`]. One that founds another circle means the rig
/// lost track of its own creates.
async fn take_welcome_from_inbox(
    device: &SimDevice,
    urls: &[String],
    group: &GroupId,
    before: &[nostr::EventId],
) -> Result<bool, RigError> {
    let filter = nostr::Filter::new()
        .kind(nostr::Kind::GiftWrap)
        .pubkey(device.keys.public_key());
    let manager = device.manager()?;
    let found = poll_until(WITNESS_BOUND, INBOX_POLL, || async {
        let wraps = device
            .relays
            .fetch_events(filter.clone(), urls, Some(INBOX_POLL))
            .await
            .unwrap_or_default();
        let Some(wrap) = wraps.into_iter().find(|wrap| !before.contains(&wrap.id)) else {
            return Ok(false);
        };
        manager
            .process_gift_wrapped_invitation(&device.keys, &wrap)
            .await
            .map_err(|_| RigError::Core(Step::ProcessInvitation))?;
        let joined = manager
            .accept_invitation(&wrap.id)
            .await
            .map_err(|_| RigError::Core(Step::AcceptInvitation))?;
        if joined.circle.mls_group_id == *group {
            Ok(true)
        } else {
            Err(RigError::UnknownTarget)
        }
    })
    .await?;
    Ok(found.is_some())
}

/// Drives `joiner`'s post-join self-update to an acknowledgement on a
/// transport that stores nothing and has every other device take it in. MDK's windows — a 15 s grace after
/// the end of stored events, 60 s of quiet, a jitter of up to 30 s — are
/// served on the session's injectable clock, put a day ahead of the device's
/// for the drive and given back after it.
async fn settle_post_join(
    joiner: &SimDevice,
    devices: &[SimDevice],
    group: &GroupId,
) -> Result<(), RigError> {
    let session = joiner.session()?;
    let ahead =
        u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0) + 24 * 60 * 60 * 1_000;
    session.set_legacy_clock_for_test(ahead);
    session.mark_caught_up_for_test(group);
    // Past grace, quiet and jitter; and past the spacing an earlier circle's
    // post-join on this device set, which the session itself names.
    let mut now = ahead + 2 * 60 * 1_000;
    if let (due, Some(wait)) = session.post_join_due_for_test(now).await {
        if due.is_empty() {
            now += wait;
        }
    }
    session.set_legacy_clock_for_test(now);
    // Acknowledged and stored on no plane: the world's relays hold nothing
    // the build made, as before joiners self-updated.
    let sent = joiner.manager()?.resume_accepted_for_test().await;
    session.set_legacy_clock_for_test(0);
    let Some(commit) = sent.into_iter().last() else {
        return Err(RigError::Core(Step::PostJoin));
    };
    for device in devices {
        if device.tag == joiner.tag {
            continue;
        }
        device
            .manager()?
            .ingest_for_test(&commit)
            .await
            .map_err(|_| RigError::Core(Step::PostJoin))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rig::doubles::TestRelay;
    use crate::rig::RelayTag;
    use haven_core::nostr::mls::types::GroupId;

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

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_devices_spec_dials_its_own_endpoint_where_it_has_one() {
        let relay = TestRelay::start(RelayTag::new(0)).await;
        let spec = needle_circle().spec_for(DeviceTag::new(1), std::slice::from_ref(&relay));
        assert_eq!(spec.group_id_hex, hex::encode([0xCD_u8; 32]));
        assert_eq!(
            spec.relays,
            vec![relay.url_for(DeviceTag::new(1)).to_owned()],
            "a one-endpoint plane answers every device with its canonical address"
        );
        assert_eq!(spec.relays, vec![relay.url().to_owned()]);
    }

    #[test]
    fn a_publish_verdict_is_a_distinct_literal() {
        let labels: std::collections::HashSet<&str> = PublishVerdict::ALL
            .iter()
            .map(|verdict| verdict.label())
            .collect();
        assert_eq!(labels.len(), PublishVerdict::ALL.len());
        assert_eq!(PublishVerdict::Confirmed.label(), "confirmed");
        assert_eq!(PublishVerdict::RolledBack.label(), "rolled-back");
    }
}
