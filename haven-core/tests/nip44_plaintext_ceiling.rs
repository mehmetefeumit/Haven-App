//! The NIP-44 v2 plaintext ceiling, gated as the dependency invariant it is,
//! and the invite it refuses.
//!
//! `nostr`'s v2 codec refuses a plaintext longer than its
//! `MAX_SUPPORTED_PLAINTEXT_SIZE` (`nostr-0.44.8/src/nips/nip44/v2.rs:35`,
//! refused in `pad` at `:334-336`) on the client, before any socket opens. Every
//! Welcome crosses it twice (the NIP-59 seal and wrap are each a NIP-44 layer),
//! so an oversized Welcome never reaches the relay size cap the soak's S22
//! grades. It is a function of one length, which is why it is proved here rather
//! than in a soak world (soak plan decision 0.12).
//!
//! The constant is private, so the ceiling is pinned by BEHAVIOUR at its edge —
//! the longest plaintext that encrypts and the first that is refused — on the
//! path the NIP-59 layers call (`nip44::encrypt`). A dependency bump that moves
//! the edge fails here. Then the product: an invite whose Welcome crosses it
//! puts nothing on the wire, and one that does not is sent.
//!
//! Rule 15: no plaintext, key or length is rendered by any assertion.

use haven_core::circle::{CircleConfig, CircleError, CircleManager, MemberKeyPackage};
use haven_core::nostr::mls::SessionManager;
use haven_core::nostr::NostrError;
use haven_core::relay::fanout::{DriveMode, EvolutionStatus, Publishing, WallClock};
use haven_core::relay::maintenance::build_kp_maintenance_events;
use haven_core::relay::recording_front::{RecordedFrame, RecordingFront};
use haven_core::relay::RelayManager;
use nostr::key::Keys;
use nostr::nips::nip44::{self, v2::ErrorV2, Version};
use nostr_relay_builder::{LocalRelay, RelayBuilder};
use tempfile::TempDir;

/// The ceiling as the dependency spells its private constant.
const CEILING: usize = 65_536 - 128;

#[test]
fn a_plaintext_one_byte_past_the_ceiling_is_refused_and_one_at_it_is_not() {
    let sender = Keys::generate();
    let receiver = Keys::generate().public_key();
    let at = "x".repeat(CEILING);
    let past = "x".repeat(CEILING + 1);

    assert!(
        nip44::encrypt(sender.secret_key(), &receiver, &at, Version::V2).is_ok(),
        "a plaintext exactly at the NIP-44 ceiling must encrypt on the NIP-59 layer's path"
    );
    assert!(
        matches!(
            nip44::encrypt(sender.secret_key(), &receiver, &past, Version::V2),
            Err(nip44::Error::V2(ErrorV2::MessageTooLong))
        ),
        "one byte past the ceiling must be refused as too long, before any relay sees it"
    );
}

/// Invitees whose one Welcome carries a ratchet tree and a group secret for
/// each of them: enough that its NIP-59 layers cross the ceiling. At this pin
/// the wrap refuses from 60 on (measured); this is a third past that.
const OVERSIZED_INVITE: usize = 80;

/// A prospective member's key package, minted on a store of its own and
/// published nowhere, whose Welcome is to go to `inbox`.
async fn invitee(inbox: &str) -> (String, MemberKeyPackage) {
    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let session = SessionManager::new_unencrypted(dir.path(), &keys).expect("session");
    let event = build_kp_maintenance_events(&session, &keys, &[inbox.to_owned()], None, None)
        .await
        .expect("a key package")
        .event;
    let member = MemberKeyPackage {
        key_package_event: event,
        inbox_relays: vec![inbox.to_owned()],
        nip65_relays: vec![],
        nip65_write_relays: vec![],
    };
    (keys.public_key().to_hex(), member)
}

/// The `(kind, tag)` of each `EVENT` frame, where `tag` is the value of its
/// `name` tag.
fn events_tagged(frames: &[RecordedFrame], name: &str) -> Vec<(u64, String)> {
    frames
        .iter()
        .filter_map(|frame| serde_json::from_str::<serde_json::Value>(&frame.text).ok())
        .filter(|message| message[0] == "EVENT")
        .filter_map(|message| {
            let event = &message[1];
            let tag = event["tags"]
                .as_array()?
                .iter()
                .find_map(|tag| (tag[0] == name).then(|| tag[1].as_str().map(str::to_owned))?)?;
            Some((event["kind"].as_u64()?, tag))
        })
        .collect()
}

/// An invite whose Welcome is past the ceiling fails through today's error
/// path — the peeler's wrap refusal, an engine error, the circle change
/// failing — and neither its commit nor any Welcome reaches the relay, and its
/// circle's epoch stays where it was. The fence, and the control: an invite
/// under the ceiling, made after the refusal returned, is sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing() {
    let relay = LocalRelay::new(RelayBuilder::default());
    relay.run().await.expect("the relay runs");
    let front = RecordingFront::start(&relay.url().await.to_string());
    let url = front.url().to_owned();

    let dir = TempDir::new().expect("temp dir");
    let keys = Keys::generate();
    let admin = CircleManager::new_unencrypted(dir.path(), &keys).expect("circle manager");
    let config = |name: &str| CircleConfig::new(name).with_relays([url.clone()]);
    let big = admin
        .create_circle(&keys, Vec::new(), &config("Big"))
        .await
        .expect("the circle is founded")
        .circle;
    let small = admin
        .create_circle(&keys, Vec::new(), &config("Small"))
        .await
        .expect("the control circle is founded")
        .circle;
    let probe = admin
        .create_circle(&keys, Vec::new(), &config("Probe"))
        .await
        .expect("the probe circle is founded")
        .circle;

    let publisher = RelayManager::new();
    let transport = publisher.fanout_transport();
    let driver = Publishing {
        fanout: &transport,
        publisher: &publisher,
        clock: &WallClock,
        deadline_ms: None,
        mode: &DriveMode::Full,
    };

    let mut oversized = Vec::with_capacity(OVERSIZED_INVITE);
    for _ in 0..OVERSIZED_INVITE {
        oversized.push(invitee(&url).await);
    }
    let members: Vec<MemberKeyPackage> = oversized.iter().map(|(_, m)| m.clone()).collect();

    // Premise: the engine refuses this invite in the peeler's wrap — the code
    // the circle change below reduces to its generic failure.
    let packages = members
        .iter()
        .map(|m| SessionManager::key_package_from_event(&m.key_package_event).expect("parses"))
        .collect();
    assert!(
        matches!(
            admin
                .session()
                .add_members_staging(&probe.mls_group_id, packages, 0)
                .await,
            Err(NostrError::MdkError("peeler"))
        ),
        "premise: the engine's refusal of this invite is not the wrap's",
    );

    let epoch = admin
        .session()
        .epoch(&big.mls_group_id)
        .await
        .expect("epoch");
    let refused = driver
        .add_members(&admin, &big.mls_group_id, &members)
        .await;
    assert!(
        matches!(refused, Err(CircleError::Mls(_))),
        "an invite whose Welcome is past the NIP-44 ceiling was not refused",
    );
    assert_eq!(
        admin
            .session()
            .epoch(&big.mls_group_id)
            .await
            .expect("epoch"),
        epoch,
        "a refused invite moved its circle's epoch",
    );

    let (control, member) = invitee(&url).await;
    let sent = driver
        .add_members(&admin, &small.mls_group_id, &[member])
        .await
        .expect("an invite under the ceiling is made");
    assert_eq!(sent.status, EvolutionStatus::Confirmed);
    assert_eq!((sent.welcomes_sent, sent.welcomes_total), (1, 1));

    let frames = front.frames();
    let small_h = hex::encode(small.nostr_group_id);
    assert!(
        events_tagged(&frames, "h").contains(&(445, small_h))
            && events_tagged(&frames, "p").contains(&(1059, control)),
        "premise: the control's commit and Welcome are on the wire, after the refusal",
    );
    let big_h = hex::encode(big.nostr_group_id);
    assert!(
        !events_tagged(&frames, "h")
            .iter()
            .any(|(kind, h)| *kind == 445 && *h == big_h),
        "the refused invite's commit reached the relay",
    );
    assert!(
        !events_tagged(&frames, "p")
            .iter()
            .any(|(kind, p)| *kind == 1059 && oversized.iter().any(|(invited, _)| invited == p)),
        "a Welcome of the refused invite reached the relay",
    );
}
