//! Lifetime-aware `KeyPackage` rotation policy: read a `KeyPackage`'s **own**
//! MLS `Lifetime` and decide, from that alone, whether it must be re-minted.
//!
//! # Why this module exists (the day-85 cliff)
//!
//! `OpenMLS` stamps every `KeyPackage` with an MLS `Lifetime` extension
//! (`not_before` / `not_after`). Its default is
//! `DEFAULT_KEY_PACKAGE_LIFETIME_SECONDS` = 84 days, extended one hour into the
//! past for clock skew — a total range of exactly 7 261 200 s. Neither MDK nor
//! the pinned `cgka-engine` overrides it, and the Marmot spec caps the range at
//! that same 7 261 200 s ("84 days plus a one-hour clock-skew margin"), so the
//! `OpenMLS` default is already **spec-maximal**. Nothing is gained by lengthening
//! it; the rotation threshold is what does the work.
//!
//! RFC 9420 and `foundation/key-packages.md` both require an inviter to reject a
//! candidate whose validation time is outside `[not_before, not_after]`. On day
//! 85 an un-rotated account is therefore **silently uninvitable**: the 30443 is
//! still on the relay, still fetchable, still well-formed — and every `Add`
//! fails validation. There is no error anywhere on the publishing device.
//!
//! # The policy
//!
//! Rotate once a fixed fraction of the package's OWN lifetime has elapsed:
//!
//! ```text
//! rotate_at = not_before + KP_ROTATE_AT_LIFETIME_FRACTION * (not_after - not_before)
//! ```
//!
//! With the 84-day-plus-margin default that lands at ~day 63 of an 84-day
//! window, leaving ~21 days of slack for a device that is offline, backgrounded,
//! or simply not opened.
//!
//! # Why the clock comes off the PACKAGE, never off the event
//!
//! The reference app (White Noise) ages `KeyPackages` off the Nostr event's
//! `created_at` (`KEY_PACKAGE_MAX_AGE`, 30 days). What expires is the package:
//! `not_after` is the bound every inviter validates, and an event's stamp is
//! not its package's mint time — moving a package into another slot signs a
//! NEW event for OLD material
//! ([`build_kp_slot_repoint_event`](super::key_package::build_kp_slot_repoint_event)),
//! so an event-age timer would run behind the package it carries.
//!
//! Everything here therefore reads `not_before` / `not_after` off the MLS
//! `KeyPackage` itself. `a_repoint_does_not_reset_the_rotation_clock` in
//! `tests/kp_rotation_e2e.rs` is the regression proof.

use cgka_engine::key_package_metadata;
use cgka_traits::engine::KeyPackage;
use cgka_traits::error::EngineError;
use cgka_traits::group::ProtocolProfile;

/// Fraction of a `KeyPackage`'s **own** lifetime after which it must be
/// re-minted.
///
/// # Do not move this number without reading this
///
/// The window it governs is `not_after - not_before`, which for a Haven package
/// is the `OpenMLS`/Marmot maximum of 7 261 200 s (84 days + 1 h). At `0.75` the
/// rotation point is ~day 63, leaving **~21 days of slack** before the package
/// stops being usable at all.
///
/// * **Raising it** (e.g. `0.9` ⇒ ~day 76) shrinks the slack to ~8 days. That
///   slack is not decoration: it is the entire budget for a device that is
///   backgrounded, offline, travelling, or just not opened — and for relays that
///   are unreachable on the tick that would have rotated (a no-responder tick is
///   deliberately a `NoOp`, see [`decide_kp_maintenance`]). Spend it and an
///   ordinary week away becomes silent uninvitability.
/// * **Lowering it** (e.g. `0.5` ⇒ ~day 42) buys slack Haven does not need and
///   costs real privacy: every rotation is a fresh 30443 publish to the
///   account's own relays, i.e. an observable "this account is alive" beacon,
///   and it churns MLS init-key material for no protocol benefit.
///
/// `rotation_fraction_is_pinned_in_both_directions` in
/// [`super::key_package`]'s test module fails if this moves in either
/// direction.
///
/// [`decide_kp_maintenance`]: super::key_package::decide_kp_maintenance
pub const KP_ROTATE_AT_LIFETIME_FRACTION: f64 = 0.75;

/// A `KeyPackage`'s MLS `Lifetime` window, in Unix seconds.
///
/// Both fields are public MLS wire metadata (they are literally serialized into
/// every published 30443), so the derived `Debug` is leak-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyPackageLifetime {
    /// MLS `Lifetime.not_before` — Unix seconds.
    pub not_before: u64,
    /// MLS `Lifetime.not_after` — Unix seconds.
    pub not_after: u64,
}

impl KeyPackageLifetime {
    /// Builds a lifetime from raw bounds (test fixtures / defensive callers).
    #[must_use]
    pub const fn new(not_before: u64, not_after: u64) -> Self {
        Self {
            not_before,
            not_after,
        }
    }

    /// Whether this window is **degenerate** — zero-length or inverted.
    ///
    /// A degenerate window has no interval in which the package is usable, so
    /// there is nothing to rotate *toward*: it is treated as permanently past
    /// the threshold rather than fed through the fraction (which would return
    /// `not_before` and then read "fresh" for any earlier `now`).
    #[must_use]
    pub const fn is_degenerate(&self) -> bool {
        self.not_after <= self.not_before
    }

    /// The instant at/after which the package must be re-minted.
    ///
    /// `not_before + KP_ROTATE_AT_LIFETIME_FRACTION * (not_after - not_before)`,
    /// saturating at `u64::MAX`. For a degenerate window this is `not_before`,
    /// but callers should use [`Self::is_past_rotation_threshold`], which treats
    /// degenerate windows as unconditionally due.
    #[must_use]
    pub fn rotate_at(&self) -> u64 {
        let span = self.not_after.saturating_sub(self.not_before);
        // A lifetime span is bounded by the Marmot cap (7 261 200 s) and, even
        // for a malformed package, by u64 seconds — many orders of magnitude
        // below f64's 2^53 exact-integer range, so the round trip is exact for
        // every input that can reach here. `as u64` on a non-negative, finite,
        // in-range f64 truncates toward zero, which is the conservative
        // direction (rotate no LATER than the true fraction).
        #[allow(
            clippy::cast_precision_loss,
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss
        )]
        let elapsed = (span as f64 * KP_ROTATE_AT_LIFETIME_FRACTION) as u64;
        self.not_before.saturating_add(elapsed)
    }

    /// Whether `now` is at or past the rotation threshold.
    ///
    /// The boundary is inclusive: rotation is due **at** `rotate_at`, not one
    /// second later.
    #[must_use]
    pub fn is_past_rotation_threshold(&self, now_secs: u64) -> bool {
        self.is_degenerate() || now_secs >= self.rotate_at()
    }

    /// Whether `now` is at or past `not_after` — the package is dead, and the
    /// spec's second deletion bound has fired
    /// ([`SessionManager::sweep_expired_key_packages`](crate::nostr::mls::SessionManager::sweep_expired_key_packages)).
    #[must_use]
    pub const fn is_past_not_after(&self, now_secs: u64) -> bool {
        now_secs >= self.not_after
    }
}

/// What the maintenance tick knows about the lifetime of the `KeyPackage` it
/// currently tracks.
///
/// Fieldless-or-public-metadata, so the derived `Debug` is leak-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackedKpLifetime {
    /// No tracked `KeyPackage` bytes at all — a first publish, or the
    /// empty-bytes seed row written by
    /// [`KpMaintenanceDecision::SeedD`](super::key_package::KpMaintenanceDecision::SeedD).
    /// There is no material to age out and none to delete.
    Absent,
    /// The tracked bytes parsed and validated; this is their real window.
    Known(KeyPackageLifetime),
    /// The tracked bytes parsed, but MLS rejects their `Lifetime` as **not
    /// current** — `now` is outside `[not_before, not_after]`. In practice this
    /// is the expired package (we minted it ourselves, so `not_before` is in the
    /// past unless the device clock jumped backwards by months).
    ///
    /// Distinguished from [`Self::Unreadable`] because it is *positive*
    /// knowledge that the package is dead, which is exactly what the spec's
    /// `not_after` deletion bound keys on.
    NotCurrent,
    /// Tracked bytes exist but no lifetime could be read from them — corrupt
    /// row, a bad signature, or a wire format this build cannot parse.
    Unreadable,
}

impl TrackedKpLifetime {
    /// Whether the tracked package is due for re-minting at `now`.
    ///
    /// # The unreadable case is deliberately "rotate"
    ///
    /// Choosing between the two failure modes:
    ///
    /// * **Assume fresh** ⇒ never rotate. That is *precisely* the defect this
    ///   module exists to fix, it is unbounded (the account stays uninvitable
    ///   forever), and it is silent — nothing on the device ever reports it.
    /// * **Assume stale** ⇒ rotate. Bounded and self-correcting: a rotation
    ///   mints bytes with *our own* engine, so the very next tick reads
    ///   [`Self::Known`] and settles. It can only repeat if the reader is broken
    ///   for *every* package (say, a future `OpenMLS` wire change), and that case
    ///   is loud rather than silent — it surfaces as
    ///   [`KpMaintenanceAction::RotatedUnreadableLifetime`] on every tick, a
    ///   distinct value Dart can see, rather than as an indistinguishable
    ///   `AlreadyHealthy`.
    ///
    /// So: rotate, and make the reason visible.
    ///
    /// [`KpMaintenanceAction::RotatedUnreadableLifetime`]: super::key_package::KpMaintenanceAction::RotatedUnreadableLifetime
    #[must_use]
    pub fn is_rotation_due(&self, now_secs: u64) -> bool {
        match self {
            Self::Absent => false,
            Self::Known(l) => l.is_past_rotation_threshold(now_secs),
            Self::NotCurrent | Self::Unreadable => true,
        }
    }

    /// Whether the rotation is due *because the lifetime could not be read*
    /// rather than because the package genuinely aged out.
    ///
    /// Drives the distinct outcome the FFI reports, so an unreadable-lifetime
    /// loop is diagnosable instead of masquerading as ordinary rotation.
    #[must_use]
    pub const fn is_unreadable(&self) -> bool {
        matches!(self, Self::Unreadable)
    }
}

/// Reads the MLS `Lifetime` out of raw `KeyPackage` wire bytes.
///
/// `bytes` are the framed `MLSMessage` (`wire_format = mls_key_package`) the
/// lifecycle record tracks and a 30443 carries as base64. They
/// are read through MDK's own parser, `cgka_engine::key_package_metadata`
/// (MDK v0.10.4 `cgka-engine/src/key_package.rs:127-163`), which validates the
/// package, its lifetime and its account-identity proof before reporting
/// `not_before` / `not_after` — so a corrupt row cannot dictate rotation
/// timing, and Haven carries no MLS parser of its own. Every package Haven
/// mints is the Current profile (the reset left no Legacy bundle behind), so
/// bytes that do not decode as Current are unreadable, and rotate.
///
/// Never returns an error string: every failure is classified into the enum, so
/// no MLS error text (which can carry key-package internals) can reach a log or
/// a UI (Security Rules 6/8).
#[must_use]
pub fn read_kp_lifetime(bytes: &[u8]) -> TrackedKpLifetime {
    if bytes.is_empty() {
        return TrackedKpLifetime::Absent;
    }
    let package = KeyPackage::new(bytes.to_vec()).with_protocol_profile(ProtocolProfile::Current);
    match key_package_metadata(&package) {
        Ok(meta) => TrackedKpLifetime::Known(KeyPackageLifetime {
            not_before: meta.not_before,
            not_after: meta.not_after,
        }),
        // MLS says the window does not contain "now" (or is out of the accepted
        // range). Positive knowledge that this package is unusable — NOT merely
        // unparseable.
        Err(EngineError::InvalidKeyPackageLifetime { .. }) => TrackedKpLifetime::NotCurrent,
        Err(_) => TrackedKpLifetime::Unreadable,
    }
}

/// Wall-clock "now" in Unix seconds, for callers that have no injected clock.
///
/// Saturates to `0` before the epoch rather than panicking — a device whose
/// clock is set before 1970 reads as "everything is past its threshold", which
/// is the fail-safe direction (rotate) rather than the fail-silent one.
#[must_use]
pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `OpenMLS` default `KeyPackage` lifetime span: 84 days + a 1 h
    /// clock-skew margin, i.e. the Marmot maximum (`not_after - not_before <=
    /// 7_261_200`).
    const SPAN: u64 = 60 * 60 * 24 * 28 * 3 + 60 * 60;

    fn lifetime(span: u64) -> KeyPackageLifetime {
        KeyPackageLifetime::new(1_000_000, 1_000_000 + span)
    }

    // ── Threshold arithmetic ─────────────────────────────────────────────────

    #[test]
    fn rotate_at_is_three_quarters_into_the_window() {
        let l = lifetime(SPAN);
        assert_eq!(l.rotate_at(), 1_000_000 + SPAN * 3 / 4);
    }

    #[test]
    fn threshold_lands_on_day_63_leaving_21_days_of_slack() {
        // The whole point of 0.75: rotate around day 63 of an 84-day package and
        // keep ~21 days of slack for a device that is offline or backgrounded.
        let l = lifetime(SPAN);
        // `OpenMLS` back-dates `not_before` by the 1 h skew margin, so "days since
        // MINT" is the operationally meaningful anchor: mint == not_before + 1h.
        let mint = l.not_before + 3_600;
        assert_eq!(
            (l.rotate_at() - mint) / 86_400,
            62,
            "rotation must fall inside day 63 counted from the mint instant"
        );
        assert_eq!(
            (l.not_after - mint) / 86_400,
            84,
            "the package must die exactly 84 days after the mint instant"
        );
        assert_eq!(
            (l.not_after - l.rotate_at()) / 86_400,
            21,
            "~21 days of slack must remain between rotation and expiry"
        );
    }

    #[test]
    fn exact_boundary_is_rotation_due() {
        let l = lifetime(SPAN);
        assert!(
            l.is_past_rotation_threshold(l.rotate_at()),
            "the boundary second itself must be due (inclusive)"
        );
    }

    #[test]
    fn one_second_before_the_boundary_is_not_due() {
        let l = lifetime(SPAN);
        assert!(!l.is_past_rotation_threshold(l.rotate_at() - 1));
    }

    #[test]
    fn one_second_after_the_boundary_is_due() {
        let l = lifetime(SPAN);
        assert!(l.is_past_rotation_threshold(l.rotate_at() + 1));
    }

    #[test]
    fn fresh_package_at_not_before_is_not_due() {
        let l = lifetime(SPAN);
        assert!(!l.is_past_rotation_threshold(l.not_before));
    }

    #[test]
    fn zero_length_lifetime_is_always_due() {
        let l = KeyPackageLifetime::new(1_000_000, 1_000_000);
        assert!(l.is_degenerate());
        // Due even STRICTLY BEFORE `not_before` — a window with no usable
        // interval can never be "fresh".
        assert!(l.is_past_rotation_threshold(0));
        assert!(l.is_past_rotation_threshold(1_000_000));
        assert!(l.is_past_rotation_threshold(u64::MAX));
    }

    #[test]
    fn inverted_lifetime_is_always_due() {
        let l = KeyPackageLifetime::new(2_000_000, 1_000_000);
        assert!(l.is_degenerate());
        assert!(l.is_past_rotation_threshold(0));
        assert!(l.is_past_rotation_threshold(1_500_000));
    }

    #[test]
    fn rotate_at_saturates_instead_of_overflowing() {
        let l = KeyPackageLifetime::new(u64::MAX - 1, u64::MAX);
        assert_eq!(l.rotate_at(), u64::MAX - 1);
        let wide = KeyPackageLifetime::new(0, u64::MAX);
        assert!(wide.rotate_at() > 0, "a huge span must not wrap to zero");
    }

    // ── TrackedKpLifetime dispatch ───────────────────────────────────────────

    #[test]
    fn absent_is_never_rotation_due() {
        assert!(!TrackedKpLifetime::Absent.is_rotation_due(u64::MAX));
    }

    #[test]
    fn known_delegates_to_the_threshold() {
        let l = lifetime(SPAN);
        assert!(!TrackedKpLifetime::Known(l).is_rotation_due(l.rotate_at() - 1));
        assert!(TrackedKpLifetime::Known(l).is_rotation_due(l.rotate_at()));
    }

    #[test]
    fn unreadable_lifetime_rotates_and_is_labelled_unreadable() {
        // The explicit decision: unreadable ⇒ rotate (bounded, self-correcting)
        // rather than assume-fresh (unbounded, silent).
        assert!(TrackedKpLifetime::Unreadable.is_rotation_due(0));
        assert!(TrackedKpLifetime::Unreadable.is_unreadable());
        // And it must be distinguishable from an ordinary aged-out rotation.
        assert!(!TrackedKpLifetime::NotCurrent.is_unreadable());
        assert!(!TrackedKpLifetime::Known(lifetime(SPAN)).is_unreadable());
        assert!(!TrackedKpLifetime::Absent.is_unreadable());
    }

    #[test]
    fn not_current_rotates_at_any_clock() {
        assert!(TrackedKpLifetime::NotCurrent.is_rotation_due(0));
        assert!(TrackedKpLifetime::NotCurrent.is_rotation_due(u64::MAX));
    }

    // ── Reading real bytes ───────────────────────────────────────────────────

    #[test]
    fn empty_bytes_read_as_absent_not_unreadable() {
        // The seed row carries EMPTY bytes; that is "nothing tracked", not
        // "corrupt", and must not trigger an unreadable-lifetime rotation.
        assert_eq!(read_kp_lifetime(&[]), TrackedKpLifetime::Absent);
    }

    #[test]
    fn garbage_bytes_read_as_unreadable() {
        assert_eq!(
            read_kp_lifetime(&[0xde, 0xad, 0xbe, 0xef]),
            TrackedKpLifetime::Unreadable
        );
    }

    #[test]
    fn non_key_package_mls_message_reads_as_unreadable() {
        // A well-formed TLS blob that is not a KeyPackage body.
        let mut bytes = vec![0x00u8; 64];
        bytes[0] = 0x00;
        assert!(matches!(
            read_kp_lifetime(&bytes),
            TrackedKpLifetime::Unreadable
        ));
    }

    #[test]
    fn now_secs_is_after_the_2020s_epoch() {
        // Sanity: the helper returns Unix seconds, not millis or a monotonic
        // counter (a wrong unit would silently break every threshold compare).
        assert!(now_secs() > 1_700_000_000);
    }
}
