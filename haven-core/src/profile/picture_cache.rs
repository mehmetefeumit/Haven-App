//! Pure reconciliation logic between a member's kind-0 `picture` URL and the
//! locally cached picture bytes.
//!
//! The picture bytes live in the `profile_pictures` table (keyed by pubkey),
//! separate from the kind-0 metadata cache. Each cached-bytes row records the
//! URL the bytes were downloaded from. When a member changes or removes their
//! `picture`, the kind-0 `picture` URL changes/clears but the byte cache does
//! not automatically follow — so a viewer would render stale bytes forever.
//!
//! These two pure functions define, in one place, when cached bytes are still
//! "current" ([`picture_is_current`], which drives the FFI `has_picture` flag)
//! and what the download path must do to reconcile the cache
//! ([`picture_sync_action`]). Keeping them pure (no I/O) makes the
//! changed-URL / cleared-URL invariants exhaustively unit-testable and keeps the
//! FFI orchestration a thin translation of these decisions.

/// Trims `value` and returns it only when it is present and not
/// whitespace-only — a blank `picture` field means "no picture".
fn non_blank(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|s| !s.is_empty())
}

/// Whether the cached picture bytes are still current for the kind-0 `picture`
/// URL.
///
/// * `current_url` — the kind-0 `picture` field (`None` / blank means the user
///   currently has no picture).
/// * `cached_url` — the URL stored alongside the cached bytes (`None` means no
///   bytes are cached).
///
/// Returns `true` **only** when bytes are cached AND their URL equals the
/// current kind-0 URL. A changed URL, a cleared URL, or absent bytes all make
/// the cached bytes stale (`false`) — which is exactly the condition under
/// which the caller must re-download or clear.
#[must_use]
pub fn picture_is_current(current_url: Option<&str>, cached_url: Option<&str>) -> bool {
    matches!(
        (non_blank(current_url), non_blank(cached_url)),
        (Some(current), Some(cached)) if current == cached
    )
}

/// The action the picture-download path must take to reconcile the byte cache
/// with the member's current kind-0 `picture` URL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PictureSyncAction {
    /// Cached bytes already match the current URL (or there is nothing to do):
    /// no network and no cache mutation.
    Skip,
    /// The current URL is present and differs from the cached bytes' URL (or no
    /// bytes are cached): download the current URL and overwrite the cache.
    Download,
    /// The current URL is absent/blank but stale bytes are cached: delete the
    /// cached row so a removed avatar stops rendering.
    Clear,
}

/// Decides how the download path reconciles the cache.
///
/// Given the member's current kind-0 `picture` URL (`current_url`) and the URL
/// recorded with any cached bytes (`cached_url`, `None` when no bytes are
/// cached), this is authoritative: it makes the existing Dart gate
/// `if (!hasPicture) downloadMemberPicture(..)` correct for every transition —
/// a changed URL downloads the new bytes, a removed URL clears the stale row,
/// and an unchanged URL is a no-op.
#[must_use]
pub fn picture_sync_action(
    current_url: Option<&str>,
    cached_url: Option<&str>,
) -> PictureSyncAction {
    match non_blank(current_url) {
        // No current picture: clear stale bytes if a row exists, else nothing.
        None if cached_url.is_some() => PictureSyncAction::Clear,
        None => PictureSyncAction::Skip,
        // Current picture unchanged from the cached bytes' URL → no-op.
        Some(current) if non_blank(cached_url) == Some(current) => PictureSyncAction::Skip,
        // Current picture present and changed (or no bytes yet) → (re)download.
        Some(_) => PictureSyncAction::Download,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const URL_A: &str = "https://blossom.example/aaaa";
    const URL_B: &str = "https://blossom.example/bbbb";

    #[test]
    fn is_current_true_only_when_bytes_match_url() {
        assert!(picture_is_current(Some(URL_A), Some(URL_A)));
    }

    #[test]
    fn is_current_false_when_url_changed() {
        // Bytes cached under an OLD url; the kind-0 now points elsewhere → stale.
        assert!(!picture_is_current(Some(URL_B), Some(URL_A)));
    }

    #[test]
    fn is_current_false_when_picture_cleared() {
        // kind-0 has no picture but stale bytes are still cached → stale.
        assert!(!picture_is_current(None, Some(URL_A)));
        assert!(!picture_is_current(Some("   "), Some(URL_A)));
    }

    #[test]
    fn is_current_false_when_no_bytes() {
        assert!(!picture_is_current(Some(URL_A), None));
        assert!(!picture_is_current(None, None));
    }

    #[test]
    fn is_current_ignores_surrounding_whitespace() {
        assert!(picture_is_current(Some(URL_A), Some(&format!(" {URL_A} "))));
    }

    #[test]
    fn sync_action_download_when_url_changed() {
        assert_eq!(
            picture_sync_action(Some(URL_B), Some(URL_A)),
            PictureSyncAction::Download
        );
    }

    #[test]
    fn sync_action_download_when_no_bytes_yet() {
        assert_eq!(
            picture_sync_action(Some(URL_A), None),
            PictureSyncAction::Download
        );
    }

    #[test]
    fn sync_action_skip_when_url_matches() {
        assert_eq!(
            picture_sync_action(Some(URL_A), Some(URL_A)),
            PictureSyncAction::Skip
        );
    }

    #[test]
    fn sync_action_clear_when_picture_removed_and_bytes_cached() {
        assert_eq!(
            picture_sync_action(None, Some(URL_A)),
            PictureSyncAction::Clear
        );
        assert_eq!(
            picture_sync_action(Some(""), Some(URL_A)),
            PictureSyncAction::Clear
        );
    }

    #[test]
    fn sync_action_skip_when_no_picture_and_no_bytes() {
        assert_eq!(picture_sync_action(None, None), PictureSyncAction::Skip);
    }
}
