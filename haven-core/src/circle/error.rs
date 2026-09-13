//! Error types for circle management operations.
//!
//! This module defines errors that can occur during circle operations,
//! including storage errors, validation errors, and MDK errors.

use thiserror::Error;

/// Why a relay-list edit was refused.
///
/// Fieldless: each sentence is Haven-authored and value-free, so it is the one
/// `CircleError` payload the FFI may surface verbatim — Dart's relay-preferences
/// service routes the user-facing message off these exact sentences, and a
/// generic "Invalid data" would leave it with nothing to route on
/// (Security Rule 15). Pinned against the Dart router and its test by
/// `tests/relay_input_rejection_ties.rs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum RelayInputRejection {
    /// The input was empty or whitespace only.
    #[error("Relay URL must not be empty")]
    Empty,

    /// The URL used plaintext `ws://` outside the debug-only loopback opt-in.
    #[error("Use wss:// for security")]
    PlaintextWs,

    /// The URL carried `user:pass@`, which must never reach storage.
    #[error("Relay URL must not contain credentials")]
    Credentials,

    /// `nostr::RelayUrl::parse` refused the URL.
    #[error("Invalid relay URL")]
    Unparseable,

    /// Removing the relay would leave its category empty.
    #[error("At least one relay is required per category")]
    LastInCategory,
}

impl RelayInputRejection {
    /// Every rejection, for the exhaustiveness of the sentence and code pins.
    pub const ALL: [Self; 5] = [
        Self::Empty,
        Self::PlaintextWs,
        Self::Credentials,
        Self::Unparseable,
        Self::LastInCategory,
    ];

    /// A stable, value-free token naming the rejection, for log lines.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Empty => "relay-url-empty",
            Self::PlaintextWs => "relay-url-plaintext-ws",
            Self::Credentials => "relay-url-credentials",
            Self::Unparseable => "relay-url-unparseable",
            Self::LastInCategory => "relay-last-in-category",
        }
    }
}

/// Error type for circle operations.
#[derive(Error)]
pub enum CircleError {
    /// Storage operation failed.
    ///
    /// The wrapped detail is kept for programmatic use but is NEVER rendered:
    /// `Display` crosses the FFI into Dart, whose default error handler prints
    /// an exception's message verbatim (Security Rule 15 / Rule 8).
    #[error("Storage error")]
    Storage(String),

    /// Database error from `SQLite`.
    ///
    /// The wrapped error is NOT rendered: rusqlite's `Display` can echo a bound
    /// parameter back (the same reason `tiles::TileCacheError` reduces it to a
    /// category), and a bound parameter here is a pubkey or a group id.
    #[error("Database error")]
    Database(#[from] rusqlite::Error),

    /// Circle not found.
    #[error("Circle not found")]
    NotFound(String),

    /// Contact not found.
    #[error("Contact not found")]
    ContactNotFound(String),

    /// Invalid data provided.
    #[error("Invalid data")]
    InvalidData(String),

    /// A relay-list edit was refused for a reason the user can act on.
    ///
    /// The one variant whose rendered payload is prose, because that prose is a
    /// fieldless, Haven-authored sentence rather than anything borrowed: the FFI
    /// flattens `Display`, and Dart's `_mapStorageError` routes the message the
    /// user reads off it. See [`RelayInputRejection`].
    #[error("{0}")]
    InvalidRelayInput(#[from] RelayInputRejection),

    /// MDK operation failed.
    #[error("MLS error")]
    Mls(String),

    /// Circle already exists.
    #[error("Circle already exists")]
    AlreadyExists(String),

    /// Membership state conflict.
    #[error("Membership conflict")]
    MembershipConflict(String),

    /// Orphaned circle was removed from local storage.
    ///
    /// The MLS group did not exist in MDK (e.g., from a failed finalization
    /// or database reset), but local storage was cleaned up successfully.
    /// Callers should treat this as a successful leave with no evolution
    /// event to publish.
    #[error("Orphaned circle removed")]
    OrphanedCircleRemoved,

    /// Caller is the sole remaining member — no one to hand off admin
    /// rights to, so the circle is abandoned locally without a relay commit.
    ///
    /// Surfaced from [`CircleManager::plan_leave`] so the Flutter layer can
    /// decide between calling `abandon_circle_local_only` (simple cleanup)
    /// or prompting the user. The variant is intentionally data-free so that
    /// `Debug`/`Display` cannot leak the MLS group ID.
    ///
    /// [`CircleManager::plan_leave`]: crate::circle::CircleManager::plan_leave
    #[error("Last member abandon")]
    LastMemberAbandon,

    /// A still-admin caller tried to leave; the remediation is to exit the admin
    /// set first. Byte-identical sentence to
    /// [`crate::nostr::NostrError::AdminSelfDemoteRequired`], which it carries
    /// across the boundary conversion.
    ///
    /// Typed and payload-free because the FFI surfaces `Display`: routed through
    /// [`Self::Mls`] the remediation would sit in a payload that no rendering
    /// shows any more, and the flattened FFI string IS the contract here —
    /// `haven/integration_test/circle_admin_leave_ghost_test.dart` asserts it
    /// names the remediation, which is what proves the pinned MDK still refuses
    /// an admin's bare `SelfRemove` rather than silently accepting it (the
    /// ghost-admin bug). The UI maps every leave failure to one generic
    /// message, so that oracle is the consumer, not a screen. The sentence names
    /// no circle, no epoch and no member (Security Rule 15).
    #[error("admin cannot leave the circle yet: self-demote (leave the admin set) first")]
    AdminSelfDemoteRequired,

    /// Gift-wrapped invitation has already been processed.
    ///
    /// Returned from `process_invitation` when the wrapper event ID is
    /// present in the `processed_gift_wraps` dedup table. This is the
    /// expected outcome when the invitation poller re-fetches a gift wrap
    /// it has already processed (NIP-59's 2-day lookback window causes
    /// every poll cycle to re-surface the same events). Callers should
    /// treat this as a silent no-op rather than surfacing it as a failure.
    ///
    /// The variant is intentionally data-free so that `Debug`/`Display`
    /// output cannot leak an MLS group ID. Use
    /// [`CircleStorage::is_gift_wrap_processed`] if you need the group ID
    /// that the wrapper was originally bound to.
    ///
    /// [`CircleStorage::is_gift_wrap_processed`]: crate::circle::storage::CircleStorage::is_gift_wrap_processed
    #[error("Invitation already processed")]
    AlreadyProcessed,

    /// No reachable relay was found to deliver a gift-wrapped Welcome.
    ///
    /// Returned from circle creation when an invited member advertised no
    /// inbox (kind 10050) or NIP-65 (kind 10002) relays and the creator has
    /// no inbox relays to fall back to. Haven **fails closed** here rather
    /// than delivering the (encrypted) Welcome to public default relays,
    /// which would expose the invite-recipient's pubkey metadata to those
    /// relays. The user should retry once the invitee becomes reachable.
    ///
    /// The variant is intentionally data-free so that `Debug`/`Display`
    /// cannot leak a pubkey, relay URL, or MLS group ID (Security Rule #8).
    #[error("No reachable relay for welcome delivery")]
    MissingWelcomeRelays,

    /// The MLS engine QUEUED the location update instead of encrypting it, so
    /// there is no event to publish.
    ///
    /// `cgka-engine`'s `do_send` persists a `QueuedOutboundIntent` and returns
    /// `SendResult::Queued` whenever any stored message inside the group's
    /// convergence window is still `Created` or `Retryable`. A Haven circle's
    /// epoch only advances on a membership change, so that window is the
    /// circle's entire life: ONE inbound row that can never be resolved — a
    /// `Created` row orphaned by a kill mid-ingest, or a `Retryable` row left
    /// by a decrypt that can never succeed — silently stops the device sending
    /// for that circle, permanently and across restarts.
    ///
    /// This is a distinct, ACTIONABLE outcome, not the opaque
    /// [`Self::Mls`] string it replaced. It is an `Err` because the caller has
    /// no event to publish; it is TYPED so the FFI can classify it by matching
    /// a Rust variant instead of testing the flattened error prose — a test
    /// Haven forbids elsewhere for good reason (error strings interpolate
    /// remote-authored text, so a substring match is a remotely-influenceable
    /// control channel; see `nostr::mls::storage::is_session_live`).
    ///
    /// Every field is a count, a flag, or a type whose own `Debug` is
    /// presence-only ([`crate::circle::DeferredWork`]). The variant carries no
    /// group id, no message id, no epoch and no payload, so the hand-written
    /// `Debug` below (which renders only [`Self::code`]) and the `Display` above
    /// are leak-free by construction (Security Rules 4/8) —
    /// the same posture as [`Self::LastMemberAbandon`] and
    /// [`Self::AlreadyProcessed`]. The caller already knows which circle it
    /// asked about, so naming it here would add nothing but exposure.
    #[error(
        "Send deferred: {} unresolved convergence input(s), \
         {} queued intent(s) discarded, repaired={repaired}, work={work:?}",
        crate::log_alias::bucket(*unresolved_inputs),
        crate::log_alias::bucket(*discarded_intents)
    )]
    SendDeferred {
        /// Stored rows still gating outbound sends for this circle, read AFTER
        /// everything else this outcome describes. Zero means the next send
        /// should encrypt.
        unresolved_inputs: usize,
        /// Queued location intents dropped so a stalled circle cannot
        /// accumulate one stale fix per publish cycle.
        discarded_intents: usize,
        /// Whether the circle was left with nothing gating.
        repaired: bool,
        /// Publish work the engine staged or emitted during this deferral.
        /// **The caller MUST run the Rule-13 ladder over
        /// [`work.commits`](crate::circle::DeferredWork::commits)** — publish,
        /// then confirm on a ≥1-relay ack — or the group stays in
        /// `PendingPublish` and stops sending entirely. Empty in the ordinary
        /// stuck-row case.
        work: crate::circle::DeferredWork,
    },
}

impl CircleError {
    /// A stable, value-free token naming the variant, for log lines.
    ///
    /// Log lines quote this instead of `Display`: the string-carrying variants
    /// wrap `SQLite` and MLS-engine prose, and prose Haven did not author is
    /// exactly what must not reach a log (Security Rule 15).
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Storage(_) => "storage",
            Self::Database(_) => "database",
            Self::NotFound(_) => "not-found",
            Self::ContactNotFound(_) => "contact-not-found",
            Self::InvalidData(_) => "invalid-data",
            Self::InvalidRelayInput(rejection) => rejection.code(),
            Self::Mls(_) => "mls",
            Self::AlreadyExists(_) => "already-exists",
            Self::MembershipConflict(_) => "membership-conflict",
            Self::OrphanedCircleRemoved => "orphaned-circle-removed",
            Self::LastMemberAbandon => "last-member-abandon",
            Self::AdminSelfDemoteRequired => "admin-self-demote-required",
            Self::AlreadyProcessed => "already-processed",
            Self::MissingWelcomeRelays => "missing-welcome-relays",
            Self::SendDeferred { .. } => "send-deferred",
        }
    }
}

/// Prints the variant's [`code`](CircleError::code) and nothing else — a
/// `{:?}` of an error reaches panic messages and `expect` output, where the
/// wrapped `SQLite` / MLS prose would be a leak Haven cannot see coming.
impl std::fmt::Debug for CircleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CircleError({})", self.code())
    }
}

/// Result type alias for circle operations.
pub type Result<T> = std::result::Result<T, CircleError>;

impl From<crate::nostr::NostrError> for CircleError {
    fn from(err: crate::nostr::NostrError) -> Self {
        match err {
            // The one `NostrError` whose sentence is an actionable remediation
            // rather than a category, so it must stay a variant: `Mls`'s payload
            // is no longer rendered anywhere, and `Display` is what the FFI
            // hands to Dart.
            crate::nostr::NostrError::AdminSelfDemoteRequired => Self::AdminSelfDemoteRequired,
            other => Self::Mls(crate::nostr::mls::redact_hex_sequences(&other.to_string())),
        }
    }
}

impl From<crate::profile::ProfileError> for CircleError {
    fn from(err: crate::profile::ProfileError) -> Self {
        // Every `ProfileError` variant is already content-free or redacted at
        // construction; passing the rendered message through the canonical
        // redactor once more is the floor, not the mechanism, and it costs
        // nothing on a message that carries no hex.
        Self::InvalidData(crate::util::redact_hex_sequences(&err.to_string()))
    }
}

impl From<crate::avatar::AvatarError> for CircleError {
    fn from(err: crate::avatar::AvatarError) -> Self {
        use crate::avatar::AvatarError as A;
        match err {
            // Storage strings come from the SQLite layer (never image content).
            A::Storage(s) => Self::Storage(s),
            // Every other avatar-pipeline variant carries only a fixed, generic,
            // content-free message (no bytes, dimensions, or detected format),
            // so surfacing its Display cannot leak anything (Security Rule #8).
            other => Self::InvalidData(other.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circle_error_display_redacts_every_payload() {
        // `Display` is what the FFI hands to Dart, and Flutter's default error
        // handler prints an exception's message verbatim — so the payload (in
        // production a `nostr_group_id`, a pubkey, or SQLite/MLS prose) must be
        // ABSENT from it, not merely shortened (Security Rule 15).
        let group_hex = "4b3a29180f7e6d5c4b3a29180f7e6d5c4b3a29180f7e6d5c4b3a29180f7e6d5c";
        let pubkey_hex = "9c8b7a695847362514f3e2d1c0b9a8978685746352413f2e1d0c9b8a79685746";
        let cases = [
            (
                CircleError::Storage(format!("UNIQUE failed: {group_hex}")),
                "Storage error",
            ),
            (
                CircleError::NotFound(group_hex.to_string()),
                "Circle not found",
            ),
            (
                CircleError::ContactNotFound(pubkey_hex.to_string()),
                "Contact not found",
            ),
            (
                CircleError::InvalidData(format!("bad name for {group_hex}")),
                "Invalid data",
            ),
            (
                CircleError::Mls(format!("no group {group_hex}")),
                "MLS error",
            ),
            (
                CircleError::AlreadyExists(group_hex.to_string()),
                "Circle already exists",
            ),
            (
                CircleError::MembershipConflict(format!("{pubkey_hex} already accepted")),
                "Membership conflict",
            ),
        ];
        for (err, expected) in cases {
            crate::assert_display_redacted!(
                &err,
                "CircleError",
                marker = expected,
                &[group_hex, pubkey_hex]
            );
            let display = err.to_string();
            assert_eq!(display, expected);
            // Not even a prefix: a prefix of an identifier is the identifier.
            assert!(!display.contains(&group_hex[..8]), "{display}");
            assert!(!display.contains(&pubkey_hex[..8]), "{display}");
            // The machine-readable discriminator is `code()`, not the prose.
            assert!(!err.code().is_empty());
        }
    }

    #[test]
    fn orphaned_circle_removed_error_display() {
        let err = CircleError::OrphanedCircleRemoved;
        assert_eq!(err.to_string(), "Orphaned circle removed");
    }

    #[test]
    fn last_member_abandon_display_is_opaque() {
        let err = CircleError::LastMemberAbandon;
        assert_eq!(err.to_string(), "Last member abandon");
    }

    #[test]
    fn send_deferred_display_buckets_its_counts() {
        let err = CircleError::SendDeferred {
            unresolved_inputs: 2,
            discarded_intents: 1,
            repaired: false,
            work: crate::circle::DeferredWork::default(),
        };
        // An exact count of gating rows is a per-circle magnitude; the bucket
        // keeps the triage signal (none / one / a few / many) without it.
        assert_eq!(
            err.to_string(),
            "Send deferred: 2-4 unresolved convergence input(s), \
             1 queued intent(s) discarded, repaired=false, \
             work=DeferredWork { commits: \"0\", proposals: \"0\" }"
        );
    }

    #[test]
    fn circle_error_debug_redacts_every_payload() {
        // Structural, not incidental: the derived `Debug` printed each
        // variant's payload, so a SQLite message that echoed a bound pubkey
        // reached every `expect`/panic rendering. Now no payload can.
        let cases = [
            (
                CircleError::Storage("UNIQUE constraint failed: circles.a1b2c3d4".to_string()),
                "CircleError(storage)",
            ),
            (
                CircleError::Mls("no group a1b2c3d4e5f60718".to_string()),
                "CircleError(mls)",
            ),
            (
                CircleError::SendDeferred {
                    unresolved_inputs: 3,
                    discarded_intents: 0,
                    repaired: true,
                    work: crate::circle::DeferredWork::default(),
                },
                "CircleError(send-deferred)",
            ),
        ];
        for (err, expected) in cases {
            crate::assert_debug_redacted!(
                &err,
                "CircleError",
                &["a1b2c3d4", "a1b2c3d4e5f60718", "UNIQUE constraint"]
            );
            assert_eq!(format!("{err:?}"), expected);
        }
    }

    #[test]
    fn error_codes_are_distinct_and_value_free() {
        // The rejections come from `ALL`, so a sixth one is covered the moment
        // it is declared rather than when somebody remembers this list.
        let mut codes: Vec<&str> = RelayInputRejection::ALL
            .into_iter()
            .map(|rejection| CircleError::from(rejection).code())
            .collect();
        codes.extend([
            CircleError::Storage(String::new()).code(),
            CircleError::Database(rusqlite::Error::QueryReturnedNoRows).code(),
            CircleError::NotFound(String::new()).code(),
            CircleError::ContactNotFound(String::new()).code(),
            CircleError::InvalidData(String::new()).code(),
            CircleError::Mls(String::new()).code(),
            CircleError::AlreadyExists(String::new()).code(),
            CircleError::MembershipConflict(String::new()).code(),
            CircleError::OrphanedCircleRemoved.code(),
            CircleError::LastMemberAbandon.code(),
            CircleError::AdminSelfDemoteRequired.code(),
            CircleError::AlreadyProcessed.code(),
            CircleError::MissingWelcomeRelays.code(),
            CircleError::SendDeferred {
                unresolved_inputs: 0,
                discarded_intents: 0,
                repaired: true,
                work: crate::circle::DeferredWork::default(),
            }
            .code(),
        ]);
        let unique: std::collections::BTreeSet<&str> = codes.iter().copied().collect();
        assert_eq!(unique.len(), codes.len(), "a code is reused: {codes:?}");
        for code in codes {
            assert!(
                code.chars().all(|c| c.is_ascii_lowercase() || c == '-'),
                "a code must be a fixed token, not a value: {code}"
            );
        }
    }

    #[test]
    fn database_error_display_omits_the_sqlite_message() {
        // rusqlite's Display can echo a bound parameter, and a bound parameter
        // here is a pubkey or a group id.
        let err = CircleError::Database(rusqlite::Error::InvalidParameterName(
            ":pubkey_a1b2c3d4".to_string(),
        ));
        crate::assert_display_redacted!(
            &err,
            "CircleError",
            marker = "Database error",
            &["pubkey_a1b2c3d4"]
        );
        assert_eq!(err.to_string(), "Database error");
    }

    #[test]
    fn already_processed_error_display_is_opaque() {
        let err = CircleError::AlreadyProcessed;
        // The Display output intentionally reveals no MLS group ID, wrapper
        // event ID, or other correlatable state. Callers that need that
        // context must look it up via `CircleStorage::is_gift_wrap_processed`.
        assert_eq!(err.to_string(), "Invitation already processed");
    }

    #[test]
    fn missing_welcome_relays_display_is_redacted() {
        let err = CircleError::MissingWelcomeRelays;
        // Fail-closed welcome delivery must surface a fixed, generic message:
        // no recipient pubkey, no relay URL, no MLS group id (Security Rule #8).
        let display = err.to_string();
        assert_eq!(display, "No reachable relay for welcome delivery");
        // Debug must be equally opaque (the variant's code, no payload).
        let debug = format!("{err:?}");
        assert_eq!(debug, "CircleError(missing-welcome-relays)");
        for needle in ["wss://", "npub", "ws://", "@", "relay."] {
            assert!(
                !display.contains(needle) && !debug.contains(needle),
                "welcome-relay error must not leak '{needle}'"
            );
        }
    }

    #[test]
    fn all_lists_every_rejection() {
        // Exhaustive: a sixth variant cannot compile without an arm here, and the
        // arm cannot pass unless ALL carries it — ALL is what every pin and the
        // cross-language tie test iterate, so a rejection missing from it would
        // ship with no Dart arm and degrade to the generic failure message.
        let listed = |r: RelayInputRejection| match r {
            RelayInputRejection::Empty
            | RelayInputRejection::PlaintextWs
            | RelayInputRejection::Credentials
            | RelayInputRejection::Unparseable
            | RelayInputRejection::LastInCategory => RelayInputRejection::ALL.contains(&r),
        };
        assert!(RelayInputRejection::ALL.into_iter().all(listed));
    }

    #[test]
    fn the_relay_input_sentences_are_unchanged() {
        // These five sentences are an interface, not prose: `_mapStorageError`
        // in `nostr_relay_preferences_service.dart` selects the user-facing
        // message by comparing the flattened FFI string against them, so a
        // reworded sentence silently degrades every relay-edit error to the
        // generic "Relay update failed." (the tie to the Dart files is
        // `tests/relay_input_rejection_ties.rs`).
        assert_eq!(
            RelayInputRejection::ALL.map(|r| r.to_string()),
            [
                "Relay URL must not be empty",
                "Use wss:// for security",
                "Relay URL must not contain credentials",
                "Invalid relay URL",
                "At least one relay is required per category",
            ]
            .map(String::from),
            "a relay-rejection sentence moved, changed or was reordered"
        );
        // `CircleError` is what the FFI flattens, so the wrapper must render the
        // sentence and nothing around it.
        for rejection in RelayInputRejection::ALL {
            assert_eq!(
                CircleError::from(rejection).to_string(),
                rejection.to_string(),
                "the wrapper must surface {}'s sentence verbatim",
                rejection.code()
            );
            // `Debug` stays the code, as for every other variant: a sentence in
            // a panic message is fine, but the codes are what log lines quote.
            assert_eq!(
                format!("{:?}", CircleError::from(rejection)),
                format!("CircleError({})", rejection.code())
            );
        }
    }

    #[test]
    fn admin_self_demote_remediation_survives_the_conversion_on_display() {
        use crate::nostr::NostrError;

        // Longest contiguous hex run, to prove the surfaced sentence carries no
        // identifier at ANY truncation: every Haven identifier (group id,
        // pubkey, event id) renders as a long hex run, and prose cannot.
        fn longest_hex_run(s: &str) -> usize {
            let mut best = 0usize;
            let mut run = 0usize;
            for b in s.bytes() {
                run = if b.is_ascii_hexdigit() { run + 1 } else { 0 };
                best = best.max(run);
            }
            best
        }

        // The sentence the FFI must hand to Dart, pinned here as it is pinned on
        // `NostrError` — the two have to stay byte-identical, because the
        // conversion is the only thing carrying it across.
        const SENTENCE: &str =
            "admin cannot leave the circle yet: self-demote (leave the admin set) first";
        assert_eq!(
            NostrError::AdminSelfDemoteRequired.to_string(),
            SENTENCE,
            "the two variants' sentences have diverged"
        );

        let err = CircleError::from(NostrError::AdminSelfDemoteRequired);
        // Typed, not `Mls`: the remediation used to ride in `Mls`'s payload,
        // which no rendering shows any more, so Dart received only "MLS error".
        assert!(
            matches!(err, CircleError::AdminSelfDemoteRequired),
            "the admin gate must convert to the typed variant, not {err:?}"
        );

        let display = err.to_string();
        assert_eq!(display, SENTENCE);
        assert!(
            display.to_lowercase().contains("self-demote"),
            "the surfaced message must name the remediation: {display}"
        );
        let debug = format!("{err:?}");
        assert_eq!(debug, "CircleError(admin-self-demote-required)");

        assert!(
            longest_hex_run("group 4b3a29180f7e6d5c4b3a29180f7e6d5c") >= 8,
            "detector sanity: a planted group id must be seen, or the checks below are vacuous"
        );
        for rendering in [&display, &debug] {
            assert!(
                longest_hex_run(rendering) < 8,
                "the admin-gate rendering carries a hex run: {rendering}"
            );
        }
    }

    #[test]
    fn nostr_error_conversion_redacts_long_hex_from_surfaced_message() {
        use crate::nostr::mls::redact_hex_sequences;
        use crate::nostr::NostrError;

        // Independent detector for a contiguous hex run >= 16 chars (the shape
        // of an MLS group id / key material the redactor must strip). Written
        // from scratch — NOT via the redactor — so it cannot mask a regression.
        fn has_hex_run_ge16(s: &str) -> bool {
            let mut run = 0usize;
            for b in s.bytes() {
                if b.is_ascii_hexdigit() {
                    run += 1;
                    if run >= 16 {
                        return true;
                    }
                } else {
                    run = 0;
                }
            }
            false
        }

        // 64-char hex standing in for a leaked MLS group id / key material.
        let secret_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assert!(
            has_hex_run_ge16(secret_hex),
            "detector sanity: the planted secret is a >=16 hex run"
        );

        // Positive control, on a SYNTHETIC string rather than on any error
        // type's rendering: the redactor both collapses a 64-hex run and marks
        // that it did, and leaves a 15-char run (a short code, not an
        // identifier) alone. Deliberately independent of `NostrError`'s
        // `Display` — an error that renders no identifier is the goal, so a
        // control that REQUIRED one would forbid the fix it is meant to protect.
        let synthetic = format!("decryption failed for group {secret_hex} at epoch 3");
        let collapsed = redact_hex_sequences(&synthetic);
        assert!(
            !has_hex_run_ge16(&collapsed),
            "redactor sanity: a long hex run is stripped: {collapsed}"
        );
        assert!(
            !collapsed.contains(secret_hex),
            "redactor sanity: the literal run must not survive: {collapsed}"
        );
        assert!(
            collapsed.contains("[REDACTED]"),
            "redactor sanity: a redaction must be marked: {collapsed}"
        );
        let short_run = "id=0123456789abcde end";
        assert_eq!(
            redact_hex_sequences(short_run),
            short_run,
            "redactor sanity: a 15-char run is below the threshold and is kept"
        );

        // `From<NostrError> for CircleError` is the boundary the FFI/UI surfaces
        // (every CircleManager op returns `Result<_, CircleError>`, which the
        // FFI renders to a String shown to developers/users). It MUST redact
        // every variant's Display so a raw MDK/group error can never reach the
        // surface carrying key material (Security Rule #6/#8).
        let cases = [
            NostrError::MdkError(format!("decryption failed for group {secret_hex}")),
            NostrError::GroupNotFound(secret_hex.to_string()),
        ];
        for nostr_err in cases {
            let surfaced = CircleError::from(nostr_err).to_string();
            assert!(
                !has_hex_run_ge16(&surfaced),
                "CircleError surfaced a >=16 hex run (key/group-id leak): {surfaced}"
            );
            // Stronger than the run-length check alone: the literal needle must
            // be gone, catching a redactor bug that split the run into sub-16
            // chunks (which `has_hex_run_ge16` would miss).
            assert!(
                !surfaced.contains(secret_hex),
                "the literal secret hex must not survive redaction: {surfaced}"
            );
            // Nor may a prefix of it: whether the hex is stopped by
            // `NostrError`'s own `Display` or by this conversion's redactor,
            // what reaches the surface must carry no part of the identifier
            // (Security Rule 15).
            assert!(
                !surfaced.contains(&secret_hex[..8]),
                "a prefix of the secret hex is still an identifier: {surfaced}"
            );
        }
    }
}
