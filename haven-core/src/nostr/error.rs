//! Error types for Nostr operations.

use thiserror::Error;

use crate::nostr::mls::storage::SESSION_BUSY_MARKER;

/// Errors that can occur during Nostr event construction and encryption.
///
/// # Neither rendering discloses a payload (Security Rule 15)
///
/// Every `String` below carries an engine, peeler, `SQLCipher` or `serde` message
/// that Haven does not author and cannot bound: those quote group ids,
/// `KeyPackageRef`s, event ids, epochs and relay URLs. So `Display` renders the
/// variant's own Haven-authored sentence and `Debug` renders
/// [`code`](Self::code) — the payload stays on the variant for a caller that
/// wants to branch on it, and reaches no log line, panic message or FFI string.
/// Only `{:?}` of the inner `String` itself can surface it, which is why no
/// production site does that.
#[derive(Error)]
pub enum NostrError {
    /// MLS group operation failed.
    #[error("MLS group operation failed")]
    MlsGroup(String),

    /// Encryption operation failed.
    #[error("Encryption failed")]
    Encryption(String),

    /// Decryption operation failed.
    #[error("Decryption failed")]
    Decryption(String),

    /// Key derivation failed.
    #[error("Key derivation failed")]
    KeyDerivation(String),

    /// Event signing failed.
    #[error("Event signing failed")]
    Signing(String),

    /// Serialization failed.
    #[error("Serialization failed")]
    Serialization(#[from] serde_json::Error),

    /// Invalid event structure or content.
    #[error("Invalid event")]
    InvalidEvent(String),

    /// Exporter secret is not available (wrong epoch or not in group).
    ///
    /// The epoch is carried for a caller that wants to branch on it, and
    /// deliberately NOT rendered: an absolute epoch number tells one circle's
    /// history apart from another's (Security Rule 15).
    #[error("Exporter secret unavailable for the requested epoch")]
    ExporterSecretUnavailable(u64),

    /// Event has expired (NIP-40).
    #[error("Event has expired")]
    Expired,

    /// Event signature verification failed.
    #[error("Invalid event signature")]
    InvalidSignature,

    /// Hex encoding/decoding error.
    #[error("Hex encoding error")]
    HexError(String),

    /// MDK operation failed.
    #[error("MDK error")]
    MdkError(String),

    /// A still-admin caller attempted to leave a group. Haven's stable
    /// mapping of the engine's typed `AdminCannotSelfRemove` rejection
    /// (matched on the variant, never on upstream message text): the message
    /// names the actionable remediation — self-demote (leave the admin set)
    /// first — so UI/tests can route on it, and carries no group id.
    #[error("admin cannot leave the circle yet: self-demote (leave the admin set) first")]
    AdminSelfDemoteRequired,

    /// The engine refused a commit because the group's epoch state is not
    /// `Stable` (a commit is staged, merging, recovering, or unrecoverable).
    ///
    /// Haven's stable mapping of `EngineError::InvalidTransition` whose `from`
    /// token names an `EpochState` variant. Matched on the TOKEN, which
    /// `EpochState::name()` derives from the enum, never on the surrounding
    /// message text — see `SessionManager::update_admin_policy`. Carries no
    /// group id, no epoch, and no state name: the caller already knows which
    /// circle it asked about, and the state itself is transient engine
    /// bookkeeping the user cannot act on.
    #[error("the circle's group state is busy; try again shortly")]
    EpochNotStable,

    /// The engine has frozen this group at its last stable epoch
    /// (`EpochState::Unrecoverable`) and refuses to apply or ingest further
    /// group state.
    ///
    /// Split from [`Self::EpochNotStable`] because the two need opposite
    /// handling: that one clears on its own and invites a retry, this one never
    /// does, so presenting it as "try again shortly" would put the user in a
    /// loop that cannot succeed. Carries no group id and no epoch.
    #[error("the circle's group state cannot be repaired on this device")]
    EpochUnrecoverable,

    /// Group not found.
    ///
    /// The payload IS a group id, so it is the one variant whose `Display` was
    /// never safe at any truncation.
    #[error("Group not found")]
    GroupNotFound(String),

    /// Invalid welcome message.
    #[error("Invalid welcome message")]
    InvalidWelcome(String),

    /// Storage operation failed.
    #[error("Storage error")]
    StorageError(String),

    /// An MLS session is already open on this database (Security Rule 14).
    ///
    /// Its own variant rather than a [`Self::StorageError`] carrying the marker
    /// in its payload, because a payload no longer renders at all and
    /// [`SESSION_BUSY_MARKER`] is Haven-authored text, not an identifier.
    ///
    /// What actually puts the marker in a log is the `warn!` at the refusal
    /// itself (`LiveSessionGuard::acquire`): no log site interpolates an error's
    /// `Display`, and the production caller converts this to
    /// `CircleError::Mls`, whose payload is hidden. The marker in the sentence
    /// above is the second line of defence, for an FFI surface that flattens
    /// `Display` rather than a code. Routing still goes through
    /// `is_session_live`, never this prose
    /// (`scripts/ci/check_session_busy_marker_not_routed.sh`).
    #[error(
        "{SESSION_BUSY_MARKER}: an MLS session is already open on this database \
         (Rule 14: exactly one live session per DB file)"
    )]
    SessionBusy,

    /// Gift-wrapping failed.
    #[error("Gift wrap failed")]
    GiftWrap(String),

    /// Gift-unwrapping failed.
    #[error("Gift unwrap failed")]
    GiftUnwrap(String),
}

/// Prints the variant's [`code`](NostrError::code) and nothing else.
///
/// A `{:?}` of an error reaches panic messages, `expect` output and every
/// `unwrap` on a nostr result, where the derived `Debug` would have printed the
/// wrapped engine / peeler / `SQLCipher` prose verbatim — group ids included —
/// past every `Display` precaution (Security Rule 15).
impl std::fmt::Debug for NostrError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "NostrError({})", self.code())
    }
}

impl NostrError {
    /// A stable, Haven-authored token naming the variant and nothing else.
    ///
    /// The `Display` of most variants interpolates the engine's or the MDK
    /// peeler's own prose, which can quote a group id, an epoch or a
    /// `KeyPackageRef`. A log line therefore names the CODE, never the error
    /// (Security Rule 15); the boundary conversion to
    /// [`crate::circle::CircleError`] remains what protects the UI string.
    ///
    /// Kebab-case and matched only in tests, so it is safe to extend but not to
    /// re-spell.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::MlsGroup(_) => "mls-group",
            Self::Encryption(_) => "encryption",
            Self::Decryption(_) => "decryption",
            Self::KeyDerivation(_) => "key-derivation",
            Self::Signing(_) => "signing",
            Self::Serialization(_) => "serialization",
            Self::InvalidEvent(_) => "invalid-event",
            Self::ExporterSecretUnavailable(_) => "exporter-secret-unavailable",
            Self::Expired => "expired",
            Self::InvalidSignature => "invalid-signature",
            Self::HexError(_) => "hex",
            Self::MdkError(_) => "mdk",
            Self::AdminSelfDemoteRequired => "admin-self-demote-required",
            Self::EpochNotStable => "epoch-not-stable",
            Self::EpochUnrecoverable => "epoch-unrecoverable",
            Self::GroupNotFound(_) => "group-not-found",
            Self::InvalidWelcome(_) => "invalid-welcome",
            Self::StorageError(_) => "storage",
            Self::SessionBusy => "session-busy",
            Self::GiftWrap(_) => "gift-wrap",
            Self::GiftUnwrap(_) => "gift-unwrap",
        }
    }
}

/// Result type for Nostr operations.
pub type Result<T> = std::result::Result<T, NostrError>;

impl From<hex::FromHexError> for NostrError {
    fn from(e: hex::FromHexError) -> Self {
        Self::HexError(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every payload-carrying variant, paired with the whole sentence its
    /// `Display` must render. The pairing is the anti-vacuity anchor for the
    /// absence tests below, and stronger than a substring marker: a rendering
    /// that EQUALS its sentence cannot also carry the payload.
    fn every_payload_carrying_variant(payload: &str) -> Vec<(NostrError, &'static str)> {
        vec![
            (
                NostrError::MlsGroup(payload.to_owned()),
                "MLS group operation failed",
            ),
            (
                NostrError::Encryption(payload.to_owned()),
                "Encryption failed",
            ),
            (
                NostrError::Decryption(payload.to_owned()),
                "Decryption failed",
            ),
            (
                NostrError::KeyDerivation(payload.to_owned()),
                "Key derivation failed",
            ),
            (
                NostrError::Signing(payload.to_owned()),
                "Event signing failed",
            ),
            (
                NostrError::InvalidEvent(payload.to_owned()),
                "Invalid event",
            ),
            (
                NostrError::HexError(payload.to_owned()),
                "Hex encoding error",
            ),
            (NostrError::MdkError(payload.to_owned()), "MDK error"),
            (
                NostrError::GroupNotFound(payload.to_owned()),
                "Group not found",
            ),
            (
                NostrError::InvalidWelcome(payload.to_owned()),
                "Invalid welcome message",
            ),
            (
                NostrError::StorageError(payload.to_owned()),
                "Storage error",
            ),
            (NostrError::GiftWrap(payload.to_owned()), "Gift wrap failed"),
            (
                NostrError::GiftUnwrap(payload.to_owned()),
                "Gift unwrap failed",
            ),
        ]
    }

    #[test]
    fn error_display_redacts_every_payload() {
        const GROUP_HEX: &str = "c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff";
        const NPUB: &str = "npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9";
        const RELAY: &str = "wss://secret-relay.example.com";
        const CIRCLE_NAME: &str = "Needle Circle Zephyr";

        for needle in [GROUP_HEX, NPUB, RELAY, CIRCLE_NAME] {
            for (err, sentence) in every_payload_carrying_variant(needle) {
                assert_eq!(
                    err.to_string(),
                    sentence,
                    "{}'s Display must be its own sentence and nothing else",
                    err.code()
                );
                crate::assert_display_redacted!(err, "NostrError", marker = sentence, &[needle]);
                // And the 8- and 16-char prefixes too: truncation is not
                // redaction, so a "helpful" `{:.8}` would still fail here.
                for width in [8_usize, 16] {
                    let prefix: String = needle.chars().take(width).collect();
                    assert!(
                        !err.to_string().contains(&prefix),
                        "{}'s Display discloses a prefix of its payload",
                        err.code()
                    );
                }
            }
        }
    }

    #[test]
    fn error_debug_redacts_every_payload() {
        // The derived `Debug` printed the payload verbatim, past every `Display`
        // precaution, and a `{:?}` is what an `unwrap` panic renders.
        const GROUP_HEX: &str = "c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff";

        for (err, _) in every_payload_carrying_variant(GROUP_HEX) {
            let expected = format!("NostrError({})", err.code());
            crate::assert_debug_redacted!(err, "NostrError", &[GROUP_HEX]);
            assert_eq!(format!("{err:?}"), expected);
        }
    }

    /// The hand-written sentences the UI and tests route on, pinned verbatim:
    /// they carry no payload, and dropping the payload from the others must not
    /// have disturbed them.
    #[test]
    fn the_routable_sentences_are_unchanged() {
        assert_eq!(
            NostrError::AdminSelfDemoteRequired.to_string(),
            "admin cannot leave the circle yet: self-demote (leave the admin set) first"
        );
        assert_eq!(
            NostrError::EpochNotStable.to_string(),
            "the circle's group state is busy; try again shortly"
        );
        assert_eq!(
            NostrError::EpochUnrecoverable.to_string(),
            "the circle's group state cannot be repaired on this device"
        );
    }

    #[test]
    fn error_display_mls_group() {
        let err = NostrError::MlsGroup("test error".to_string());
        assert_eq!(err.to_string(), "MLS group operation failed");
    }

    #[test]
    fn error_display_encryption() {
        let err = NostrError::Encryption("cipher failed".to_string());
        assert_eq!(err.to_string(), "Encryption failed");
    }

    #[test]
    fn error_display_decryption() {
        let err = NostrError::Decryption("invalid mac".to_string());
        assert_eq!(err.to_string(), "Decryption failed");
    }

    #[test]
    fn error_display_redacts_the_absolute_epoch() {
        let err = NostrError::ExporterSecretUnavailable(1_234_567);
        assert_eq!(
            err.to_string(),
            "Exporter secret unavailable for the requested epoch"
        );
        // The variant still carries the epoch for callers; only the rendering
        // drops it (Security Rule 15).
        assert!(matches!(
            err,
            NostrError::ExporterSecretUnavailable(1_234_567)
        ));
    }

    #[test]
    fn error_display_expired() {
        let err = NostrError::Expired;
        assert_eq!(err.to_string(), "Event has expired");
    }

    #[test]
    fn error_from_serde_json() {
        let json_err = serde_json::from_str::<i32>("invalid").unwrap_err();
        let err: NostrError = json_err.into();
        assert!(matches!(err, NostrError::Serialization(_)));
    }

    #[test]
    fn error_from_hex() {
        let hex_err = hex::decode("not valid hex").unwrap_err();
        let err: NostrError = hex_err.into();
        assert!(matches!(err, NostrError::HexError(_)));
    }

    #[test]
    fn error_display_key_derivation() {
        let err = NostrError::KeyDerivation("invalid key".to_string());
        assert_eq!(err.to_string(), "Key derivation failed");
    }

    #[test]
    fn error_display_signing() {
        let err = NostrError::Signing("signer unavailable".to_string());
        assert_eq!(err.to_string(), "Event signing failed");
    }

    #[test]
    fn error_display_invalid_event() {
        let err = NostrError::InvalidEvent("missing field".to_string());
        assert_eq!(err.to_string(), "Invalid event");
    }

    #[test]
    fn error_display_invalid_signature() {
        let err = NostrError::InvalidSignature;
        assert_eq!(err.to_string(), "Invalid event signature");
    }

    #[test]
    fn error_display_hex_error() {
        let err = NostrError::HexError("bad hex".to_string());
        assert_eq!(err.to_string(), "Hex encoding error");
    }

    #[test]
    fn every_variant_code_is_distinct() {
        // The code IS the `Debug` rendering, so a new variant that forgot a code
        // would silently share another's and a reader would mis-attribute the
        // failure.
        let mut codes: Vec<&str> = every_payload_carrying_variant("x")
            .iter()
            .map(|(err, _)| err.code())
            .collect();
        codes.extend([
            NostrError::SessionBusy.code(),
            NostrError::ExporterSecretUnavailable(0).code(),
            NostrError::Expired.code(),
            NostrError::InvalidSignature.code(),
            NostrError::AdminSelfDemoteRequired.code(),
            NostrError::EpochNotStable.code(),
            NostrError::EpochUnrecoverable.code(),
            NostrError::Serialization(serde_json::from_str::<i32>("!").unwrap_err()).code(),
        ]);
        let unique: std::collections::HashSet<&str> = codes.iter().copied().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "codes must be distinct: {codes:?}"
        );
    }
}
