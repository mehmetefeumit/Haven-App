//! The `KeyPackage` lifecycle on MDK's durable record: one signed event per
//! package, republished byte for byte; private material deleted when a relay
//! acknowledges its replacement, and at `Lifetime.not_after` whether or not
//! anything can be published (`foundation/key-packages.md:86-106`).
//!
//! Every test drives a real `AccountDeviceSession` over a real `SQLCipher`
//! file. "Is the private material still there?" is read off the store itself
//! (`key_package_bundle_count_for_test`), because MDK stops reporting a bundle
//! the moment its lifetime ends and the bound under test is about exactly
//! those.

mod helpers;

use cgka_traits::maintenance::KeyPackageLifecycleState;
use cgka_traits::storage::StorageProvider as _;
use cgka_traits::transport::Timestamp as MdkTimestamp;
use haven_core::nostr::mls::types::{KeyPackage, LocationGroupConfig, MessageId, ProtocolProfile};
use haven_core::nostr::mls::{SessionManager, StorageConfig, TrackedKeyPackage};
use haven_core::relay::maintenance::{
    build_kp_maintenance_events, decide_kp_maintenance, now_secs, read_kp_lifetime,
    KpMaintenanceDecision, KpMaintenanceEvents, RelayKpEntry, RelayKpPerRelay, RelayKpSnapshot,
    TrackedKpLifetime, TrackedKpSlot,
};
use helpers::twin_key_packages::{expired_lifetime, mint_like, pre_migration, Minted, Twin};
use nostr::{JsonUtil as _, Keys};
use openmls::prelude::OpenMlsProvider;
use openmls_rust_crypto::RustCrypto;
use storage_sqlite::SqliteAccountStorage;
use tempfile::TempDir;

const RELAY: &str = "wss://own.example.com";

struct Device {
    session: SessionManager,
    keys: Keys,
    dir: TempDir,
}

impl Device {
    fn new() -> Self {
        let dir = TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let session = SessionManager::new_unencrypted(dir.path(), &keys).expect("session");
        Self { session, keys, dir }
    }

    /// Mints and freezes a replacement in `slot`, as a maintenance tick does.
    async fn stage(&self, slot: Option<&str>) -> KpMaintenanceEvents {
        build_kp_maintenance_events(&self.session, &self.keys, &[RELAY.to_owned()], slot, None)
            .await
            .expect("stage a key package")
    }

    /// A staged package a relay acknowledged.
    async fn publish(&self, slot: Option<&str>) -> KpMaintenanceEvents {
        let staged = self.stage(slot).await;
        assert!(self
            .session
            .promote_key_package(&staged.event.id)
            .await
            .expect("promote"));
        staged
    }

    async fn tracked(&self) -> TrackedKeyPackage {
        self.session
            .tracked_key_package()
            .await
            .expect("read the record")
            .expect("a slot is tracked")
    }

    async fn sweep(&self, now: u64) -> bool {
        self.session
            .sweep_expired_key_packages(now)
            .await
            .expect("sweep")
    }

    async fn bundles(&self) -> usize {
        self.session
            .key_package_bundle_count_for_test()
            .await
            .expect("count the stored bundles")
    }

    /// A second storage handle on the session's database, as the session's
    /// own is: nothing hydrated, only the tables a test plants into.
    fn store(&self) -> SqliteAccountStorage {
        haven_core::sqlcipher_init::ensure().expect("SQLite initialises");
        SqliteAccountStorage::open_encrypted_with_options(
            StorageConfig::new(self.dir.path()).database_path(),
            &StorageConfig::test_sqlcipher_key().expect("the test key"),
            StorageConfig::test_storage_options(),
        )
        .expect("open a second handle")
    }

    /// Makes a genuinely expired package of this account the tracked current
    /// one in `slot`, with its private bundle in the store — the state a
    /// device is in when it comes back after its package's `not_after`. The
    /// replacement already staged in the slot stays staged. Returns the
    /// package and its `not_after`.
    fn plant_expired_current(&self, template: &[u8], slot: &str) -> (Minted, u64) {
        let store = self.store();
        let lifetime = expired_lifetime();
        let expired = mint_like(
            &Planting {
                crypto: RustCrypto::default(),
                store: &store,
            },
            template,
            &self.keys,
            Twin {
                lifetime: Some(lifetime),
                last_resort: true,
                without_component: None,
            },
        );
        let records = store
            .maintenance_storage()
            .expect("the store keeps maintenance records");
        let mut state: KeyPackageLifecycleState = records
            .key_package_lifecycle()
            .expect("read the record")
            .expect("a replacement is staged in the slot");
        assert_eq!(state.stable_slot_id, slot);
        state.authored_event_id = Some(MessageId::new(vec![7; 32]));
        state.current_key_package = Some(
            KeyPackage::new(expired.bytes.clone()).with_protocol_profile(ProtocolProfile::Current),
        );
        state.current_key_package_ref = Some(expired.key_package_ref.clone());
        state.current_not_before = Some(MdkTimestamp(lifetime.not_before()));
        state.current_not_after = Some(MdkTimestamp(lifetime.not_after()));
        records
            .put_key_package_lifecycle(&state)
            .expect("plant the record");
        (expired, lifetime.not_after())
    }
}

/// An `OpenMLS` provider whose storage is the session's own database, so a
/// package built through it leaves its private bundle where the engine keeps
/// its own.
struct Planting<'a> {
    crypto: RustCrypto,
    store: &'a SqliteAccountStorage,
}

impl OpenMlsProvider for Planting<'_> {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = <SqliteAccountStorage as cgka_traits::storage::StorageProvider>::Mls;

    fn storage(&self) -> &Self::StorageProvider {
        self.store.mls_storage()
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

fn slot(seed: u8) -> String {
    hex::encode([seed; 32])
}

/// V2-10: a package's kind-30443 is signed once. What is staged, what a retry
/// republishes, what is tracked after the acknowledgement and what a reopened
/// session reads back are the same bytes.
#[tokio::test]
async fn a_kp_republish_is_byte_identical_to_the_frozen_signed_event() {
    let device = Device::new();
    let staged = device.stage(None).await;
    let signed = staged.event.as_json();

    let pending = device.tracked().await;
    assert_eq!(pending.pending.map(|e| e.as_json()), Some(signed.clone()));
    assert!(
        pending.published.is_none() && pending.package.is_empty(),
        "nothing is current until a relay acknowledged it"
    );

    assert!(device
        .session
        .promote_key_package(&staged.event.id)
        .await
        .expect("promote"));
    let current = device.tracked().await;
    assert_eq!(current.published.map(|e| e.as_json()), Some(signed.clone()));
    assert_eq!(current.package, staged.key_package.bytes());
    assert_eq!(current.slot, staged.d_tag);
    assert!(current.pending.is_none() && !current.adopted && !current.replacement_owed);

    let Device { session, keys, dir } = device;
    drop(session);
    let reopened = SessionManager::new_unencrypted(dir.path(), &keys).expect("reopen");
    let after = reopened
        .tracked_key_package()
        .await
        .expect("read the record")
        .expect("the record is durable");
    assert_eq!(after.published.map(|e| e.as_json()), Some(signed));
}

/// A kill between staging a replacement and its acknowledgement loses
/// nothing: the reopened session holds the same signed event, promotes it when
/// the acknowledgement arrives, and has minted nothing more.
#[tokio::test]
async fn a_replacement_staged_before_a_kill_is_promoted_after_the_reopen() {
    let device = Device::new();
    let first = device.publish(None).await;
    let staged = device.stage(Some(&first.d_tag)).await;
    let signed = staged.event.as_json();

    let Device { session, keys, dir } = device;
    drop(session);
    let reopened = Device {
        session: SessionManager::new_unencrypted(dir.path(), &keys).expect("reopen"),
        keys,
        dir,
    };
    let pending = reopened.tracked().await;
    assert_eq!(pending.pending.map(|e| e.as_json()), Some(signed.clone()));
    assert_eq!(
        pending.package,
        first.key_package.bytes(),
        "the acknowledged package stays current until the replacement is"
    );
    assert_eq!(reopened.bundles().await, 2);

    assert!(reopened
        .session
        .promote_key_package(&staged.event.id)
        .await
        .expect("promote"));
    let current = reopened.tracked().await;
    assert_eq!(current.published.map(|e| e.as_json()), Some(signed));
    assert_eq!(current.package, staged.key_package.bytes());
    assert_eq!(current.slot, first.d_tag);
    assert_eq!(reopened.bundles().await, 1, "the superseded key is gone");
}

/// A replacement whose signing never completed (a kill between MDK's stage
/// and the signature) is signed on the next attempt: the same package, no
/// second private bundle.
#[tokio::test]
async fn a_replacement_a_kill_left_unsigned_is_signed_not_reminted() {
    let device = Device::new();
    let slot = slot(1);
    let unsigned = device
        .session
        .stage_key_package(&slot, now_secs(), &[RELAY.to_owned()], |_, _| None)
        .await;
    assert!(unsigned.is_err(), "the signature did not happen");
    assert_eq!(device.bundles().await, 1, "MDK minted and kept the bundle");
    assert!(device.tracked().await.pending.is_none());

    let resumed = device.stage(Some(&slot)).await;
    assert_eq!(device.bundles().await, 1, "the same package was signed");
    assert_eq!(
        device.tracked().await.pending.map(|e| e.id),
        Some(resumed.event.id)
    );
}

/// `foundation/key-packages.md:89-106`: a superseded package's private
/// material goes when a relay acknowledges its replacement — not before, and
/// not at some later `not_after`. A replacement that was staged and then
/// re-staged goes with it.
#[tokio::test]
async fn superseded_kp_material_deleted_on_confirmed_replacement_not_at_not_after() {
    let device = Device::new();
    let first = device.publish(None).await;
    assert_eq!(device.bundles().await, 1);

    // A replacement no relay has acknowledged supersedes nothing yet.
    let unacked = device.stage(Some(&first.d_tag)).await;
    assert_eq!(device.bundles().await, 2);
    assert_eq!(device.tracked().await.package, first.key_package.bytes());

    // Re-staged before any acknowledgement: MDK keeps the earlier one too.
    let replacement = device.stage(Some(&first.d_tag)).await;
    assert_eq!(device.bundles().await, 3);
    assert!(
        !device
            .session
            .promote_key_package(&unacked.event.id)
            .await
            .expect("promote"),
        "an event that is no longer the staged one promotes nothing"
    );
    assert_eq!(device.bundles().await, 3);

    assert!(device
        .session
        .promote_key_package(&replacement.event.id)
        .await
        .expect("promote"));
    assert_eq!(
        device.bundles().await,
        1,
        "only the acknowledged replacement's material is left"
    );
    let TrackedKpLifetime::Known(lifetime) = read_kp_lifetime(first.key_package.bytes()) else {
        panic!("a freshly minted package has a readable lifetime");
    };
    assert!(
        now_secs() < lifetime.not_after,
        "and that happened long before the superseded package's `not_after`"
    );
    let tracked = device.tracked().await;
    assert_eq!(tracked.package, replacement.key_package.bytes());
    assert_eq!(tracked.slot, first.d_tag, "the slot is reused");
}

/// V16, as predicted from source: MDK's own delete validates the lifetime
/// first and so refuses the one package the `not_after` bound exists to
/// delete (`cgka-engine/src/key_package.rs:412-435,516-525`). Haven's sweep
/// deletes it all the same, and keeps the slot.
#[tokio::test]
async fn an_expired_key_package_bundle_is_still_deleted() {
    let device = Device::new();
    let template = device.stage(None).await;
    let slot = template.d_tag.clone();
    let (expired, not_after) = device.plant_expired_current(template.key_package.bytes(), &slot);
    assert_eq!(
        device.bundles().await,
        2,
        "the staged template and the expired package"
    );

    let through_mdk = device
        .session
        .delete_key_package(
            &KeyPackage::new(expired.bytes.clone()).with_protocol_profile(ProtocolProfile::Current),
        )
        .await;
    assert!(through_mdk.is_err(), "MDK refuses an expired package");
    assert_eq!(device.bundles().await, 2, "and leaves its bundle in place");

    assert!(
        !device
            .session
            .sweep_expired_key_packages(not_after - 1)
            .await
            .expect("sweep"),
        "the bound does not fire before `not_after`"
    );
    assert_eq!(device.bundles().await, 2);

    assert!(
        device
            .session
            .sweep_expired_key_packages(not_after)
            .await
            .expect("sweep"),
        "at `not_after` the current package's material is deleted"
    );
    assert_eq!(device.bundles().await, 1, "only the expired bundle went");
    let tracked = device.tracked().await;
    assert!(tracked.package.is_empty() && tracked.published.is_none());
    assert_eq!(tracked.slot, slot, "the slot survives for the replacement");
    assert!(!tracked.adopted, "it is still this device's own slot");

    assert!(
        !device
            .session
            .sweep_expired_key_packages(now_secs())
            .await
            .expect("sweep again"),
        "the sweep does not repeat"
    );
}

/// The `not_after` bound deletes nothing it should not. A package inside its
/// lifetime — even past its rotation point — is kept until the exact second
/// of `not_after`, and a record with no lifetime to read (nothing tracked, or
/// bytes that do not parse) is never swept.
#[tokio::test]
async fn the_expiry_sweep_spares_everything_short_of_not_after() {
    let device = Device::new();
    assert!(!device.sweep(u64::MAX).await, "nothing is tracked");

    let published = device.publish(None).await;
    let TrackedKpLifetime::Known(lifetime) = read_kp_lifetime(published.key_package.bytes()) else {
        panic!("a freshly minted package has a readable lifetime");
    };
    for live in [lifetime.rotate_at(), lifetime.not_after - 1] {
        assert!(!device.sweep(live).await, "a live package is kept");
    }
    assert_eq!(device.bundles().await, 1);
    assert_eq!(
        device.tracked().await.package,
        published.key_package.bytes()
    );

    assert!(
        device.sweep(lifetime.not_after).await,
        "the bound is inclusive"
    );
    assert_eq!(device.bundles().await, 0);

    let unreadable = b"not a key package";
    device
        .session
        .track_key_package_for_test(&published.d_tag, unreadable, None, now_secs())
        .await
        .expect("plant bytes that do not parse");
    assert!(
        !device.sweep(u64::MAX).await,
        "an unreadable package has no bound"
    );
    assert_eq!(device.tracked().await.package, unreadable);
}

/// V2-11: MDK's promotion validates every package it retires and aborts on an
/// expired one (`cgka-engine/src/maintenance.rs:99-135`), which would leave a
/// device that came back after `not_after` unable ever to promote its
/// replacement.
#[tokio::test]
async fn an_acked_replacement_is_promoted_even_when_a_retired_bundle_has_expired() {
    let device = Device::new();
    let template = device.stage(None).await;
    let slot = template.d_tag.clone();
    device.plant_expired_current(template.key_package.bytes(), &slot);

    let replacement = device.stage(Some(&slot)).await;
    assert_eq!(
        device.bundles().await,
        3,
        "the template, the expired package and the replacement"
    );
    assert!(device
        .session
        .promote_key_package(&replacement.event.id)
        .await
        .expect("the promotion must not abort on the expired package"));

    assert_eq!(
        device.bundles().await,
        1,
        "the expired package and the re-staged template are both gone"
    );
    assert_eq!(
        device.tracked().await.package,
        replacement.key_package.bytes()
    );
}

/// `foundation/key-packages.md:86-87`: after a Welcome consumed the published
/// package a replacement is owed, and its acknowledgement deletes the consumed
/// package's material.
#[tokio::test]
async fn a_welcome_that_consumed_our_package_owes_a_replacement() {
    let alice = Device::new();
    let bob = Device::new();
    let published = bob.publish(None).await;
    assert!(!bob.tracked().await.replacement_owed);

    let config = LocationGroupConfig::new("Consumed")
        .with_relay(RELAY)
        .with_admin(alice.keys.public_key().to_hex());
    let created = alice
        .session
        .create_group(
            vec![SessionManager::key_package_from_event(&published.event).expect("parse")],
            config,
        )
        .await
        .expect("create");
    let welcome = helpers::first_welcome_event(&created.effects);
    bob.session.accept_welcome(&welcome).await.expect("join");

    let consumed = bob.tracked().await;
    assert!(
        consumed.replacement_owed && consumed.consumed_but_held,
        "the join consumed the tracked package, whose key is still held"
    );
    let replacement = bob.publish(Some(&published.d_tag)).await;
    let tracked = bob.tracked().await;
    assert!(!tracked.replacement_owed);
    assert_eq!(tracked.package, replacement.key_package.bytes());
    assert_eq!(bob.bundles().await, 1, "the consumed package's key is gone");
}

/// A relay may hold a package whose acknowledgement never arrived, and an
/// inviter may use it. When the acknowledgement does arrive, the package is
/// current and already consumed: the replacement is still owed.
#[tokio::test]
async fn a_package_consumed_before_its_acknowledgement_still_owes_a_replacement() {
    let alice = Device::new();
    let bob = Device::new();
    let staged = bob.stage(None).await;

    let config = LocationGroupConfig::new("ConsumedEarly")
        .with_relay(RELAY)
        .with_admin(alice.keys.public_key().to_hex());
    let created = alice
        .session
        .create_group(
            vec![SessionManager::key_package_from_event(&staged.event).expect("parse")],
            config,
        )
        .await
        .expect("create");
    bob.session
        .accept_welcome(&helpers::first_welcome_event(&created.effects))
        .await
        .expect("join");

    assert!(bob
        .session
        .promote_key_package(&staged.event.id)
        .await
        .expect("promote"));
    assert!(bob.tracked().await.replacement_owed);
}

/// A heal re-advertises a package only while this device can still open a
/// Welcome to it. One whose private bundle is gone, and one that is not a
/// Current-profile package at all, are replaced instead — even though every
/// relay already serves the tracked event.
#[tokio::test]
async fn heal_rotates_when_cached_kp_is_legacy_or_not_owned() {
    let device = Device::new();
    let published = device.publish(None).await;
    let served = RelayKpSnapshot {
        responders: vec![RelayKpPerRelay {
            relay_url: RELAY.to_owned(),
            canonical: vec![RelayKpEntry {
                d_tag: published.d_tag.clone(),
                event_id: published.event.id.to_hex(),
                created_at: published.event.created_at.as_secs(),
                pre_migration: false,
            }],
        }],
    };
    let decide = |tracked: &TrackedKeyPackage, package: &[u8]| {
        decide_kp_maintenance(
            &served,
            Some(TrackedKpSlot {
                d_tag: &tracked.slot,
                event_id: &published.event.id.to_hex(),
                created_at: published.event.created_at.as_secs(),
                adopted: tracked.adopted,
                replacement_owed: tracked.replacement_owed,
            }),
            read_kp_lifetime(package),
            now_secs(),
        )
    };

    let tracked = device.tracked().await;
    assert_eq!(
        decide(&tracked, &tracked.package),
        KpMaintenanceDecision::NoOp,
        "control: an owned, current package every relay serves is left alone"
    );

    device
        .session
        .delete_key_package(&published.key_package)
        .await
        .expect("lose the private bundle");
    let tracked = device.tracked().await;
    assert!(
        tracked.replacement_owed && !tracked.consumed_but_held,
        "the bundle is no longer held, which no held invitation can wait for"
    );
    assert_eq!(
        decide(&tracked, &tracked.package),
        KpMaintenanceDecision::Replace {
            existing_d: published.d_tag.clone(),
            targets: vec![RELAY.to_owned()],
        }
    );

    let healthy = TrackedKeyPackage {
        replacement_owed: false,
        ..tracked
    };
    assert_eq!(
        decide(&healthy, &pre_migration(&device.keys)),
        KpMaintenanceDecision::Rotate {
            existing_d: published.d_tag.clone(),
            targets: vec![RELAY.to_owned()],
            lifetime_unreadable: true,
        },
        "a pre-migration package is never re-advertised"
    );
}

/// The record names a slot, two events and a package: none of them renders.
#[tokio::test]
async fn tracked_key_package_debug_redacts_the_slot_and_both_events() {
    let device = Device::new();
    let published = device.publish(None).await;
    let staged = device.stage(Some(&published.d_tag)).await;
    let tracked = device.tracked().await;
    haven_core::assert_debug_redacted!(
        &tracked,
        "TrackedKeyPackage",
        &[
            published.d_tag.as_str(),
            &published.event.id.to_hex(),
            &staged.event.id.to_hex(),
            &device.keys.public_key().to_hex(),
            &hex::encode(published.key_package.bytes()),
        ]
    );
}

/// The record — slot, signed event, package — sits in the MLS database, and
/// none of it is readable in the file or its sidecars.
#[tokio::test]
async fn the_tracked_key_package_is_encrypted_at_rest() {
    let device = Device::new();
    let published = device.publish(None).await;
    let tracked = device.tracked().await;
    assert_eq!(
        tracked.slot, published.d_tag,
        "anti-vacuity: the record really holds what is scanned for"
    );
    let needles: [Vec<u8>; 4] = [
        published.d_tag.clone().into_bytes(),
        published.event.id.to_hex().into_bytes(),
        published.event.sig.to_string().into_bytes(),
        published.key_package.bytes().to_vec(),
    ];

    let Device { session, dir, .. } = device;
    let db = StorageConfig::new(dir.path()).database_path();
    let scan = |phase: &str| {
        let mut scanned = false;
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let mut path = db.clone().into_os_string();
            path.push(suffix);
            let Ok(bytes) = std::fs::read(&path) else {
                continue;
            };
            scanned |= !bytes.is_empty();
            for needle in &needles {
                assert!(
                    !bytes.windows(needle.len()).any(|w| w == needle.as_slice()),
                    "a tracked KeyPackage value is readable at rest ({phase})"
                );
            }
        }
        assert!(scanned, "the scan must have read the database ({phase})");
    };
    scan("session open");
    drop(session);
    scan("session closed");
}
