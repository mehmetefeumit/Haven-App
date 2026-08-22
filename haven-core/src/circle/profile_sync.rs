//! Publishing the local user's own profile from the durable outbox.
//!
//! Editing a display name or photo is local and instant
//! ([`CircleStorage::stage_own_profile_edits`] /
//! [`CircleStorage::stage_own_profile_picture`]); this module is the other
//! half — the idempotent, serialized attempt to make the network agree.
//!
//! One pass does: upload a staged picture to Blossom **while** reading the
//! freshest kind-0 back from the whole profile pool, merge the pending edits
//! onto whichever object that read produced, sign one kind-0, publish it to
//! every pool relay, and record exactly how far the coverage got.
//!
//! # Failure is an outcome, not an error
//!
//! [`ProfileSyncOutcome`] reports what happened; `Err` is reserved for local
//! database faults. A failed upload or publish leaves the edit pending with the
//! retry ladder advanced, which is the whole point of the outbox: the user's
//! save is never lost, and the app never claims a network success it did not
//! get.
//!
//! # One sync at a time
//!
//! [`CircleManager::profile_sync_lock`] serializes this body against itself and
//! against the retraction paths in the FFI layer. Without it an in-flight sync
//! could republish just-retracted metadata with a NEWER `created_at` — the
//! retraction would be undone on the relays while every local check reported
//! success. The loser of the race observes the committed state and reports
//! [`ProfileSyncOutcome::NothingPending`].

use nostr::Keys;

use super::error::Result;
use super::manager::CircleManager;
use super::storage::CircleStorage;
use super::storage_profile_sync::ProfileSyncCommit;
use crate::avatar::StagedPicture;
use crate::profile::{
    blossom_server, build_metadata_event, fetch_own_profile, merge_base, merge_edits,
    publish_metadata, upload_profile_picture, ProfileError, ProfilePicture,
};
use crate::relay::RelayManager;

/// What one own-profile sync pass did.
///
/// Scalar-only and deliberately without a catch-all variant, so a new outcome
/// forces every consumer (including the FFI mapping) to decide what it means
/// rather than silently folding into "something went wrong".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileSyncOutcome {
    /// Everything saved is already fully acknowledged; no network was touched.
    NothingPending,
    /// A kind-0 was published and at least one relay acknowledged it.
    Published,
    /// The staged picture could not be uploaded; nothing was published.
    UploadFailed,
    /// The kind-0 was built but no relay accepted it.
    PublishFailed,
    /// Too few uncontaminated profile relays remain to publish at all.
    ///
    /// Terminal and fail-closed: the profile plane never falls back to relays
    /// carrying this account's location traffic.
    PoolUnderflow,
}

/// The result of one own-profile sync pass.
///
/// Counts only — no relay URL and no identifier crosses this type, so its
/// derived [`Debug`] is safe to log and to surface across the FFI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProfileSyncReport {
    /// What the pass did.
    pub outcome: ProfileSyncOutcome,
    /// How many relays acknowledged the published event.
    pub relays_acked: u32,
    /// How many relays the publish was attempted against.
    pub relays_attempted: u32,
    /// Whether a save is STILL unpublished after this pass — the honest answer
    /// even when `outcome` is [`ProfileSyncOutcome::Published`], because a
    /// partial acknowledgement (or an edit saved mid-flight) leaves work behind.
    pub still_pending: bool,
}

impl ProfileSyncReport {
    /// A pass that never reached the network, at a known pending state.
    const fn no_network(outcome: ProfileSyncOutcome, still_pending: bool) -> Self {
        Self {
            outcome,
            relays_acked: 0,
            relays_attempted: 0,
            still_pending,
        }
    }
}

impl CircleManager {
    /// Publishes whatever the own-profile outbox is holding.
    ///
    /// Idempotent: with nothing pending it returns
    /// [`ProfileSyncOutcome::NothingPending`] without constructing a relay
    /// client, so the resume/foreground triggers that call it cost nothing and
    /// disclose nothing. `now` is injected (Unix seconds) so the retry ladder
    /// and the cache stamps are deterministic under test.
    ///
    /// # Errors
    ///
    /// Returns a [`CircleError`](super::error::CircleError) only for LOCAL
    /// faults: a database failure, or a kind-0 that could not be built/signed.
    /// Every network failure is an outcome instead — see the module docs.
    pub async fn sync_own_profile(&self, keys: &Keys, now: i64) -> Result<ProfileSyncReport> {
        // Held for the whole body. See the module docs: this is what stops an
        // in-flight sync from republishing retracted metadata.
        let _guard = self.profile_sync_lock().lock().await;

        let own_pk = keys.public_key();
        let own_hex = own_pk.to_hex();

        // Cheapest question first, and the honest one: with nothing pending
        // there is nothing to report about the relay pool either.
        let Some(snapshot) = self.storage.pending_profile_sync(&own_hex)? else {
            return Ok(ProfileSyncReport::no_network(
                ProfileSyncOutcome::NothingPending,
                false,
            ));
        };
        let pool = match self.storage.usable_profile_relays() {
            Ok(pool) => pool,
            Err(ProfileError::PoolUnderflow { .. }) => {
                // Counts are deliberately NOT logged: on a small pool they are
                // close to an enumeration of which relays this install treats
                // as contaminated.
                log::debug!("[profile] own-profile sync: relay pool underflow (fail-closed)");
                // The ladder advances even though no relay was dialed: an
                // underflowed pool is terminal until the user changes something,
                // and without a persisted backoff every resume trigger would
                // re-materialize the identity secret to reach this same answer.
                self.storage.record_profile_sync_attempt(&own_hex, now)?;
                return Ok(ProfileSyncReport::no_network(
                    ProfileSyncOutcome::PoolUnderflow,
                    true,
                ));
            }
            Err(e) => return Err(e.into()),
        };
        let staged = if snapshot.picture_staged {
            staged_picture(&self.storage, &own_hex)?
        } else {
            None
        };
        let local = self.storage.get_profile(&own_hex)?;
        let salt = self.storage.get_or_create_profile_relay_salt()?;
        let attempted = u32::try_from(pool.len()).unwrap_or(u32::MAX);

        // A signer-less client (`RelayManager::new`), so a relay's NIP-42 AUTH
        // challenge structurally cannot be answered on the read leg.
        let relay = RelayManager::new();
        // The upload and the merge-base read are independent: one talks to a
        // Blossom host, the other to the relay pool. Running them concurrently
        // is what keeps a photo save from costing the sum of both round trips.
        let (uploaded, (fetched, _settled)) = tokio::join!(
            upload_staged_picture(keys, staged),
            fetch_own_profile(&relay, own_pk, &salt, &pool, now),
        );
        let uploaded: Option<ProfilePicture> = match uploaded {
            Some(Ok(picture)) => Some(picture),
            Some(Err(_)) => {
                // No detail is logged: a Blossom/HTTP error string can carry the
                // server URL, and the profile plane logs counts only.
                log::debug!("[profile] own-profile sync: picture upload failed");
                self.storage.record_profile_sync_attempt(&own_hex, now)?;
                return Ok(ProfileSyncReport {
                    outcome: ProfileSyncOutcome::UploadFailed,
                    relays_acked: 0,
                    relays_attempted: 0,
                    still_pending: true,
                });
            }
            None => None,
        };

        let (base, previous_created_at) = merge_base(fetched.as_ref(), local.as_ref());
        let merged = merge_edits(
            &base,
            &snapshot
                .edits
                .to_edits(uploaded.as_ref().map(|p| p.url.clone())),
        );
        let event = build_metadata_event(keys, &merged, previous_created_at)?;

        let Ok(result) = publish_metadata(&relay, &event, &pool).await else {
            log::debug!("[profile] own-profile sync: no relay accepted the kind-0");
            self.storage.record_profile_sync_attempt(&own_hex, now)?;
            return Ok(ProfileSyncReport {
                outcome: ProfileSyncOutcome::PublishFailed,
                relays_acked: 0,
                relays_attempted: attempted,
                still_pending: true,
            });
        };

        // "Fully acked" means EVERY relay we sent to answered yes. Anything less
        // leaves the edit pending: a peer's assignment salt is private to their
        // install, so a relay that refused us is a peer who still reads the old
        // profile.
        let fully_acked = result.accepted_by.len() == result.total_attempted();
        self.storage.commit_profile_sync(&ProfileSyncCommit {
            pubkey: &own_pk,
            published_version: snapshot.local_version,
            merged: &merged,
            event_id: &event.id,
            event_created_at: i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX),
            uploaded_picture_url: uploaded.as_ref().map(|p| p.url.as_str()),
            fully_acked,
            now,
        })?;

        Ok(ProfileSyncReport {
            outcome: ProfileSyncOutcome::Published,
            relays_acked: u32::try_from(result.accepted_by.len()).unwrap_or(u32::MAX),
            relays_attempted: u32::try_from(result.total_attempted()).unwrap_or(u32::MAX),
            // Re-read rather than inferred: the commit is a compare-and-set, so
            // an edit saved while this publish was in flight is still pending
            // even though the publish itself fully landed.
            still_pending: self.storage.pending_profile_sync(&own_hex)?.is_some(),
        })
    }
}

/// Rehydrates the staged picture bytes into the sealed upload type.
///
/// [`StagedPicture::from_sanitized_cache`] recomputes the content hash from the
/// canonical bytes rather than trusting the stored one, so a partially-written
/// row cannot produce a Blossom authorization that commits to a hash the body
/// does not have.
fn staged_picture(storage: &CircleStorage, pubkey_hex: &str) -> Result<Option<StagedPicture>> {
    let (Some(canonical), Some(thumbnail)) = (
        storage.get_profile_picture(pubkey_hex)?,
        storage.get_profile_thumbnail(pubkey_hex)?,
    ) else {
        return Ok(None);
    };
    Ok(Some(StagedPicture::from_sanitized_cache(
        canonical.to_vec(),
        thumbnail.to_vec(),
    )))
}

/// Uploads a staged picture, or resolves to `None` when there is none.
///
/// The server URL is parsed inside the future so a malformed override folds
/// into the same failure path as an unreachable host — there is no third
/// outcome for it to invent.
async fn upload_staged_picture(
    keys: &Keys,
    staged: Option<StagedPicture>,
) -> Option<crate::profile::Result<ProfilePicture>> {
    let staged = staged?;
    let Ok(server) = blossom_server().parse::<url::Url>() else {
        return Some(Err(ProfileError::BadUrl));
    };
    Some(upload_profile_picture(keys, &server, staged).await)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A contiguous ASCII-hex run of 16+ characters — the shape of a pubkey,
    /// an event id or a content hash. Written from scratch rather than through
    /// the crate redactor so it cannot mask a regression in the redactor.
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

    #[test]
    fn a_report_never_carries_a_url_or_an_identifier() {
        // The report crosses the FFI and is logged. Its derived `Debug` is only
        // safe while every field stays a scalar — the moment a URL, a pubkey or
        // an event id lands here it needs a redacting impl, and this is what
        // says so. Field NAMES may of course mention relays; VALUES may not.
        let rendered = format!(
            "{:?}",
            ProfileSyncReport {
                outcome: ProfileSyncOutcome::Published,
                relays_acked: 3,
                relays_attempted: 4,
                still_pending: true,
            }
        );
        for needle in ["://", "@", "npub", "wss", "ws:"] {
            assert!(
                !rendered.contains(needle),
                "profile sync report leaked `{needle}`: {rendered}",
            );
        }
        assert!(
            !has_hex_run_ge16(&rendered),
            "profile sync report leaked an identifier-shaped hex run: {rendered}",
        );
        assert!(rendered.contains('3') && rendered.contains('4'));
    }

    #[test]
    fn a_pass_that_never_reached_the_network_reports_no_relays() {
        // A zero attempted count is load-bearing: the UI must not render "0 of 0
        // relays" as a partial publish.
        let clean = ProfileSyncReport::no_network(ProfileSyncOutcome::NothingPending, false);
        assert_eq!(clean.relays_acked, 0);
        assert_eq!(clean.relays_attempted, 0);
        assert!(!clean.still_pending);

        let underflow = ProfileSyncReport::no_network(ProfileSyncOutcome::PoolUnderflow, true);
        assert!(
            underflow.still_pending,
            "a fail-closed pool leaves the save queued, not discarded",
        );
    }
}
