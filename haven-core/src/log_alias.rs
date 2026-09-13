//! Per-process, salted log handles — the only shape in which a log line may
//! say "the same circle/peer/relay/event as that other line".
//!
//! # Why this exists
//!
//! Log anonymity is a project pillar (`CLAUDE.md`) and Security Rule 15:
//! nothing that tells one user, circle or device apart from another may reach a
//! log, a panic message, a `Debug`/`Display` rendering or an FFI error string —
//! in any build, at any level, in any encoding, at any truncation. A prefix of
//! an identifier is still an identifier, so shortening a group id or a pubkey
//! is not a redaction.
//!
//! A handle is `HMAC-SHA256(process_salt, class_tag ‖ 0x00 ‖ value)[..3]`
//! rendered as `circle#a91f3c`. It preserves the one property a log line
//! legitimately needs from an identifier — within-process correlation — and
//! nothing else. The salt is 32 [`OsRng`] bytes minted on first use, held in a
//! [`Zeroizing`] cell, never persisted, never exported and never logged, so a
//! captured log cannot be matched against a candidate value by anyone,
//! including the device that wrote it once the process is gone.
//!
//! The newtype arguments exist so the compiler, not a reviewer, decides what
//! may be aliased: a real MLS `GroupId` has no `NostrGroupId` conversion and so
//! cannot reach [`circle`] at all (Security Rule 4).
//!
//! # Residual
//!
//! A log still reveals how many DISTINCT handles of a class it mentions, and
//! that two lines concern the same one. That is what a handle is for, and the
//! accepted cost; it is bounded to a single process lifetime, and
//! [`rotate_salt`] is called on wipe/logout so no handle survives a wipe.
//!
//! # Non-goals
//!
//! Not a defence against an attacker who also has the live process memory (it
//! holds the salt). Not stable across processes or installs, not a storage key,
//! not reversible, and deliberately not collision-free: three bytes collide by
//! birthday after a few hundred values, which is irrelevant for triage and
//! preferable to a wider, better fingerprint.
//!
//! # Examples
//!
//! ```
//! use haven_core::log_alias::{self, NostrGroupId, PeerPubkey};
//! use haven_core::nostr::mls::types::GroupId;
//!
//! let group_id = [7u8; 32];
//! let handle = log_alias::circle(NostrGroupId(&group_id));
//! log::debug!("relay re-sync declined for {handle}");
//!
//! // The MLS group id constructs and reads fine — it simply cannot be aliased.
//! let mls_group_id = GroupId::new(vec![7u8; 32]);
//! assert_eq!(mls_group_id.as_slice().len(), 32);
//!
//! // The hex and `npub` spellings of one pubkey alias to one handle.
//! let hex = "e1d9e8e1e35d8a5a1a1dbe6d3e0aa1b9f5f0f2a3b4c5d6e7f8091a2b3c4d5e6f";
//! assert_eq!(
//!     log_alias::peer(PeerPubkey(hex)).to_string(),
//!     log_alias::peer(PeerPubkey(
//!         "npub1u8v73c0rtk995xsaheknuz4ph86lpu4rknzadelcpydzk0zdtehsppv8pq"
//!     ))
//!     .to_string(),
//! );
//! ```
//!
//! A real MLS group id is rejected at compile time. Everything but the call
//! itself compiles in the example above this one, so the failure below can only
//! be the argument type:
//!
//! ```compile_fail
//! use haven_core::log_alias::{self, NostrGroupId};
//! use haven_core::nostr::mls::types::GroupId;
//!
//! let mls_group_id = GroupId::new(vec![7u8; 32]);
//! let handle = log_alias::circle(NostrGroupId(&mls_group_id));
//! ```

use std::borrow::Cow;
use std::fmt;
use std::sync::{OnceLock, PoisonError, RwLock};

use hmac::{Hmac, Mac};
use nostr::PublicKey;
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::Sha256;
use zeroize::{Zeroize, Zeroizing};

/// The kind of thing a [`LogHandle`] stands for.
///
/// The variant is part of the hashed input, so the same bytes aliased as two
/// classes yield two unrelated handles — a pubkey that is also used as a
/// subscription seed cannot be correlated across the two roles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogAliasClass {
    /// A circle, keyed by its `nostr_group_id`.
    Circle,
    /// A member or peer, keyed by their Nostr public key.
    Peer,
    /// A Nostr event, keyed by its id.
    Event,
    /// A relay, keyed by its URL.
    Relay,
    /// A published `KeyPackage`, keyed by its `d` slot.
    KeyPackage,
    /// A relay subscription, keyed by its subscription id.
    Subscription,
}

impl LogAliasClass {
    /// The rendered prefix, and the domain-separation tag in the hashed input.
    const fn tag(self) -> &'static str {
        match self {
            Self::Circle => "circle",
            Self::Peer => "peer",
            Self::Event => "event",
            Self::Relay => "relay",
            Self::KeyPackage => "key_package",
            Self::Subscription => "subscription",
        }
    }
}

/// A circle's `nostr_group_id` (never the MLS `GroupId` — Security Rule 4).
#[derive(Clone, Copy)]
pub struct NostrGroupId<'a>(pub &'a [u8; 32]);

/// A Nostr public key, as 64-char hex or as `npub1…`.
#[derive(Clone, Copy)]
pub struct PeerPubkey<'a>(pub &'a str);

/// A Nostr event id, as hex.
#[derive(Clone, Copy)]
pub struct EventIdHex<'a>(pub &'a str);

/// A relay URL, in any spelling.
#[derive(Clone, Copy)]
pub struct RelayUrl<'a>(pub &'a str);

/// A published `KeyPackage`'s `d`-tag slot.
#[derive(Clone, Copy)]
pub struct KeyPackageSlot<'a>(pub &'a str);

/// A relay subscription id.
#[derive(Clone, Copy)]
pub struct SubscriptionId<'a>(pub &'a str);

/// An opaque, per-process handle for one value of one [`LogAliasClass`].
///
/// Renders as `class#xxxxxx` (six lowercase hex), identically through
/// [`fmt::Display`] and [`fmt::Debug`] so `{}` and `{:?}` cannot differ in what
/// they disclose. Renders `class#??????` if the salt is unreachable: a log line
/// never fails and never falls back to the real value.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct LogHandle {
    class: LogAliasClass,
    digest: Option<[u8; 3]>,
}

impl LogHandle {
    /// The handle for a class whose digest could not be computed.
    const fn unavailable(class: LogAliasClass) -> Self {
        Self {
            class,
            digest: None,
        }
    }
}

impl fmt::Display for LogHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}#", self.class.tag())?;
        match self.digest {
            Some(bytes) => write!(f, "{:02x}{:02x}{:02x}", bytes[0], bytes[1], bytes[2]),
            None => f.write_str("??????"),
        }
    }
}

// `{:?}` must disclose exactly what `{}` does: a `Debug` that said more would
// leak through every `{:?}` of a struct that merely holds a handle.
impl fmt::Debug for LogHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

/// Aliases a circle by its `nostr_group_id`.
#[must_use]
pub fn circle(id: NostrGroupId<'_>) -> LogHandle {
    alias(LogAliasClass::Circle, id.0)
}

/// Aliases a peer by their public key, in hex or `npub1…` form.
#[must_use]
pub fn peer(pk: PeerPubkey<'_>) -> LogHandle {
    alias(LogAliasClass::Peer, pk.0.as_bytes())
}

/// Aliases a Nostr event by its id.
#[must_use]
pub fn event(id: EventIdHex<'_>) -> LogHandle {
    alias(LogAliasClass::Event, id.0.as_bytes())
}

/// Aliases a relay by its URL, in any spelling.
#[must_use]
pub fn relay(url: RelayUrl<'_>) -> LogHandle {
    alias(LogAliasClass::Relay, url.0.as_bytes())
}

/// Aliases a published `KeyPackage` by its `d`-tag slot.
#[must_use]
pub fn key_package(slot: KeyPackageSlot<'_>) -> LogHandle {
    alias(LogAliasClass::KeyPackage, slot.0.as_bytes())
}

/// Aliases a relay subscription by its id.
#[must_use]
pub fn subscription(id: SubscriptionId<'_>) -> LogHandle {
    alias(LogAliasClass::Subscription, id.0.as_bytes())
}

/// Aliases a raw value in `class`, for the FFI and for callers holding bytes.
///
/// Applies the same per-class normalisation the typed entry points do, so a
/// value aliased from Dart over the FFI and the same value aliased in Rust
/// render one handle.
#[must_use]
pub fn alias(class: LogAliasClass, value: &[u8]) -> LogHandle {
    let normalised = normalise(class, value);
    let keyed = {
        let cell = salt_cell().read().unwrap_or_else(PoisonError::into_inner);
        // `None` means the OS CSPRNG refused: a handle must still render, and
        // must NOT fall back to an unsalted digest, which would be computable.
        cell.as_ref()
            .map(|salt| Hmac::<Sha256>::new_from_slice(salt.as_slice()))
    };
    // HMAC accepts any key length, so the inner error is unreachable; a panic
    // here would take the caller's log line with it, so both the absent salt
    // and the impossible error map to `class#??????`.
    let Some(Ok(mut mac)) = keyed else {
        return LogHandle::unavailable(class);
    };
    mac.update(class.tag().as_bytes());
    mac.update(&[0x00]);
    mac.update(&normalised);
    let digest = mac.finalize().into_bytes();
    LogHandle {
        class,
        digest: Some([digest[0], digest[1], digest[2]]),
    }
}

/// Re-mints the process salt, invalidating every handle already rendered.
///
/// Called from the wipe/logout path: after a wipe no log line may still be
/// linkable to the identity that produced it.
pub fn rotate_salt() {
    let mut cell = salt_cell().write().unwrap_or_else(PoisonError::into_inner);
    // Wipe before the move so the old key is not left in the vacated bytes.
    if let Some(salt) = cell.as_mut() {
        salt.zeroize();
    }
    *cell = mint_salt();
}

/// The coarse magnitude of `count` — the only shape in which a log line may
/// state one.
///
/// An exact count of circles, members, relays or events fingerprints the user
/// (Security Rule 15); the policy buckets are `0`, `1`, `2-4` and `5+`, which
/// keep triage possible without doing so. The Dart mirror spells the same
/// policy `magnitudeBucket`.
#[must_use]
pub const fn bucket(count: usize) -> &'static str {
    match count {
        0 => "0",
        1 => "1",
        2..=4 => "2-4",
        _ => "5+",
    }
}

/// The process salt cell, minted on first use; `None` if the OS CSPRNG refused.
fn salt_cell() -> &'static RwLock<Option<Zeroizing<[u8; 32]>>> {
    static SALT: OnceLock<RwLock<Option<Zeroizing<[u8; 32]>>>> = OnceLock::new();
    SALT.get_or_init(|| RwLock::new(mint_salt()))
}

/// Mints 32 fresh salt bytes from the OS CSPRNG, or `None` if it failed.
///
/// `try_fill_bytes`, never `fill_bytes`: the infallible form PANICS when
/// `getrandom` fails, and this function is reached from inside log lines.
fn mint_salt() -> Option<Zeroizing<[u8; 32]>> {
    let mut bytes = Zeroizing::new([0u8; 32]);
    OsRng.try_fill_bytes(bytes.as_mut_slice()).ok()?;
    Some(bytes)
}

/// The canonical form of `value` for `class`.
///
/// Two spellings of one value must alias to one handle or the handle is
/// useless: a pubkey arrives as hex from the engine and as `npub1…` from the
/// UI, a relay URL with and without its trailing slash, a hex id in either
/// case. Anything unparseable is hashed verbatim — a handle is always produced,
/// never an error.
fn normalise(class: LogAliasClass, value: &[u8]) -> Cow<'_, [u8]> {
    let Ok(text) = std::str::from_utf8(value).map(str::trim) else {
        return Cow::Borrowed(value);
    };
    match class {
        // Canonical form is the raw 32 bytes, so a caller holding the byte array
        // and a caller holding the 64-hex spelling (the FFI, Dart) meet.
        LogAliasClass::Circle => decode_32(text).map_or(Cow::Borrowed(value), Cow::Owned),
        LogAliasClass::Peer => PublicKey::parse(text).map_or(Cow::Borrowed(value), |pk| {
            Cow::Owned(pk.to_bytes().to_vec())
        }),
        // Same 32-byte canonical form; a non-hex id (no Nostr event has one)
        // falls back to its lowercased text rather than to an error.
        LogAliasClass::Event => decode_32(text).map_or_else(
            || Cow::Owned(text.to_ascii_lowercase().into_bytes()),
            Cow::Owned,
        ),
        LogAliasClass::Relay => Cow::Owned(normalise_relay_url(text).into_bytes()),
        LogAliasClass::KeyPackage | LogAliasClass::Subscription => Cow::Borrowed(text.as_bytes()),
    }
}

/// The 32 bytes `text` spells in hex, if it spells exactly 32.
fn decode_32(text: &str) -> Option<Vec<u8>> {
    hex::decode(text).ok().filter(|bytes| bytes.len() == 32)
}

/// Lowercases a relay URL's scheme and host and drops trailing slashes.
///
/// Deliberately not [`crate::relay::url_norm::normalize_relay_url`]: that one
/// REJECTS what it cannot canonicalize, and an unaliasable value must never be
/// the reason a log line prints something else.
fn normalise_relay_url(value: &str) -> String {
    let trimmed = value.trim_end_matches('/');
    let Some(scheme_end) = trimmed.find("://") else {
        return trimmed.to_ascii_lowercase();
    };
    let authority_start = scheme_end + 3;
    let host_end = trimmed[authority_start..]
        .find(['/', '?', '#'])
        .map_or(trimmed.len(), |offset| authority_start + offset);
    let mut out = trimmed[..host_end].to_ascii_lowercase();
    out.push_str(&trimmed[host_end..]);
    out
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use nostr::prelude::ToBech32 as _;

    use super::{
        alias, bucket, circle, event, key_package, peer, relay, salt_cell, subscription,
        EventIdHex, KeyPackageSlot, LogAliasClass, LogHandle, NostrGroupId, PeerPubkey, RelayUrl,
        SubscriptionId,
    };
    use std::sync::PoisonError;

    /// Serializes the tests that rotate the salt against the tests that compare
    /// two handles: the salt is process-wide, so a rotation racing a comparison
    /// would be a genuine flake.
    static SALT: Mutex<()> = Mutex::new(());

    const HEX_PUBKEY: &str = "e1d9e8e1e35d8a5a1a1dbe6d3e0aa1b9f5f0f2a3b4c5d6e7f8091a2b3c4d5e6f";
    const NPUB_PUBKEY: &str = "npub1u8v73c0rtk995xsaheknuz4ph86lpu4rknzadelcpydzk0zdtehsppv8pq";

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        SALT.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Whether `haystack` contains any `window`-char run of `value`.
    fn shares_window(haystack: &str, value: &str, window: usize) -> bool {
        value
            .as_bytes()
            .windows(window)
            .filter_map(|run| std::str::from_utf8(run).ok())
            .any(|run| haystack.contains(run))
    }

    #[test]
    fn same_value_yields_the_same_handle() {
        let _guard = lock();
        let id = [3u8; 32];
        assert_eq!(
            circle(NostrGroupId(&id)).to_string(),
            circle(NostrGroupId(&id)).to_string()
        );
    }

    #[test]
    fn different_values_yield_different_handles() {
        let _guard = lock();
        assert_ne!(
            circle(NostrGroupId(&[3u8; 32])).to_string(),
            circle(NostrGroupId(&[4u8; 32])).to_string()
        );
    }

    #[test]
    fn classes_are_domain_separated() {
        let _guard = lock();
        let value = b"same-bytes-in-two-roles";
        let handles = [
            alias(LogAliasClass::Peer, value).to_string(),
            alias(LogAliasClass::Event, value).to_string(),
            alias(LogAliasClass::Relay, value).to_string(),
            alias(LogAliasClass::KeyPackage, value).to_string(),
            alias(LogAliasClass::Subscription, value).to_string(),
        ];
        let digests: std::collections::BTreeSet<&str> = handles
            .iter()
            .map(|handle| handle.split('#').nth(1).expect("handle has a digest"))
            .collect();
        assert_eq!(digests.len(), handles.len(), "{handles:?}");
    }

    #[test]
    fn hex_and_npub_spellings_agree() {
        let _guard = lock();
        assert_eq!(
            peer(PeerPubkey(HEX_PUBKEY)).to_string(),
            peer(PeerPubkey(NPUB_PUBKEY)).to_string()
        );
    }

    #[test]
    fn the_nip21_uri_spelling_agrees_too() {
        let _guard = lock();
        // `PublicKey::parse` accepts a `nostr:` URI, and the UI layer passes
        // pubkeys around in whichever spelling it received — an untested third
        // spelling would silently become a second handle for one person.
        assert_eq!(
            peer(PeerPubkey(HEX_PUBKEY)).to_string(),
            peer(PeerPubkey(&format!("nostr:{NPUB_PUBKEY}"))).to_string()
        );
    }

    #[test]
    fn different_peer_pubkeys_yield_different_handles() {
        let _guard = lock();
        // A second REAL, PARSEABLE key (not just different bytes): the risk this
        // guards against is `normalise`'s `PublicKey::parse` path collapsing two
        // distinct valid keys onto one normalised form, which a raw-bytes
        // comparison would never exercise.
        let other = nostr::Keys::generate().public_key().to_hex();
        assert_ne!(other, HEX_PUBKEY, "test vector collision — regenerate");
        assert_ne!(
            peer(PeerPubkey(HEX_PUBKEY)).to_string(),
            peer(PeerPubkey(&other)).to_string()
        );
        // ...and the npub spelling of that same second key must land on the
        // same handle as its own hex spelling, not on the first key's.
        let other_npub = nostr::PublicKey::parse(&other)
            .expect("generated key parses")
            .to_bech32()
            .expect("encodes as npub");
        assert_eq!(
            peer(PeerPubkey(&other)).to_string(),
            peer(PeerPubkey(&other_npub)).to_string()
        );
        assert_ne!(
            peer(PeerPubkey(&other_npub)).to_string(),
            peer(PeerPubkey(NPUB_PUBKEY)).to_string()
        );
    }

    #[test]
    fn group_id_bytes_and_hex_agree() {
        let _guard = lock();
        let id = [0xabu8; 32];
        assert_eq!(
            circle(NostrGroupId(&id)).to_string(),
            alias(LogAliasClass::Circle, hex::encode(id).as_bytes()).to_string()
        );
    }

    #[test]
    fn event_id_case_does_not_split_the_handle() {
        let _guard = lock();
        let id = "AB12CD34";
        assert_eq!(
            event(EventIdHex(id)).to_string(),
            event(EventIdHex(&id.to_lowercase())).to_string()
        );
    }

    #[test]
    fn event_id_bytes_and_hex_agree() {
        let _guard = lock();
        // Same canonical form as a circle's: a 64-hex id and the raw 32 bytes of
        // the same id are one handle, so a caller holding `EventId::as_bytes()`
        // and a caller holding `to_hex()` cannot produce two names for one event.
        let id = [0x3cu8; 32];
        let hex = hex::encode(id);
        assert_eq!(
            event(EventIdHex(&hex)).to_string(),
            alias(LogAliasClass::Event, &id).to_string()
        );
        // And the uppercase spelling still collapses onto it.
        assert_eq!(
            event(EventIdHex(&hex.to_uppercase())).to_string(),
            event(EventIdHex(&hex)).to_string()
        );
    }

    #[test]
    fn relay_url_trailing_slash_and_case_do_not_split_the_handle() {
        let _guard = lock();
        let canonical = relay(RelayUrl("wss://relay.example.com")).to_string();
        assert_eq!(
            relay(RelayUrl("wss://relay.example.com/")).to_string(),
            canonical
        );
        assert_eq!(
            relay(RelayUrl("WSS://Relay.Example.COM")).to_string(),
            canonical
        );
        assert_eq!(
            relay(RelayUrl("  wss://relay.example.com  ")).to_string(),
            canonical
        );
    }

    #[test]
    fn relay_url_path_case_is_preserved() {
        let _guard = lock();
        assert_ne!(
            relay(RelayUrl("wss://relay.example.com/Inbox")).to_string(),
            relay(RelayUrl("wss://relay.example.com/inbox")).to_string()
        );
    }

    #[test]
    fn schemeless_relay_value_still_aliases() {
        let _guard = lock();
        assert_eq!(
            relay(RelayUrl("Relay.Example.COM")).to_string(),
            relay(RelayUrl("relay.example.com")).to_string()
        );
    }

    #[test]
    fn invalid_pubkey_still_yields_a_handle() {
        let _guard = lock();
        let handle = peer(PeerPubkey("not-a-pubkey")).to_string();
        assert!(handle.starts_with("peer#"), "{handle}");
        assert!(!handle.contains('?'), "{handle}");
    }

    #[test]
    fn non_utf8_value_still_yields_a_handle() {
        let _guard = lock();
        let handle = alias(LogAliasClass::Subscription, &[0xff, 0xfe, 0x00]).to_string();
        assert!(handle.starts_with("subscription#"), "{handle}");
        assert!(!handle.contains('?'), "{handle}");
    }

    #[test]
    fn rotation_changes_every_handle() {
        let _guard = lock();
        let id = [5u8; 32];
        let before = circle(NostrGroupId(&id)).to_string();
        super::rotate_salt();
        let after = circle(NostrGroupId(&id)).to_string();
        assert_ne!(before, after);
        // Still a well-formed handle, and still stable within the new salt.
        assert_eq!(after, circle(NostrGroupId(&id)).to_string());
    }

    #[test]
    fn class_tag_shares_no_run_of_the_value() {
        // The DIGEST half of a handle is an HMAC output over an unpredictable
        // per-process salt: a random 4-char run of it landing inside a value
        // that is itself mostly hex (a 64-char hex pubkey has 61 overlapping
        // 4-char windows) is an expected, non-adversarial coincidence, not a
        // leak — asserting against it here made this test's pass/fail depend
        // on the process's random salt draw (empirically ~1 in 40 runs).
        // What must never coincide, independent of any salt, is the class
        // TAG itself (`circle`, `peer`, …), which is why the relay fixture
        // below deliberately avoids the substring "relay". The digest's own
        // shape (six lowercase hex chars) is pinned by
        // `rendering_is_a_class_prefix_and_six_lowercase_hex`; its
        // independence from the raw value is pinned by
        // `rotation_changes_every_handle` and the agreement/domain-separation
        // tests above.
        const RELAY_URL: &str = "wss://needle-vault-zephyr.example.com";
        const RELAY_HOST: &str = "needle-vault-zephyr.example.com";

        let _guard = lock();
        let bytes = hex::decode(HEX_PUBKEY).expect("test vector is hex");
        let id: [u8; 32] = bytes.try_into().expect("test vector is 32 bytes");
        for handle in [
            circle(NostrGroupId(&id)).to_string(),
            peer(PeerPubkey(HEX_PUBKEY)).to_string(),
            peer(PeerPubkey(NPUB_PUBKEY)).to_string(),
            event(EventIdHex(HEX_PUBKEY)).to_string(),
            key_package(KeyPackageSlot("haven-kp-slot-0")).to_string(),
            subscription(SubscriptionId("a1b2c3d4_inbox_0")).to_string(),
            relay(RelayUrl(RELAY_URL)).to_string(),
        ] {
            let (tag, digest) = handle.split_once('#').expect("handle has a '#'");
            assert_eq!(digest.len(), 6, "{handle}");
            for value in [
                HEX_PUBKEY,
                NPUB_PUBKEY,
                "haven-kp-slot-0",
                "a1b2c3d4_inbox_0",
                RELAY_URL,
                RELAY_HOST,
            ] {
                assert!(
                    !shares_window(tag, value, 4),
                    "{tag} (from {handle}) shares a 4-char run with {value}"
                );
            }
        }
    }

    #[test]
    fn display_and_debug_are_identical() {
        let _guard = lock();
        let handle = peer(PeerPubkey(HEX_PUBKEY));
        assert_eq!(format!("{handle}"), format!("{handle:?}"));
    }

    #[test]
    fn rendering_is_a_class_prefix_and_six_lowercase_hex() {
        let _guard = lock();
        let cases = [
            ("circle", circle(NostrGroupId(&[1u8; 32])).to_string()),
            ("peer", peer(PeerPubkey(HEX_PUBKEY)).to_string()),
            ("event", event(EventIdHex("abc")).to_string()),
            ("relay", relay(RelayUrl("wss://a.example")).to_string()),
            (
                "key_package",
                key_package(KeyPackageSlot("slot")).to_string(),
            ),
            (
                "subscription",
                subscription(SubscriptionId("sub")).to_string(),
            ),
        ];
        for (class, rendered) in cases {
            let (prefix, digest) = rendered.split_once('#').expect("handle has a '#'");
            assert_eq!(prefix, class, "{rendered}");
            assert_eq!(digest.len(), 6, "{rendered}");
            assert!(
                digest
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
                "{rendered}"
            );
        }
    }

    #[test]
    fn unavailable_salt_renders_question_marks() {
        assert_eq!(
            LogHandle::unavailable(LogAliasClass::Circle).to_string(),
            "circle#??????"
        );
        assert_eq!(
            format!("{:?}", LogHandle::unavailable(LogAliasClass::Peer)),
            "peer#??????"
        );
    }

    #[test]
    fn poisoned_salt_lock_still_yields_a_handle() {
        let _guard = lock();
        let id = [8u8; 32];
        let before = circle(NostrGroupId(&id)).to_string();
        // A panic while holding the write guard poisons the lock for the rest of
        // the process; every later handle must still render.
        let poisoner = std::thread::spawn(|| {
            let _held = salt_cell().write().unwrap_or_else(PoisonError::into_inner);
            panic!("poisoning the salt lock on purpose");
        });
        assert!(poisoner.join().is_err(), "the poisoner must have panicked");
        assert!(salt_cell().read().is_err(), "the lock must be poisoned");
        let after = circle(NostrGroupId(&id)).to_string();
        assert_eq!(before, after);
        assert!(!after.contains('?'), "{after}");
    }

    #[test]
    fn log_handle_debug_redacts_and_display_redacts_the_value() {
        let _guard = lock();
        let handle: LogHandle = peer(PeerPubkey(HEX_PUBKEY));
        crate::assert_debug_redacted!(
            &handle,
            "LogHandle",
            marker = "peer#",
            &[HEX_PUBKEY, NPUB_PUBKEY]
        );
        crate::assert_display_redacted!(
            &handle,
            "LogHandle",
            marker = "peer#",
            &[HEX_PUBKEY, NPUB_PUBKEY]
        );
    }

    #[test]
    fn a_handle_renders_question_marks_when_the_salt_is_absent() {
        let _guard = lock();
        // The OS CSPRNG refusing is the only way this happens in production
        // (`mint_salt` returns `None` rather than panicking); the effect must be
        // an unresolvable handle, never an unsalted — computable — digest.
        let restore = {
            let mut cell = salt_cell().write().unwrap_or_else(PoisonError::into_inner);
            cell.take()
        };
        let handle = circle(NostrGroupId(&[6u8; 32])).to_string();
        *salt_cell().write().unwrap_or_else(PoisonError::into_inner) = restore;

        assert_eq!(handle, "circle#??????");
        // And the salt comes back, so the rest of the suite is unaffected.
        assert!(!circle(NostrGroupId(&[6u8; 32])).to_string().contains('?'));
    }

    #[test]
    fn buckets_never_state_an_exact_magnitude() {
        assert_eq!(bucket(0), "0");
        assert_eq!(bucket(1), "1");
        assert_eq!(bucket(2), "2-4");
        assert_eq!(bucket(4), "2-4");
        assert_eq!(bucket(5), "5+");
        assert_eq!(bucket(9_001), "5+");
    }

    #[test]
    fn class_debug_is_only_a_variant_name() {
        assert_eq!(format!("{:?}", LogAliasClass::KeyPackage), "KeyPackage");
    }
}
