//! Compile-time configuration and relay-set selection for the public-profile
//! module.
//!
//! Every tunable lives here in one place. The relay helpers deliberately reach
//! only into `crate::relay::discovery` (the AUTH-free discovery plane) — never
//! `crate::circle` — so the profile fetch/publish paths never ride a circle's
//! relays or carry any group identifier.

use std::time::Duration;

/// Re-export of the canonical avatar MIME type (`image/jpeg`). Profile pictures
/// use the same re-encode format as the avatar pipeline.
pub use crate::avatar::AVATAR_MIME;

/// Time-to-live for a cached profile before a fetch is considered stale
/// (6 hours, in seconds). Matches the White Noise refresh cadence.
pub const PROFILE_TTL_SECS: i64 = 6 * 3600;

/// Maximum authors per batched kind-0 `REQ`. The union of all known member
/// pubkeys is chunked into requests of at most this size (defensive bound
/// against non-pruning relays and oversized filters).
pub const PROFILE_FETCH_MAX_AUTHORS: usize = 500;

/// Bounded timeout for a one-shot profile (kind-0) relay fetch.
pub const PROFILE_FETCH_TIMEOUT: Duration = Duration::from_secs(10);

/// Bounded timeout for a Blossom upload/download HTTP round-trip.
pub const BLOSSOM_TIMEOUT: Duration = Duration::from_secs(30);

/// Lifetime, in seconds, of a Blossom kind-24242 authorization event's
/// `expiration` tag (stamped `now + this`). Short-lived by design.
pub const BLOSSOM_AUTH_EXPIRY_SECS: u64 = 60;

/// Default Blossom server for profile-picture hosting (White Noise parity).
/// MUST be `https://` — enforced by the CI privacy guard.
pub const DEFAULT_BLOSSOM_SERVER: &str = "https://blossom.primal.net";

/// Process-static install-once override for the Blossom upload server, **debug
/// builds only**. Lets the hermetic e2e harness point profile-picture UPLOADS
/// at a local Blossom (`http://10.0.2.2:3000` on the Android emulator,
/// `http://localhost:3000` on the iOS simulator/host) instead of the production
/// default, without ever affecting a release binary. Mirrors the install-once
/// `relay::set_default_relays_for_test` override discipline.
#[cfg(debug_assertions)]
static BLOSSOM_SERVER_FOR_TEST: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// The Blossom server URL profile-picture uploads target.
///
/// Returns [`DEFAULT_BLOSSOM_SERVER`] in production. In debug builds an e2e
/// override installed via [`set_blossom_server_for_test`] wins; release builds
/// can never install one (the setter is a fail-closed stub), so this always
/// returns the hard-coded HTTPS default there. The returned URL is still passed
/// through `blossom::require_https`, which permits plaintext `http://` only for
/// the loopback/emulator allowlist in debug builds.
#[must_use]
pub fn blossom_server() -> String {
    #[cfg(debug_assertions)]
    if let Some(url) = BLOSSOM_SERVER_FOR_TEST.get() {
        return url.clone();
    }
    DEFAULT_BLOSSOM_SERVER.to_string()
}

/// Overrides the Blossom upload server for hermetic e2e tests (**debug only**).
///
/// Intended to be called once from a scenario's `setUpAll` (alongside
/// `set_discovery_relays_for_test` and `allow_private_blossom_for_test`) so
/// `upload_my_profile_picture` targets the local Blossom container/binary.
///
/// # Errors
///
/// * Returns an error if `url` is empty.
/// * Returns an error if the override has already been installed in this
///   process (`OnceLock` install-once semantics).
/// * In release builds this is unreachable; the sibling stub always errors.
#[cfg(debug_assertions)]
pub fn set_blossom_server_for_test(url: String) -> std::result::Result<(), String> {
    if url.is_empty() {
        return Err("blossom server override must not be empty".to_string());
    }
    BLOSSOM_SERVER_FOR_TEST
        .set(url)
        .map_err(|_existing| "set_blossom_server_for_test already installed".to_string())
}

/// Release stub for [`set_blossom_server_for_test`] — always errors so release
/// callers fail closed and the production default is never overridable.
///
/// # Errors
///
/// Always returns an error.
#[cfg(not(debug_assertions))]
pub fn set_blossom_server_for_test(_url: String) -> std::result::Result<(), String> {
    Err("set_blossom_server_for_test is disabled in release builds".to_string())
}

/// Hard byte cap for a profile-picture DOWNLOAD (`512 KiB`).
///
/// Matches the untrusted-inbound avatar input cap
/// ([`crate::avatar::config::INBOUND_MAX_INPUT_BYTES`]). Enforced twice on the
/// download path: a `Content-Length` precheck (reject a header claiming more)
/// AND a streamed byte counter (reject a body that overruns even when the
/// header lies or is absent). A picture at the 512 px / ~90 KB canonical tier
/// is far under this.
pub const PROFILE_PICTURE_MAX_DOWNLOAD_BYTES: u64 = 512 * 1024;

/// Read-plane relays for resolving *other* users' kind-0 metadata.
///
/// The AUTH-free discovery plane ([`crate::relay::discovery::discovery_relays`]):
/// read-only, one-shot, and never a publish target — so a metadata read can
/// never be attributed to the local user (the fetch path never answers NIP-42
/// AUTH).
#[must_use]
pub fn profile_read_relays() -> Vec<String> {
    crate::relay::discovery::discovery_relays()
}

/// Write-plane relays for publishing the local user's own kind-0 / kind-24242.
///
/// Uses the user's NIP-65 **write** relays when configured (`user_nip65_write`,
/// typically produced by
/// [`crate::relay::RelayManager::extract_nip65_write_relays`]); otherwise falls
/// back to the discovery plane. Never a circle's relays.
///
/// The result may be empty (e.g. the user configured no write relays and the
/// discovery override is somehow empty in a test harness); publish callers MUST
/// fail closed on an empty set rather than broadcast to an unintended relay.
#[must_use]
pub fn profile_write_relays(user_nip65_write: &[String]) -> Vec<String> {
    if user_nip65_write.is_empty() {
        profile_read_relays()
    } else {
        user_nip65_write.to_vec()
    }
}

/// Relays to fetch the merge BASE from when editing the user's own kind-0.
///
/// The de-duplicated union of the read/discovery plane and the user's resolved
/// write relays. For a NIP-65 user whose write relays are **disjoint** from the
/// discovery plane, the freshest own kind-0 lives on the WRITE relays; fetching
/// the base from the read plane alone would miss it, so a subsequent edit could
/// silently drop `custom`/unknown fields written by another client (bug
/// MEDIUM-4). For a Haven-only user with no NIP-65 relay list, `write_relays`
/// falls back to the discovery plane, so this returns the read plane unchanged.
#[must_use]
pub fn self_merge_base_relays(write_relays: &[String]) -> Vec<String> {
    let mut relays = profile_read_relays();
    for relay in write_relays {
        if !relays.contains(relay) {
            relays.push(relay.clone());
        }
    }
    relays
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttl_is_six_hours() {
        assert_eq!(PROFILE_TTL_SECS, 21_600);
    }

    #[test]
    fn default_blossom_server_is_https() {
        assert!(DEFAULT_BLOSSOM_SERVER.starts_with("https://"));
    }

    #[test]
    fn avatar_mime_is_jpeg() {
        assert_eq!(AVATAR_MIME, "image/jpeg");
    }

    #[test]
    fn read_relays_are_non_empty_and_wss() {
        let relays = profile_read_relays();
        assert!(!relays.is_empty());
        assert!(relays.iter().all(|r| r.starts_with("wss://")));
    }

    #[test]
    fn write_relays_prefer_user_configured() {
        let user = vec!["wss://my.write.example".to_string()];
        assert_eq!(profile_write_relays(&user), user);
    }

    #[test]
    fn write_relays_fall_back_to_discovery() {
        // No user-configured write relays → discovery plane.
        let fallback = profile_write_relays(&[]);
        assert_eq!(fallback, profile_read_relays());
        assert!(!fallback.is_empty());
    }

    #[test]
    fn merge_base_includes_write_relays() {
        // A NIP-65 write relay disjoint from the discovery plane must appear in
        // the merge-base set so an own-edit reads its freshest kind-0 (MEDIUM-4).
        let write = vec!["wss://write.only.example".to_string()];
        let base = self_merge_base_relays(&write);
        assert!(
            base.contains(&"wss://write.only.example".to_string()),
            "the disjoint write relay must be in the merge-base set: {base:?}"
        );
        for read in profile_read_relays() {
            assert!(base.contains(&read), "the read plane must be retained too");
        }
    }

    #[test]
    fn merge_base_dedups_and_is_read_plane_without_nip65() {
        // No NIP-65 relays → the base is exactly the read plane (Haven-only user;
        // behavior unchanged). And a write relay already in the read plane is not
        // duplicated.
        assert_eq!(self_merge_base_relays(&[]), profile_read_relays());
        let dup = profile_read_relays();
        let base = self_merge_base_relays(&dup);
        assert_eq!(
            base, dup,
            "a write set equal to the read plane must not duplicate entries"
        );
    }
}
