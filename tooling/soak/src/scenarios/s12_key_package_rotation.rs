//! **S12** — the day-63 rotation decision over a real slot on a real relay, and
//! the day-85 rejection as the engine's own validator gives it.
//!
//! An `OpenMLS` `KeyPackage` carries its own MLS `Lifetime`, and on the day
//! `not_after` passes, an un-rotated account becomes silently uninvitable: the
//! 30443 is still on the relay, still fetchable, still well formed, and every
//! `Add` fails validation with nothing on the publishing device to say so. The
//! policy that prevents it rotates once a fixed fraction of the package's OWN
//! lifetime has elapsed, and this scenario grades that policy where it is
//! actually exercised: against a slot a relay really serves.
//!
//! # Every instant comes off the package, never off a calendar
//!
//! The "day 63" in the plan is not a number this arm knows. The rotation point
//! is `rotate_at()` of the package the run just minted —
//! `not_before + fraction × (not_after − not_before)` — and the `not_after`
//! probe is that same package's own upper bound. A lifetime the engine widened
//! or narrowed moves this arm with it rather than breaking it; an arm that
//! spelled a day count would go on grading a window the package no longer has.
//!
//! # Why the heal half is the load-bearing one
//!
//! Haven's heal path re-publishes CACHED bytes under a FRESH `created_at`. Any
//! rotation clock read off the event's timestamp would therefore reset on every
//! relay heal while the real `not_after` kept ticking, and a device that healed
//! a flaky relay once a week would sail straight past the cliff. The arm drives
//! a heal and then asks the same question at the same instant: the answer must
//! not have changed.
//!
//! # The clock the arm steps, and the one it does not
//!
//! The `not_after` probe needs an instant eighty-odd days ahead, which a
//! minutes-long run cannot otherwise reach, so the device's POLICY clock is
//! stepped once — between two quiescent phases, sized from the package's own
//! `not_after`, and never handed to a cursor, an anchor or a processor window
//! (see [`crate::clock`]). The rotation decision itself needs no step at all:
//! `decide_kp_maintenance` takes its instant as an argument, and the argument is
//! the package's own `rotate_at()`.
//!
//! # The cliff itself: `kp-expired-rejected`
//!
//! The second arm asks the engine's own directory validator,
//! `cgka_engine::key_package_metadata`, about two packages that differ in
//! nothing but their lifetime: one that expired an hour ago and a twin carrying
//! the lifetime the device's production mint gave it. No group, no invite, no
//! relay — the refusal is a function of the bytes, so the bytes are the whole
//! subject.
//!
//! `OpenMLS` checks the lifetime LAST inside `KeyPackageIn::validate`
//! (`openmls-0.8.1/src/key_packages/key_package_in.rs:136-207`): a package whose
//! capability list does not cover every extension it carries fails with
//! `UnsupportedExtension` (`:185-193`) before the lifetime gate (`:196-204`) is
//! reached — measured: an expired package missing one capability reports
//! `UnsupportedExtension`, never the lifetime. The engine's capability helpers
//! are `pub(crate)`, so rather than restate them this arm copies the leaf
//! capabilities, leaf extensions and package extensions of a package the
//! device's own session just minted, and re-signs the account-identity proof
//! over a fresh MLS signer with the device's Nostr keys. The twin passing the
//! whole chain is what proves the copy conformant, and what isolates the
//! lifetime as the only reason its sibling was refused. The MLS signer is a
//! fresh Ed25519 pair and the proof is signed by the secp256k1 identity, so
//! the two keys differ by construction (Security Rule 1), and nothing here
//! goes through a production signing seam.
//!
//! Setting the lifetime is what this arm does and what the product must never
//! do: a shipped override could LENGTHEN `not_after` past the rotation, which is
//! why OD-8 refused it as a seam and `scripts/ci/check_no_kp_lifetime_override.sh`
//! bans the setter's name in every shipped path. The production package the arm
//! copies from is deleted from the device's store on every path out, a failed
//! judgement included (mdk#160), so the run leaves no orphaned private init key
//! behind.
//!
//! # What is NOT provable
//!
//! A reader must not over-read this arm's green. A **relay** never rejects an
//! expired 30443 — nothing in NIP-01/NIP-33 or strfry expires a kind-30443 by
//! its embedded MLS lifetime. And wall-clock ageing is not reached: the
//! rejection is a function of the bytes, and Tier 2's −70 d clock jump is the
//! wall-clock analogue. Two upstream pins cover the invite path and are cited
//! rather than restated: `create_group_rejects_expired_invitee_keypackage`
//! (`cgka-engine/tests/group_creation.rs:695`) and
//! `create_group_rejects_invitee_keypackage_with_excessive_lifetime_range`
//! (`:730`). And two constants must not be conflated:
//! `DEFAULT_KEY_PACKAGE_LIFETIME_SECONDS` is **84 days**
//! (`openmls-0.8.1/src/key_packages/lifetime.rs:11`), while **7 261 200 s
//! (84 d + 1 h) is the MAX RANGE**, as
//! `haven-core/src/relay/maintenance/kp_lifetime.rs:6-13` states.
//! `has_acceptable_range()` is **`OpenMLS`'s** policy (`lifetime.rs:20-21`,
//! `:100-103`), not a Marmot one — MDK merely calls it.
//!
//! # Rule 15
//!
//! `RelayKpSnapshot` and `KpMaintenanceDecision` both carry relay URLs, and both
//! of their own doc comments forbid logging them. This module therefore MATCHES
//! them and never formats one; every canary here is a boolean, a slot-shape
//! predicate or a comparison between two byte strings the run itself minted.
//! The same holds for every engine and `OpenMLS` value the second arm touches:
//! an `EngineError` is matched by variant, never rendered.

use std::time::Duration;

use cgka_engine::account_identity_proof::{
    account_identity_proof_extension, AccountIdentityProofRequest, AccountIdentityProofSigner,
};
use cgka_engine::key_package_metadata;
use haven_core::nostr::mls::types::{EngineError, KeyPackage};
use haven_core::relay::maintenance::{
    build_kp_maintenance_events, build_kp_maintenance_events_reusing, decide_kp_maintenance,
    is_conformant_slot_id, monotonic_kp_created_at, read_kp_lifetime, KeyPackageLifetime,
    KpMaintenanceDecision, KpMaintenanceEvents, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
    TrackedKpLifetime, KIND_MARMOT_KEY_PACKAGE,
};
use nostr::{Filter, Keys, Kind};
use openmls::prelude::tls_codec::Deserialize as _;
use openmls::prelude::{
    BasicCredential, CredentialWithKey, KeyPackage as MlsKeyPackage, Lifetime, MlsMessageBodyIn,
    MlsMessageIn, MlsMessageOut, OpenMlsProvider as _, ProtocolVersion,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use tokio::time::Instant;

use crate::clock::{ClockError, WallNow};
use crate::oracle::vacuity::{ExpectationFloor, Observed};
use crate::oracle::{Invariant, Reach, Recovery};
use crate::rig::{DeviceTag, LogDrain, RelayPlane, RigError, Step, TimelineSink};
use crate::scenarios::{
    closing_pairs, grade_round, round, Absence, Arm, ArmOutcome, Scenario, ScenarioReport,
    ScenarioWorld, WithheldAcks, NO_GATING_ROWS,
};

/// The arms this scenario offers: the rotation DECISION over a real slot, and
/// the rejection itself over bytes.
pub const ARMS: [Arm; 2] = [
    Arm {
        label: "kp-rotation-slot",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            // Nothing is done to a relay: the subject is a decision and a slot.
            faults_applied: 0,
            // A key package is not a group operation; no epoch moves.
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 6,
        },
    },
    Arm {
        label: "kp-expired-rejected",
        recovery: Recovery::Undisturbed,
        probe_rounds: 1,
        resubscribes: false,
        absence: Absence::None,
        withheld_acks: WithheldAcks::None,
        floor: ExpectationFloor {
            faults_applied: 0,
            epochs_crossed: 0,
            deliveries_observed: 1,
            canaries_caught: 3,
        },
    },
];

/// Which lifetime the second arm's refused package is minted under.
#[derive(Clone, Copy)]
enum Minted {
    /// An hour past its `not_after`: the arm.
    Expired,
    /// The production lifetime, so nothing is refused: the control.
    Unexpired,
}

/// Runs the arm.
///
/// # Errors
///
/// [`RigError::UnknownTarget`] if the label is not one this scenario offers,
/// [`RigError::ShapeMismatch`] if the world has fewer than two devices,
/// [`RigError::PublishNeverAcked`] if no relay acknowledged a key package — the
/// slot is then on no plane and there is nothing to rotate —
/// [`RigError::InductionMechanismMoved`] if the device's own production package
/// no longer validates, otherwise [`RigError`] naming the step that failed.
pub(crate) async fn run<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    arm: &Arm,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    // A label this scenario does not offer means the dispatch table and the
    // registry disagree, which is the rig being wrong about itself.
    let Some(which) = ARMS.iter().position(|offered| offered.label == arm.label) else {
        return Err(RigError::UnknownTarget);
    };
    let (lead, owner) = lead_and_owner(world)?;
    let canaries = if which == 0 {
        rotation_slot(world, owner).await?
    } else {
        expired_rejected(world, owner, Minted::Expired).await?
    };
    close(world, lead, canaries, tick).await
}

/// The second arm with its refused package minted under the production
/// lifetime instead.
///
/// Nothing is then refused, so the lifetime canary cannot be caught and the
/// floor goes unmet over green oracles. The mis-configuration control in
/// `tests/oracles.rs` runs it and requires rc 3.
///
/// # Errors
///
/// As [`run`].
pub async fn unexpired_control<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    tick: Duration,
) -> Result<ScenarioReport, RigError> {
    let started = Instant::now();
    let (lead, owner) = lead_and_owner(world)?;
    let canaries = expired_rejected(world, owner, Minted::Unexpired).await?;
    let outcome = close(world, lead, canaries, tick).await?;
    Ok(Scenario::KeyPackageRotation.report(world, &ARMS[1], outcome, started))
}

/// The device that leads the closing round, and the one whose packages the
/// arm mints.
fn lead_and_owner<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
) -> Result<(DeviceTag, DeviceTag), RigError> {
    let tags: Vec<DeviceTag> = world.devices().iter().map(|device| device.tag).collect();
    let [lead, owner, ..] = *tags.as_slice() else {
        return Err(RigError::ShapeMismatch);
    };
    Ok((lead, owner))
}

/// The closing round both arms end on.
async fn close<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    lead: DeviceTag,
    canaries: usize,
    tick: Duration,
) -> Result<ArmOutcome, RigError> {
    // Graded over the world's own circles, which this arm never touches: a key
    // package is published beside them, and the device that owns the slot must
    // go on serving every circle it is in.
    let pairs = closing_pairs(world, lead);
    let closing = round(
        1,
        Reach::These(&pairs),
        Recovery::Undisturbed,
        tick,
        NO_GATING_ROWS,
        &[],
        &[],
    );
    let graded = grade_round(
        world,
        &closing,
        &[
            Invariant::Quiescence,
            Invariant::LocationRoundTrip,
            Invariant::SendPathLiveness,
        ],
    )
    .await?;

    world.drain_buses();
    let observed = Observed::measure(world, canaries).await?;
    Ok(ArmOutcome {
        graded,
        observed,
        tick,
    })
}

/// The whole arm: publish a slot, read its own lifetime, and walk the policy.
async fn rotation_slot<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    owner: DeviceTag,
) -> Result<usize, RigError> {
    let mut canaries = 0_usize;

    let first = publish_slot(world, owner, None, None).await?;
    let slot = first.d_tag.clone();
    let original = first.event.content.clone();
    // 1. The OLD bytes really are on every plane. Without this the rotation
    //    below would be a publish into a slot nothing was serving, and
    //    "the bytes changed" would be a comparison against nothing.
    if served_everywhere(world, owner, &slot, &original).await? {
        canaries += 1;
    }

    let lifetime = lifetime_of(&first)?;
    let rotate_at = lifetime.rotate_at();
    let snapshot = snapshot_from_planes(world, owner, &slot).await?;
    // 2. At the package's OWN rotation point — a fraction of its OWN lifetime,
    //    never a day count — the decision is to re-mint into the same slot.
    if rotates_into(&decide_kp_maintenance(
        &snapshot,
        Some(&slot),
        TrackedKpLifetime::Known(lifetime),
        rotate_at,
    )) == Some(slot.clone())
    {
        canaries += 1;
    }

    let healed = heal_slot(world, owner, &first).await?;
    // 3. A heal re-publishes CACHED bytes under a FRESH `created_at`, and the
    //    rotation clock does not move: the same lifetime, the same answer, at
    //    the same instant. This is the whole reason the clock is read off the
    //    package rather than off the event.
    if lifetime_of(&healed)? == lifetime
        && rotates_into(&decide_kp_maintenance(
            &snapshot_from_planes(world, owner, &slot).await?,
            Some(&slot),
            TrackedKpLifetime::Known(lifetime_of(&healed)?),
            rotate_at,
        )) == Some(slot.clone())
    {
        canaries += 1;
    }

    let rotated = publish_slot(world, owner, Some(&slot), created_at_of(&healed)).await?;
    // 4. The rotation lands in the SAME slot — still the binding's 64 lowercase
    //    hex — and the bytes on every plane are new ones.
    if rotated.d_tag == slot
        && is_conformant_slot_id(&slot)
        && rotated.event.content != original
        && served_everywhere(world, owner, &slot, &rotated.event.content).await?
    {
        canaries += 1;
    }

    // 5. A replacement minted in the same wall-clock second still wins the slot:
    //    NIP-01 breaks a `created_at` tie by event id, which the publisher does
    //    not control, so the stamp is floored at one above its predecessor —
    //    asserted as the pure rule AND as the bytes a plane really serves.
    let previous = created_at_of(&rotated);
    let replacement = publish_slot(world, owner, Some(&slot), previous).await?;
    if previous.is_some_and(|prev| {
        // The rule itself, at the one instant that makes it load-bearing: a
        // replacement minted in the predecessor's OWN second is stamped one
        // second above it rather than tying with it.
        monotonic_kp_created_at(Some(prev), prev_as_secs(prev)).as_secs() == prev_as_secs(prev) + 1
    }) && created_at_of(&replacement) > previous
        && served_everywhere(world, owner, &slot, &replacement.event.content).await?
    {
        canaries += 1;
    }

    // 6. The cliff itself, as a DECISION: below the package's own `not_after`
    //    it is not past it, and above it, it is. The policy clock is stepped
    //    exactly once, here, between two quiescent phases and sized from the
    //    package's own upper bound.
    if past_not_after_only_after_the_step(world, owner, lifetime)? {
        canaries += 1;
    }
    Ok(canaries)
}

/// The second arm: an expired package and its unexpired twin, both minted in
/// the device's own production shape, asked of the engine's own validator.
///
/// The production package is deleted from the device's store on EVERY path
/// out, a failed judgement included (mdk#160). The two throwaway MLS signers
/// `mint_like` builds hold their private keys in `OpenMLS`'s own
/// `SignatureKeyPair { private: Vec<u8> }`, which does not zeroize
/// (`openmls_basic_credential-0.5.0/src/lib.rs:29-33`), and in the provider's
/// in-memory store, until `mint_like` returns: test-only keys in a test
/// process over temp dirs, below Security Rule 7's bar, and said here rather
/// than left for a reader to find.
async fn expired_rejected<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    minted: Minted,
) -> Result<usize, RigError> {
    let device = world.device(owner)?;
    let session = device.session()?;
    let production = session
        .fresh_key_package()
        .await
        .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    let judged = judge(&production, &device.keys, minted);
    let deleted = session
        .delete_key_package(&production)
        .await
        .map_err(|_| RigError::Core(Step::DeleteKeyPackage));
    let canaries = judged?;
    deleted?;
    Ok(canaries)
}

/// The second arm's three canaries over `production`'s shape.
fn judge(production: &KeyPackage, keys: &Keys, minted: Minted) -> Result<usize, RigError> {
    let mut canaries = 0_usize;
    let template = validated(production).ok_or(RigError::InductionMechanismMoved)?;
    // `OpenMLS` reads its own un-offset system clock inside `validate`, so the
    // refused window is minted against the wall, never the policy clock.
    let wall = u64::try_from(WallNow::now().secs())
        .map_err(|_| RigError::Clock(ClockError::BeforeEpoch))?;
    let refused_lifetime = match minted {
        // Upstream's own window (`group_creation.rs:695`): one hour wide, so far
        // inside the acceptable range that the range policy cannot be what
        // refuses it.
        Minted::Expired => Lifetime::init(wall.saturating_sub(7_200), wall.saturating_sub(3_600)),
        Minted::Unexpired => *template.life_time(),
    };
    let refused = mint_like(&template, keys, refused_lifetime)?;
    let twin = mint_like(&template, keys, *template.life_time())?;

    // 1. The expired package is refused by the lifetime-VALIDITY gate: the
    //    `None`/`None` shape is `OpenMLS`'s `InvalidLifetime`, where the range
    //    policy would carry both bounds.
    if matches!(
        key_package_metadata(&refused),
        Err(EngineError::InvalidKeyPackageLifetime {
            not_before: None,
            not_after: None,
        })
    ) {
        canaries += 1;
    }

    // 2. The twin clears the WHOLE chain — capabilities, signatures, identity,
    //    proof — and names the device's own account. Without this, canary 1
    //    could be any earlier gate wearing the lifetime's name.
    if key_package_metadata(&twin)
        .is_ok_and(|metadata| metadata.credential_identity_hex == keys.public_key().to_hex())
    {
        canaries += 1;
    }

    // 3. Haven's own rotation reader agrees: it classifies the refused bytes as
    //    positively unusable, not unreadable — the distinction that decides
    //    whether the device re-mints or merely retries.
    if read_kp_lifetime(refused.bytes()) == TrackedKpLifetime::NotCurrent {
        canaries += 1;
    }
    Ok(canaries)
}

/// The package inside `production`, validated as `OpenMLS` validates any
/// transported one.
fn validated(production: &KeyPackage) -> Option<MlsKeyPackage> {
    let MlsMessageBodyIn::KeyPackage(key_package) =
        MlsMessageIn::tls_deserialize_exact(production.bytes())
            .ok()?
            .extract()
    else {
        return None;
    };
    key_package
        .validate(
            OpenMlsRustCrypto::default().crypto(),
            ProtocolVersion::Mls10,
        )
        .ok()
}

/// A package shaped exactly like `template` but for `lifetime`, under a fresh
/// MLS signer bound to `keys` by a fresh account-identity proof.
fn mint_like(
    template: &MlsKeyPackage,
    keys: &Keys,
    lifetime: Lifetime,
) -> Result<KeyPackage, RigError> {
    let minting = || RigError::Core(Step::MintKeyPackage);
    let provider = OpenMlsRustCrypto::default();
    let ciphersuite = template.ciphersuite();
    let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm()).map_err(|_| minting())?;
    let identity = keys.public_key().to_bytes().to_vec();
    let proof = account_identity_proof_extension(
        &identity,
        &signer.to_public_vec(),
        ciphersuite,
        ciphersuite.signature_algorithm(),
        &ProofSigner(keys),
    )
    .map_err(|_| minting())?;
    let mut leaf_extensions = template.leaf_node().extensions().clone();
    leaf_extensions
        .add_or_replace(proof)
        .map_err(|_| minting())?;
    let bundle = MlsKeyPackage::builder()
        .leaf_node_capabilities(template.leaf_node().capabilities().clone())
        .leaf_node_extensions(leaf_extensions)
        .key_package_extensions(template.extensions().clone())
        .key_package_lifetime(lifetime)
        .build(
            ciphersuite,
            &provider,
            &signer,
            CredentialWithKey {
                credential: BasicCredential::new(identity).into(),
                signature_key: signer.public().into(),
            },
        )
        .map_err(|_| minting())?;
    MlsMessageOut::from(bundle.key_package().clone())
        .to_bytes()
        .map(KeyPackage::new)
        .map_err(|_| minting())
}

/// The account-identity proof signed with the device's own Nostr keys, through
/// the engine's public request type rather than any production signer.
struct ProofSigner<'a>(&'a Keys);

impl AccountIdentityProofSigner for ProofSigner<'_> {
    fn sign_account_identity_proof(
        &self,
        request: &AccountIdentityProofRequest,
    ) -> Result<[u8; 64], String> {
        let event = request
            .proof_event()?
            .sign_with_keys(self.0)
            .map_err(|_| String::from("proof signing failed"))?;
        request.signature_from_signed_event(event)
    }
}

/// Mints a fresh package into `existing_d` (or a new slot) and publishes it.
async fn publish_slot<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    existing_d: Option<&str>,
    prev_created_at: Option<i64>,
) -> Result<KpMaintenanceEvents, RigError> {
    let urls = world.relay_urls();
    let device = world.device(owner)?;
    let built = build_kp_maintenance_events(
        device.session()?,
        &device.keys,
        &urls,
        existing_d,
        prev_created_at,
    )
    .await
    .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    publish(world, owner, built).await
}

/// Re-publishes the CACHED bytes of `built` into its own slot — the heal path,
/// with no re-mint.
async fn heal_slot<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    built: &KpMaintenanceEvents,
) -> Result<KpMaintenanceEvents, RigError> {
    let urls = world.relay_urls();
    let device = world.device(owner)?;
    let healed = build_kp_maintenance_events_reusing(
        &device.keys,
        built.key_package.bytes(),
        &urls,
        &built.d_tag,
        created_at_of(built),
    )
    .map_err(|_| RigError::Core(Step::MintKeyPackage))?;
    publish(world, owner, healed).await
}

/// Publishes one key-package event and requires a relay's own acknowledgement.
async fn publish<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    built: KpMaintenanceEvents,
) -> Result<KpMaintenanceEvents, RigError> {
    if world
        .publish_witnessed(owner, std::slice::from_ref(&built.event))
        .await?
        .is_none()
    {
        // No plane serves the slot, so every probe below would be reading an
        // absence the arm created rather than the policy it grades.
        return Err(RigError::PublishNeverAcked);
    }
    Ok(built)
}

/// The lifetime the package inside `built` carries, read from its own bytes.
fn lifetime_of(built: &KpMaintenanceEvents) -> Result<KeyPackageLifetime, RigError> {
    match read_kp_lifetime(built.key_package.bytes()) {
        TrackedKpLifetime::Known(lifetime) => Ok(lifetime),
        // A package this run just minted whose lifetime cannot be read is the
        // rig's instrument being wrong about the engine, not a policy verdict.
        TrackedKpLifetime::Absent
        | TrackedKpLifetime::NotCurrent
        | TrackedKpLifetime::Unreadable => Err(RigError::InductionMechanismMoved),
    }
}

/// The `created_at` of `built`'s event, as the slot record keeps it.
fn created_at_of(built: &KpMaintenanceEvents) -> Option<i64> {
    i64::try_from(built.event.created_at.as_secs()).ok()
}

/// A recorded stamp as the seconds a policy seam takes.
fn prev_as_secs(prev: i64) -> u64 {
    u64::try_from(prev).unwrap_or(0)
}

/// The slot a decision would re-mint into, if it is a rotation at all.
fn rotates_into(decision: &KpMaintenanceDecision) -> Option<String> {
    match decision {
        KpMaintenanceDecision::Rotate { existing_d, .. } => Some(existing_d.clone()),
        // Matched, never rendered: `Republish` and `SeedD` carry relay URLs and
        // a slot id, and this scenario's canaries are booleans.
        KpMaintenanceDecision::NoOp
        | KpMaintenanceDecision::SeedD { .. }
        | KpMaintenanceDecision::Republish { .. } => None,
    }
}

/// Whether every plane serves `slot` with exactly `content`.
async fn served_everywhere<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    slot: &str,
    content: &str,
) -> Result<bool, RigError> {
    let served = slot_contents(world, owner, slot).await?;
    Ok(served.len() == world.relays().len() && served.iter().all(|page| page == content))
}

/// What each plane's store serves for `owner`'s `slot`, in plane order.
///
/// A plane that serves nothing, or more than one event for one addressable
/// coordinate, contributes nothing: both are "this plane does not serve the
/// slot", which is exactly what the maintenance decision's own presence gate
/// asks.
async fn slot_contents<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    slot: &str,
) -> Result<Vec<String>, RigError> {
    let author = world.device(owner)?.keys.public_key();
    let mut served = Vec::with_capacity(world.relays().len());
    for plane in world.relays() {
        let page = plane
            .stored_page(
                Filter::new()
                    .kind(Kind::Custom(KIND_MARMOT_KEY_PACKAGE))
                    .author(author)
                    .identifier(slot),
            )
            .await?;
        if let [only] = page.as_slice() {
            served.push(only.content.clone());
        }
    }
    Ok(served)
}

/// The snapshot the maintenance decision reads, built from what the planes
/// really serve rather than from what the arm believes it published.
///
/// Measured, for the same reason the canaries are: a snapshot the arm declared
/// would make the decision a function of this file, and the mis-configuration
/// control — an endpoint that is gone, so no relay responds — could not reach
/// the fail-closed branch it exists to prove.
async fn snapshot_from_planes<T: TimelineSink, L: LogDrain>(
    world: &ScenarioWorld<T, L>,
    owner: DeviceTag,
    slot: &str,
) -> Result<RelayKpSnapshot, RigError> {
    let author = world.device(owner)?.keys.public_key();
    let mut responders = Vec::with_capacity(world.relays().len());
    for plane in world.relays() {
        let page = plane
            .stored_page(
                Filter::new()
                    .kind(Kind::Custom(KIND_MARMOT_KEY_PACKAGE))
                    .author(author)
                    .identifier(slot),
            )
            .await?;
        if page.is_empty() {
            continue;
        }
        responders.push(RelayKpPerRelay {
            relay_url: plane.url().to_owned(),
            canonical: page
                .iter()
                .map(|event| RelayKpEntry {
                    d_tag: slot.to_owned(),
                    event_id: event.id.to_hex(),
                })
                .collect(),
        });
    }
    Ok(RelayKpSnapshot { responders })
}

/// Steps `owner`'s policy clock once, past the package's own `not_after`, and
/// answers whether the cliff predicate flipped exactly across that step.
fn past_not_after_only_after_the_step<T: TimelineSink, L: LogDrain>(
    world: &mut ScenarioWorld<T, L>,
    owner: DeviceTag,
    lifetime: KeyPackageLifetime,
) -> Result<bool, RigError> {
    let wall = WallNow::now();
    let before = world.device(owner)?.policy_now(wall)?;
    let fresh = !lifetime.is_past_not_after(before.secs());

    let span = i64::try_from(lifetime.not_after)
        .ok()
        .and_then(|not_after| not_after.checked_sub(wall.secs()))
        .and_then(|delta| delta.checked_add(1))
        .ok_or(RigError::Clock(crate::clock::ClockError::BeforeEpoch))?;
    world.device_mut(owner)?.step_policy_offset(span);

    let after = world.device(owner)?.policy_now(wall)?;
    Ok(fresh && lifetime.is_past_not_after(after.secs()))
}

#[cfg(test)]
mod tests {
    use super::ARMS;
    use crate::oracle::Recovery;

    #[test]
    fn neither_arm_breaks_a_relay_or_crosses_an_epoch() {
        for arm in ARMS {
            assert!(
                arm.recovery == Recovery::Undisturbed,
                "a key package is minted beside the circles, not against them"
            );
            assert!(
                arm.floor.faults_applied == 0,
                "the subject is a decision, a slot or a package's bytes, and none is \
                 something a relay does"
            );
            assert!(
                arm.floor.epochs_crossed == 0,
                "a key package is not a group operation"
            );
            assert!(
                !arm.resubscribes,
                "nothing re-opens a REQ, so the subscribe ladder is not in the bound"
            );
        }
    }

    #[test]
    fn the_rejection_arm_demands_the_refusal_its_twin_and_havens_own_reading() {
        let arm = ARMS[1];
        assert!(
            arm.label == "kp-expired-rejected",
            "the second arm is the day-85 rejection"
        );
        assert!(
            arm.floor.canaries_caught == 3,
            "the expired package refused by the lifetime gate, the twin that clears \
             the whole chain, and Haven's own reader calling it not current"
        );
        assert!(
            arm.floor.deliveries_observed == 1,
            "the closing round over the world's own circles still has to deliver"
        );
    }

    #[test]
    fn the_arm_demands_all_six_steps_of_the_policy() {
        assert!(
            ARMS[0].floor.canaries_caught == 6,
            "the old bytes on the plane, the rotation decision at the package's own \
             threshold, the heal that does not reset it, the re-mint into the same \
             slot, the same-second replacement that still wins it, and the cliff"
        );
        assert!(
            ARMS[0].floor.deliveries_observed == 1,
            "the closing round over the world's own circles still has to deliver"
        );
    }
}
