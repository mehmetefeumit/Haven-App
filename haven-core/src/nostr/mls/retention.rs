//! Send-side bound on the NIP-40 `expiration` of Haven's own kind-445
//! application messages.
//!
//! # The hole this closes
//!
//! The engine derives the expiration from the group's
//! `marmot.group.message-retention.v1` component (`0x8005`) and hands the result
//! to the transport peeler as `GroupMessageMetadata::Application`'s
//! `retention_seconds`. Haven supplies that component at exactly one place —
//! [`SessionManager::create_group`](super::SessionManager::create_group) — so it
//! is present in every circle THIS device created and absent from a circle
//! created by anything else: an older Haven build, or another Marmot client.
//! Upstream, absent (and zero) mean "transport expiration disabled", and the
//! peeler then stamps **no expiration tag at all**.
//!
//! Two halves of `privacyWhatOthersSeeDetailExpiry` invert together in that
//! case, in opposite directions:
//!
//! 1. "Haven asks relays to drop location messages after about four minutes"
//!    becomes false — the location ciphertext may sit on a relay indefinitely.
//! 2. Because commits and proposals are the only 445s that are never stamped,
//!    the *absence* of an expiration is how a relay observer separates group
//!    control traffic from location traffic. An unstamped location update is
//!    therefore not merely long-lived, it is **misclassified**: it announces a
//!    membership change, on the wire, where any relay can see it, when nothing
//!    structural happened.
//!
//! # What this does
//!
//! [`RetentionBoundPeeler`] delegates every peeler operation to the real Nostr
//! peeler, and bounds an APPLICATION message's retention on the way through
//! ([`bounded_retention_secs`]). It is the peeler the session is constructed
//! with, and the engine holds exactly one — so every send path reaches the wire
//! through this wrapper's [`wrap_group_message_with_metadata`], inside which
//! the real peeler mints the ephemeral key, builds the tag set and signs the
//! kind-445. There is no second handle an application 445 could leave by.
//!
//! Commits and proposals pass through untouched: they carry
//! `GroupMessageMetadata::CommitOrProposal`, which stamps nothing, and group
//! history must outlive any TTL or a NIP-40-honouring relay would strand late
//! joiners.
//!
//! # Why here, and not an `UpdateAppComponents` repair of the joined group
//!
//! Writing `0x8005` into a group that lacks it is admin-gated upstream
//! (`require_admin` on the `UpdateAppComponents` path) and a joiner is not an
//! admin, so the repair cannot fire at the moment the gap appears. Worse, it
//! would stage an epoch-advancing commit inside the join path, whose failure
//! mode — a commit staged but never published — pins the group in
//! `PendingPublish` and buffers every inbound message forever, i.e. silently
//! loses the circle. Bounding at the wrap boundary needs no group state, no
//! admin rights, no commit and no publish, and it holds unconditionally for the
//! traffic this device authors, which is the traffic Haven makes promises
//! about. The residue it cannot reach is another member's own unstamped 445s in
//! such a circle; that is recorded in `SECURITY.md` and in the privacy manifest
//! rather than papered over.
//!
//! [`wrap_group_message_with_metadata`]: TransportPeeler::wrap_group_message_with_metadata

use async_trait::async_trait;

use cgka_traits::engine::WelcomeMetadata;
use cgka_traits::error::PeelerError;
use cgka_traits::group_context::GroupContextSnapshot;
use cgka_traits::ingest::PeeledMessage;
use cgka_traits::peeler::{GroupMessageMetadata, TransportPeeler};
use cgka_traits::transport::{EncryptedPayload, TransportMessage};
use cgka_traits::types::MemberId;
use transport_nostr_peeler::NostrMlsPeeler;

use crate::location::ttl::LOCATION_MESSAGE_RETENTION_SECS;

/// The retention Haven requests for one of its own application messages, given
/// the group's declared policy.
///
/// A group that declares nothing, or declares zero (upstream: "expiration
/// disabled"), and a group whose policy is LONGER than Haven's own window both
/// collapse to [`LOCATION_MESSAGE_RETENTION_SECS`]: "about four minutes" is a
/// claim about this device's location data, and a thirty-day group policy
/// falsifies it exactly as an absent one does. A SHORTER group policy is
/// honoured as declared — shorter is strictly more data-minimizing, and the
/// window is the group's to narrow. Haven deliberately does NOT floor it: see
/// `SECURITY.md` "The no-gap invariant" for why a floor would ask relays to
/// hold location ciphertext longer than the circle asked, without restoring
/// what a too-short window costs.
///
/// `Some(0)` is upstream's "expiration disabled" encoding, documented as
/// equivalent to `None` on `GroupMessageMetadata::Application`. At the pinned
/// MDK rev it cannot reach here: `message_retention_seconds_of_group` collapses
/// a zero component to `None` before the engine builds that metadata. The zero
/// arm is therefore a guard against a pin bump that stops collapsing it, not a
/// state today's engine produces — kept because the type's contract admits the
/// value and the resulting unstamped 445 would be silent. Contrast
/// [`SessionManager::group_message_retention_secs`](super::SessionManager::group_message_retention_secs),
/// whose identical-looking filter IS load-bearing today: it reads the raw
/// component bytes, which nothing collapses.
#[must_use]
pub fn bounded_retention_secs(declared: Option<u64>) -> u64 {
    declared
        .filter(|secs| *secs > 0)
        .map_or(LOCATION_MESSAGE_RETENTION_SECS, |secs| {
            secs.min(LOCATION_MESSAGE_RETENTION_SECS)
        })
}

/// The bounded metadata to hand the real peeler.
///
/// Exhaustive on purpose: an upstream variant added here must be a decision,
/// not a silent passthrough that could carry an application payload.
fn bounded(metadata: &GroupMessageMetadata) -> GroupMessageMetadata {
    match *metadata {
        GroupMessageMetadata::Application {
            inner_created_at,
            retention_seconds,
        } => GroupMessageMetadata::application(
            inner_created_at,
            Some(bounded_retention_secs(retention_seconds)),
        ),
        GroupMessageMetadata::CommitOrProposal => GroupMessageMetadata::CommitOrProposal,
    }
}

/// The [`TransportPeeler`] Haven installs on its session.
///
/// The real Nostr peeler with `bounded_retention_secs` applied to every
/// outbound application message. See the module docs for what breaks without
/// it.
///
/// Deliberately not [`Debug`]: the wrapped peeler holds the identity welcome
/// signer, and nothing here needs to render it (Security Rule 6).
pub struct RetentionBoundPeeler {
    inner: NostrMlsPeeler,
}

impl RetentionBoundPeeler {
    /// Wraps the session's Nostr peeler.
    #[must_use]
    pub const fn new(inner: NostrMlsPeeler) -> Self {
        Self { inner }
    }
}

#[async_trait]
impl TransportPeeler for RetentionBoundPeeler {
    async fn peel_group_message(
        &self,
        msg: &TransportMessage,
        ctx: &GroupContextSnapshot,
    ) -> Result<PeeledMessage, PeelerError> {
        self.inner.peel_group_message(msg, ctx).await
    }

    async fn peel_welcome(&self, msg: &TransportMessage) -> Result<PeeledMessage, PeelerError> {
        self.inner.peel_welcome(msg).await
    }

    /// Metadata-less wrap: commits and proposals only (the engine routes every
    /// application message through [`Self::wrap_group_message_with_metadata`]).
    /// Nothing to bound — this path stamps no expiration by construction.
    async fn wrap_group_message(
        &self,
        payload: &EncryptedPayload,
        ctx: &GroupContextSnapshot,
    ) -> Result<TransportMessage, PeelerError> {
        self.inner.wrap_group_message(payload, ctx).await
    }

    async fn wrap_group_message_with_metadata(
        &self,
        payload: &EncryptedPayload,
        ctx: &GroupContextSnapshot,
        metadata: &GroupMessageMetadata,
    ) -> Result<TransportMessage, PeelerError> {
        self.inner
            .wrap_group_message_with_metadata(payload, ctx, &bounded(metadata))
            .await
    }

    async fn wrap_welcome(
        &self,
        payload: &EncryptedPayload,
        recipient: &MemberId,
    ) -> Result<TransportMessage, PeelerError> {
        self.inner.wrap_welcome(payload, recipient).await
    }

    /// Delegated explicitly, not left to the trait default: the default forwards
    /// to [`Self::wrap_welcome`], which the Nostr peeler fail-closes because a
    /// 1059 cannot be built without its metadata.
    async fn wrap_welcome_with_metadata(
        &self,
        payload: &EncryptedPayload,
        recipient: &MemberId,
        metadata: &WelcomeMetadata,
    ) -> Result<TransportMessage, PeelerError> {
        self.inner
            .wrap_welcome_with_metadata(payload, recipient, metadata)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_undeclared_policy_takes_havens_own_window() {
        // The joined-circle case: the engine reports `None` for a group whose
        // creator never declared 0x8005, which upstream means "stamp nothing".
        assert_eq!(
            bounded_retention_secs(None),
            LOCATION_MESSAGE_RETENTION_SECS
        );
    }

    #[test]
    fn an_explicitly_disabled_policy_takes_havens_own_window() {
        // Zero is upstream's "expiration disabled" encoding. At the pinned rev
        // the engine collapses a zero component to `None` before this boundary,
        // so this pins the arm for a pin bump that stops collapsing it — not a
        // value today's engine hands down.
        assert_eq!(
            bounded_retention_secs(Some(0)),
            LOCATION_MESSAGE_RETENTION_SECS
        );
    }

    #[test]
    fn a_longer_policy_is_capped_to_havens_own_window() {
        // A group asking relays to hold location ciphertext for a day would
        // falsify "about four minutes" just as an absent component does.
        assert_eq!(
            bounded_retention_secs(Some(86_400)),
            LOCATION_MESSAGE_RETENTION_SECS
        );
        assert_eq!(
            bounded_retention_secs(Some(LOCATION_MESSAGE_RETENTION_SECS + 1)),
            LOCATION_MESSAGE_RETENTION_SECS
        );
    }

    #[test]
    fn a_shorter_policy_is_honoured_as_declared() {
        // Shorter is strictly more data-minimizing; never widen a group's own
        // narrower window.
        assert_eq!(bounded_retention_secs(Some(60)), 60);
        assert_eq!(
            bounded_retention_secs(Some(LOCATION_MESSAGE_RETENTION_SECS - 1)),
            LOCATION_MESSAGE_RETENTION_SECS - 1
        );
        assert_eq!(
            bounded_retention_secs(Some(LOCATION_MESSAGE_RETENTION_SECS)),
            LOCATION_MESSAGE_RETENTION_SECS
        );
    }

    #[test]
    fn control_messages_are_never_given_a_retention() {
        // Group history must outlive any TTL: a NIP-40-honouring relay that
        // dropped a commit would strand every late joiner. The bound must not
        // manufacture an expiration for one.
        let bounded = bounded(&GroupMessageMetadata::CommitOrProposal);
        assert_eq!(bounded, GroupMessageMetadata::CommitOrProposal);
        assert_eq!(
            bounded.expiration_timestamp(),
            Ok(None),
            "a commit or proposal must resolve to no expiration timestamp"
        );
    }

    #[test]
    fn an_unstamped_application_message_becomes_stamped() {
        // The whole finding, at the value level: what the engine hands down for
        // a circle created without 0x8005, and what leaves instead.
        let unstamped = GroupMessageMetadata::application(1_000, None);
        assert_eq!(
            unstamped.expiration_timestamp(),
            Ok(None),
            "the engine's own metadata for such a circle stamps nothing"
        );
        assert_eq!(
            bounded(&unstamped).expiration_timestamp(),
            Ok(Some(1_000 + LOCATION_MESSAGE_RETENTION_SECS))
        );
    }

    #[test]
    fn the_inner_created_at_binding_survives_the_bound() {
        // The outer `created_at` is bound to the inner app event's, and the
        // expiration is measured from it; rewriting the retention must not
        // disturb either (upstream #630 cross-client ordering).
        let bounded = bounded(&GroupMessageMetadata::application(12_345, Some(86_400)));
        assert_eq!(bounded.outer_created_at(), Some(12_345));
        assert_eq!(
            bounded.expiration_timestamp(),
            Ok(Some(12_345 + LOCATION_MESSAGE_RETENTION_SECS))
        );
    }
}
