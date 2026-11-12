//! Publishing the local user's own profile from the durable outbox.
//!
//! Editing a display name or photo, or removing the photo, is local and
//! instant ([`CircleStorage::stage_own_profile_edits`],
//! [`CircleStorage::stage_own_profile_picture`],
//! [`CircleStorage::stage_own_picture_removal`]); this module is the other
//! half — the idempotent, serialized attempt to make the network agree.
//!
//! # Three kinds of pass
//!
//! A **coverage pass** runs when nothing is saved but the pool has a relay the
//! profile's coverage was never settled against — a release that swapped pool
//! relays, a relay the user added, an install whose record a storage reset
//! took. It reads the own kind-0 back from the whole pool and re-sends the
//! newest copy any relay serves, byte for byte, to the relays that lack it.
//! Nothing is signed, so it needs no key. It acts only on a WHOLE read: a
//! relay that did not answer may hold a newer copy — a blank that retracted
//! the one in hand — and re-sending the older one would put it back.
//!
//! A **re-send** runs when a complete signed kind-0 is owed to part of the
//! pool: the identical event goes only to the relays not known to serve it,
//! and each relay that answered is read back. An OK is no evidence (relays
//! answer OK true to an older replaceable they will not store), so a relay
//! counts as covered only when it serves our id. A relay serving a newer own
//! copy, or refusing the owed copy as too old, sends the pass on to one full
//! pass instead; the too-old case at most once per edit.
//!
//! A **full pass** uploads a staged picture to Blossom while reading the
//! freshest kind-0 back from the whole pool, caches that copy when it is newer
//! than the row, merges the pending edits onto it, signs one kind-0 and offers
//! it to every pool relay. A failed upload does not hold back a pending name or
//! removal: they publish without the photo, which stays staged. A pass whose
//! event would carry no saved content (a photo removal alone, or an owed
//! deletion blank) first passes the retraction gate, so it never mints a first
//! public event and never overwrites a profile this device cannot see.
//!
//! # Failure is an outcome, not an error
//!
//! [`ProfileSyncOutcome`] reports what happened; `Err` is reserved for local
//! database faults. Every pass that reaches the pool either completes or
//! advances the persisted retry ladder, dated when the pass ends.
//!
//! # One sync at a time
//!
//! [`CircleManager::profile_sync_lock`] serializes this body against itself and
//! against the deletion path in the FFI layer. Without it an in-flight sync
//! could republish just-deleted metadata with a NEWER `created_at`. The loser
//! of the race observes the committed state and reports
//! [`ProfileSyncOutcome::NothingPending`].

use nostr::{Event, Keys, PublicKey};

use super::error::Result;
use super::manager::CircleManager;
use super::storage::CircleStorage;
use super::storage_profile_sync::{ProfileDebt, ProfileSyncCommit};
use crate::avatar::StagedPicture;
use crate::log_alias::bucket;
use crate::profile::fetch::newest_own_copy;
use crate::profile::{
    blossom_server, build_metadata_event, merge_base, merge_edits, newest_own_event,
    offer_metadata, read_own_per_relay, read_own_profile_on_relays, retraction_gate,
    served_against, uncovered, upload_profile_picture, OwnProfileOnRelays, OwnReadVerdict,
    OwnRelayRead, PendingSnapshot, ProfileError, ProfileMetadata, ProfilePicture, RetractionGate,
    Served,
};
use crate::relay::clock_skew::{classify_clock_refusal, DeviceClockComplaint};
use crate::relay::{PublishResult, RelayManager};

/// What one own-profile sync pass did.
///
/// Scalar-only and deliberately without a catch-all variant, so a new outcome
/// forces every consumer (including the FFI mapping) to decide what it means
/// rather than silently folding into "something went wrong".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileSyncOutcome {
    /// Nothing needed sending: nothing was pending, the pool already serves
    /// what was, or there was nothing public to retract.
    NothingPending,
    /// A relay newly took the profile this pass.
    Published,
    /// The staged picture could not be uploaded, and nothing else was pending.
    UploadFailed,
    /// No relay newly took the profile, or the retraction gate held it back.
    PublishFailed,
    /// Too few uncontaminated profile relays remain to publish at all.
    ///
    /// Terminal and fail-closed: the profile plane never falls back to relays
    /// carrying this account's location traffic.
    PoolUnderflow,
}

/// The result of one own-profile sync pass.
///
/// Scalars only — no relay URL and no identifier crosses this type, so its
/// derived [`Debug`] is safe to log and to surface across the FFI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProfileSyncReport {
    /// What the pass did.
    pub outcome: ProfileSyncOutcome,
    /// Whether the profile is STILL not served by every pool relay after this
    /// pass — the honest answer even when `outcome` is
    /// [`ProfileSyncOutcome::Published`], because a relay that missed it (or
    /// an edit saved mid-flight) leaves work behind.
    pub still_pending: bool,
}

impl ProfileSyncReport {
    /// A pass that never reached the network, at a known pending state.
    const fn no_network(outcome: ProfileSyncOutcome, still_pending: bool) -> Self {
        Self {
            outcome,
            still_pending,
        }
    }
}

/// What the relays that answered a re-send serve, relay by relay.
#[derive(Default)]
struct ReadBack {
    /// Relays now serving the owed event.
    newly_covered: Vec<String>,
    /// Every event a relay serving a newer own copy sent.
    newer: Vec<Event>,
    /// A relay refused the owed event on timestamp grounds and does not serve it.
    stale: bool,
}

/// What a full pass publishes, once the upload and the read are in.
struct Publish {
    merged: ProfileMetadata,
    previous_created_at: Option<u64>,
    uploaded: Option<ProfilePicture>,
    /// The event carries every pending item (no upload failed).
    complete: bool,
}

/// What a pass that has work to do works with: the usable pool, the newest
/// saved version (the pending one, or the settled one a coverage pass records
/// against), and the event owed to part of the pool at that version.
type Scope = (Vec<String>, i64, Option<ProfileDebt>);

/// What a coverage pass re-sends: the newest own kind-0 the pool serves, the
/// relays serving it, and the relays that answered without it.
type Owed<'a> = (&'a Event, Vec<String>, Vec<String>);

/// A full pass either publishes or has already ended.
enum Next {
    Publish(Box<Publish>),
    /// Nothing was ever published, so the pending removal is settled locally.
    Settle,
    Done(ProfileSyncReport),
}

impl CircleManager {
    /// Publishes whatever the own-profile outbox is holding, and re-sends the
    /// published profile to a pool relay that has never been given it.
    ///
    /// Idempotent: with nothing saved and the pool's coverage settled it
    /// returns [`ProfileSyncOutcome::NothingPending`] without constructing a
    /// relay client, so the resume/foreground triggers that call it cost
    /// nothing and disclose nothing. `clock` (Unix seconds) is read again at
    /// every record, so the retry ladder is dated when the pass ends, not when
    /// it began.
    ///
    /// `keys` is what a pending save is signed with. A pass with nothing saved
    /// signs nothing and takes `None`, so a caller need not materialise the
    /// identity key to find out; a save that lands while such a pass runs is
    /// left for the pass its own trigger starts.
    ///
    /// # Errors
    ///
    /// Returns a [`CircleError`](super::error::CircleError) only for LOCAL
    /// faults: a database failure, or a kind-0 that could not be built/signed.
    /// Every network failure is an outcome instead — see the module docs.
    pub async fn sync_own_profile(
        &self,
        own_pk: &PublicKey,
        keys: Option<&Keys>,
        clock: impl Fn() -> i64 + Send + Sync,
    ) -> Result<ProfileSyncReport> {
        // Held for the whole body. See the module docs: this is what stops an
        // in-flight sync from republishing deleted metadata.
        let _guard = self.profile_sync_lock().lock().await;

        let own_hex = own_pk.to_hex();
        // The retraction gate's input, read under the lock and before anything
        // below can leave the device.
        let published_here = self.storage.has_published_profile(own_pk)?;
        let snapshot = self.storage.pending_profile_sync(&own_hex)?;
        let (pool, version, debt) = match self.scope(own_pk, snapshot.as_ref(), &clock)? {
            Ok(scope) => scope,
            Err(report) => return Ok(report),
        };

        // A signer-less client (`RelayManager::new`), so a relay's NIP-42 AUTH
        // challenge structurally cannot be answered.
        let relay = RelayManager::new();

        if let Some(debt) = debt {
            let owed = uncovered(&pool, &debt.covered);
            let found = if owed.is_empty() {
                ReadBack::default()
            } else {
                log::debug!(
                    "[profile] own-profile sync: offering the owed kind-0 to {} relay(s)",
                    bucket(owed.len())
                );
                let offer = offer_metadata(&relay, &debt.event, &owed).await.ok();
                read_back(&relay, *own_pk, &debt.event, offer.as_ref()).await
            };
            // With nothing saved there is nothing to sign afresh: a copy a
            // relay refuses as too old stays owed to it.
            let resigned = snapshot.as_ref().is_none_or(|s| s.edits.resigned);
            if let Some(report) =
                self.close_resend(own_pk, resigned, &debt, &found, &pool, clock())?
            {
                return Ok(report);
            }
        }

        let Some(snapshot) = snapshot else {
            let reads = read_own_per_relay(&relay, *own_pk, &pool).await;
            let served: Vec<Event> = reads.iter().flat_map(|r| r.served.clone()).collect();
            let judged = self.judge_coverage(own_pk, version, &reads, &served, &pool, clock())?;
            let (event, covered, lacking) = match judged {
                Ok(owed) => owed,
                Err(report) => return Ok(report),
            };
            log::debug!(
                "[profile] own-profile sync: offering the served kind-0 to {} relay(s)",
                bucket(lacking.len())
            );
            let offer = offer_metadata(&relay, event, &lacking).await.ok();
            let found = read_back(&relay, *own_pk, event, offer.as_ref()).await;
            return self.close_coverage(own_pk, version, (event, covered, found), &pool, clock());
        };
        // A save made after the caller found nothing to sign: its own trigger
        // brings the key.
        let Some(keys) = keys else {
            return self.reported(&own_hex, ProfileSyncOutcome::PublishFailed);
        };

        let staged = self.staged_now(&own_hex, &snapshot)?;
        // A removal landed after the snapshot: what it describes is gone, and
        // building on it would re-sign the removed photo. Nothing was tried,
        // so the ladder stays where the removal reset it.
        if snapshot.picture_staged && staged.is_none() {
            return self.reported(&own_hex, ProfileSyncOutcome::PublishFailed);
        }
        let staged_sha256 = staged.as_ref().map(|picture| *picture.sha256());
        // The upload and the merge-base read are independent: one talks to a
        // Blossom host, the other to the relay pool. Running them concurrently
        // is what keeps a photo save from costing the sum of both round trips.
        // The server URL is parsed inside the future so a malformed override
        // folds into the same failure path as an unreachable host.
        let upload = async {
            let staged = staged?;
            let Ok(server) = blossom_server().parse::<url::Url>() else {
                return Some(Err(ProfileError::BadUrl));
            };
            Some(upload_profile_picture(keys, &server, staged).await)
        };
        let (uploaded, read) = tokio::join!(
            upload,
            read_own_profile_on_relays(&relay, *own_pk, &pool, clock()),
        );
        let plan =
            match self.plan_publish(own_pk, &snapshot, published_here, uploaded, read, &clock)? {
                Next::Publish(plan) => *plan,
                Next::Settle => {
                    return self.settle_removal(&own_hex, snapshot.local_version, &pool);
                }
                Next::Done(report) => return Ok(report),
            };
        let event = build_metadata_event(keys, &plan.merged, plan.previous_created_at)?;

        let Some(result) = offer_metadata(&relay, &event, &pool)
            .await
            .ok()
            .filter(PublishResult::is_success)
        else {
            log::debug!("[profile] own-profile sync: no relay accepted the kind-0");
            self.storage
                .record_profile_sync_attempt(&own_hex, clock())?;
            return self.reported(&own_hex, ProfileSyncOutcome::PublishFailed);
        };

        // Anything short of every pool relay leaves the edit pending: a peer's
        // assignment salt is private to their install, so a relay that refused
        // us is a peer who still reads the old profile.
        self.storage.commit_profile_sync(&ProfileSyncCommit {
            pubkey: own_pk,
            version: snapshot.local_version,
            merged: &plan.merged,
            event: &event,
            uploaded_picture: plan
                .uploaded
                .as_ref()
                .zip(staged_sha256.as_ref())
                .map(|(picture, sha256)| (picture.url.as_str(), sha256.as_slice())),
            covered: &result.accepted_by,
            pool: &pool,
            complete: plan.complete,
            now: clock(),
        })?;
        self.reported(&own_hex, ProfileSyncOutcome::Published)
    }

    /// The picture `snapshot` says is staged, as the outbox holds it now.
    fn staged_now(
        &self,
        own_hex: &str,
        snapshot: &PendingSnapshot,
    ) -> Result<Option<StagedPicture>> {
        #[cfg(any(test, feature = "test-utils"))]
        if let Some(edit) = self.take_mid_profile_sync() {
            edit(self);
        }
        if snapshot.picture_staged {
            staged_picture(&self.storage, own_hex)
        } else {
            Ok(None)
        }
    }

    /// Records what a re-send's read-back proved, or returns `None` when the
    /// owed event is superseded and one full pass must rebuild it.
    fn close_resend(
        &self,
        own_pk: &PublicKey,
        resigned: bool,
        debt: &ProfileDebt,
        found: &ReadBack,
        pool: &[String],
        now: i64,
    ) -> Result<Option<ProfileSyncReport>> {
        let own_hex = own_pk.to_hex();
        let redirect = !found.newer.is_empty();
        if redirect || (found.stale && !resigned) {
            if let Some(copy) = newest_own_copy(own_pk, &found.newer, now) {
                self.storage.upsert_profile_if_newer(&copy)?;
            }
            self.storage
                .discard_profile_publish_debt(&own_hex, debt.version)?;
            if !redirect {
                self.storage.mark_profile_resigned(&own_hex, debt.version)?;
            }
            log::debug!("[profile] own-profile sync: the owed kind-0 is superseded; rebuilding");
            return Ok(None);
        }
        let owed = uncovered(pool, &debt.covered).len();
        log::debug!(
            "[profile] own-profile sync: coverage newly={} owed={}",
            bucket(found.newly_covered.len()),
            bucket(owed.saturating_sub(found.newly_covered.len()))
        );
        self.storage.commit_profile_coverage(
            &own_hex,
            debt.version,
            &found.newly_covered,
            pool,
            now,
        )?;
        let outcome = if owed == 0 {
            ProfileSyncOutcome::NothingPending
        } else if found.newly_covered.is_empty() {
            ProfileSyncOutcome::PublishFailed
        } else {
            ProfileSyncOutcome::Published
        };
        self.reported(&own_hex, outcome).map(Some)
    }

    /// The pool, version and owed event of this pass — or the report it ends
    /// with at once, having dialled nothing: nothing saved and the pool's
    /// coverage settled, or a pool too small to use.
    fn scope(
        &self,
        own_pk: &PublicKey,
        snapshot: Option<&PendingSnapshot>,
        clock: &(impl Fn() -> i64 + Sync),
    ) -> Result<std::result::Result<Scope, ProfileSyncReport>> {
        let own_hex = own_pk.to_hex();
        let nothing = ProfileSyncReport::no_network(ProfileSyncOutcome::NothingPending, false);
        let pool = match self.storage.usable_profile_relays() {
            Ok(pool) => pool,
            // Nothing saved, and nowhere coverage could be owed to.
            Err(ProfileError::PoolUnderflow { .. }) if snapshot.is_none() => {
                return Ok(Err(nothing));
            }
            Err(ProfileError::PoolUnderflow { .. }) => {
                // Counts are deliberately NOT logged: on a small pool they are
                // close to an enumeration of which relays this install treats
                // as contaminated.
                log::debug!("[profile] own-profile sync: relay pool underflow (fail-closed)");
                // The ladder advances even though no relay was dialed: an
                // underflowed pool is terminal until the user changes something,
                // and without a persisted backoff every resume trigger would
                // re-materialize the identity secret to reach this same answer.
                self.storage
                    .record_profile_sync_attempt(&own_hex, clock())?;
                return Ok(Err(ProfileSyncReport::no_network(
                    ProfileSyncOutcome::PoolUnderflow,
                    true,
                )));
            }
            Err(e) => return Err(e.into()),
        };
        let version = match snapshot {
            Some(snapshot) => snapshot.local_version,
            None => self.storage.profile_sync_version(&own_hex)?,
        };
        let debt = self.storage.profile_publish_debt(own_pk, version)?;
        if snapshot.is_none()
            && debt.is_none()
            && !self.storage.profile_coverage_owed(&own_hex, &pool)?
        {
            return Ok(Err(nothing));
        }
        Ok(Ok((pool, version, debt)))
    }

    /// Levels a pending removal with nothing sent: every relay of `pool`
    /// answered without a profile to remove it from.
    fn settle_removal(
        &self,
        own_hex: &str,
        version: i64,
        pool: &[String],
    ) -> Result<ProfileSyncReport> {
        self.storage.settle_profile_sync(own_hex, version, pool)?;
        self.reported(own_hex, ProfileSyncOutcome::NothingPending)
    }

    /// Reads what a coverage pass owes off one whole-pool read of the own
    /// kind-0, caching the newest copy served — or ends the pass: on the retry
    /// ladder when some relay did not answer, settled when no relay lacks the
    /// profile the pool serves.
    fn judge_coverage<'a>(
        &self,
        own_pk: &PublicKey,
        version: i64,
        reads: &[OwnRelayRead],
        served: &'a [Event],
        pool: &[String],
        now: i64,
    ) -> Result<std::result::Result<Owed<'a>, ProfileSyncReport>> {
        let own_hex = own_pk.to_hex();
        let settled = || {
            self.storage
                .settle_profile_coverage(&own_hex, version, pool)?;
            self.reported(&own_hex, ProfileSyncOutcome::NothingPending)
                .map(Err)
        };
        let newest = newest_own_event(own_pk, served);
        let holds = |read: &OwnRelayRead| {
            newest.is_some_and(|e| served_against(own_pk, e, &read.served) == Served::Holds)
        };
        // A relay that did not end its answer may hold a newer copy than the
        // one in hand — a blank that retracted it.
        if reads.len() != pool.len() || !reads.iter().all(|r| r.drained || holds(r)) {
            self.storage
                .record_profile_coverage_attempt(&own_hex, version, now)?;
            return self
                .reported(&own_hex, ProfileSyncOutcome::PublishFailed)
                .map(Err);
        }
        let Some(event) = newest else {
            return settled();
        };
        if let Some(copy) = newest_own_copy(own_pk, served, now) {
            self.storage.upsert_profile_if_newer(&copy)?;
        }
        // This device has published since: what the relays serve is the
        // profile it replaced, and is not put on a relay that lacks it.
        let superseded = self.storage.get_profile(&own_hex)?.is_some_and(|row| {
            u64::try_from(row.event_created_at).is_ok_and(|at| at > event.created_at.as_secs())
        });
        let covered: Vec<String> = reads
            .iter()
            .filter(|r| holds(r))
            .map(|r| r.relay_url.clone())
            .collect();
        let lacking = uncovered(pool, &covered);
        if superseded || lacking.is_empty() {
            return settled();
        }
        Ok(Ok((event, covered, lacking)))
    }

    /// Records what the read-back of a coverage pass's offer proved.
    fn close_coverage(
        &self,
        own_pk: &PublicKey,
        version: i64,
        (event, mut covered, found): (&Event, Vec<String>, ReadBack),
        pool: &[String],
        now: i64,
    ) -> Result<ProfileSyncReport> {
        let own_hex = own_pk.to_hex();
        // A relay now serves a newer own copy: the one offered is superseded,
        // and the next pass reads the pool afresh.
        if let Some(copy) = newest_own_copy(own_pk, &found.newer, now) {
            self.storage.upsert_profile_if_newer(&copy)?;
            self.storage
                .record_profile_coverage_attempt(&own_hex, version, now)?;
            return self.reported(&own_hex, ProfileSyncOutcome::PublishFailed);
        }
        log::debug!(
            "[profile] own-profile sync: coverage newly={}",
            bucket(found.newly_covered.len())
        );
        let outcome = if found.newly_covered.is_empty() {
            ProfileSyncOutcome::PublishFailed
        } else {
            ProfileSyncOutcome::Published
        };
        covered.extend(found.newly_covered);
        if uncovered(pool, &covered).is_empty() {
            self.storage
                .settle_profile_coverage(&own_hex, version, pool)?;
        } else {
            self.storage
                .owe_profile_coverage(&own_hex, version, event, &covered, now)?;
        }
        self.reported(&own_hex, outcome)
    }

    /// Decides, from the upload and the whole-pool read, what a full pass
    /// publishes — or ends the pass when it must publish nothing.
    fn plan_publish(
        &self,
        own_pk: &PublicKey,
        snapshot: &PendingSnapshot,
        published_here: bool,
        uploaded: Option<crate::profile::Result<ProfilePicture>>,
        read: OwnProfileOnRelays,
        clock: &(impl Fn() -> i64 + Sync),
    ) -> Result<Next> {
        let own_hex = own_pk.to_hex();
        let (fetched, verdict) = match read {
            OwnProfileOnRelays::Published(copy) => (Some(*copy), OwnReadVerdict::Found),
            OwnProfileOnRelays::Absent => (None, OwnReadVerdict::Absent),
            OwnProfileOnRelays::Unverified => (None, OwnReadVerdict::Unanswered),
        };
        // A copy read is kept when it is newer, before anything below can
        // fail: a publish that does not land must not leave the row older than
        // what this pass saw, or the retry could build on an older copy
        // another relay still serves and sign back a field another client had
        // removed. The write keeps the queued edits on top.
        if let Some(fetched) = &fetched {
            self.storage.upsert_profile_if_newer(fetched)?;
        }
        let local = self.storage.get_profile(&own_hex)?;
        let edits = &snapshot.edits;
        let has_text = edits.display_name.is_some() || edits.about.is_some();
        let (uploaded, complete) = match uploaded {
            Some(Ok(picture)) => (Some(picture), true),
            // No detail is logged: a Blossom/HTTP error string can carry the
            // server URL, and the profile plane logs counts only.
            Some(Err(_)) if has_text || edits.clear_picture => {
                log::debug!(
                    "[profile] own-profile sync: picture upload failed; publishing the text edits alone"
                );
                (None, false)
            }
            Some(Err(_)) => {
                log::debug!("[profile] own-profile sync: picture upload failed");
                return self.attempted(&own_hex, ProfileSyncOutcome::UploadFailed, clock());
            }
            None => (None, true),
        };
        // Judged on what this pass will actually publish: a name or a photo URL
        // publishes unconditionally; a removal alone or an owed blank does not.
        if !has_text && uploaded.is_none() {
            let local_dated = local.as_ref().is_some_and(|row| row.event_created_at > 0);
            match retraction_gate(published_here, verdict, local_dated) {
                RetractionGate::Publish => {}
                // A photo whose upload failed is still owed.
                RetractionGate::Settle if !complete => {
                    return self.attempted(&own_hex, ProfileSyncOutcome::UploadFailed, clock());
                }
                RetractionGate::Settle => {
                    log::debug!(
                        "[profile] own-profile sync: nothing was ever published; the removal is settled locally"
                    );
                    return Ok(Next::Settle);
                }
                RetractionGate::Hold => {
                    log::debug!("[profile] own-profile sync: no copy to build on; holding");
                    return self.attempted(&own_hex, ProfileSyncOutcome::PublishFailed, clock());
                }
            }
        }
        let (base, previous_created_at) = merge_base(fetched.as_ref(), local.as_ref());
        let merged = merge_edits(
            &base,
            &edits.to_edits(uploaded.as_ref().map(|p| p.url.clone())),
        );
        Ok(Next::Publish(Box::new(Publish {
            merged,
            previous_created_at,
            uploaded,
            complete,
        })))
    }

    /// Advances the retry ladder and ends the pass with `outcome`.
    fn attempted(&self, own_hex: &str, outcome: ProfileSyncOutcome, now: i64) -> Result<Next> {
        self.storage.record_profile_sync_attempt(own_hex, now)?;
        self.reported(own_hex, outcome).map(Next::Done)
    }

    /// `outcome`, with whether anything is still pending re-read rather than
    /// inferred: every commit is a compare-and-set, so an edit saved while the
    /// pass was in flight is still pending even when its publish fully landed.
    fn reported(&self, own_hex: &str, outcome: ProfileSyncOutcome) -> Result<ProfileSyncReport> {
        Ok(ProfileSyncReport {
            outcome,
            still_pending: self.own_profile_owes_sync(own_hex)?,
        })
    }

    /// Whether the own profile has a save to publish, or a pool relay its
    /// coverage was never settled against. An underflowed pool is owed nothing:
    /// there is nowhere to send it.
    pub(super) fn own_profile_owes_sync(&self, own_hex: &str) -> Result<bool> {
        if self.storage.pending_profile_sync(own_hex)?.is_some() {
            return Ok(true);
        }
        match self.storage.usable_profile_relays() {
            Ok(pool) => self.storage.profile_coverage_owed(own_hex, &pool),
            Err(ProfileError::PoolUnderflow { .. }) => Ok(false),
            Err(e) => Err(e.into()),
        }
    }
}

/// Reads back each relay that answered a re-send and orders what it serves
/// against the owed event.
///
/// A relay that served our id holds it whether or not it ended its answer;
/// only absence needs its `EOSE`. A relay that stayed silent on the offer is
/// not asked: its connect failed or its `OK` never came.
async fn read_back(
    relay: &RelayManager,
    own_pk: PublicKey,
    owed: &Event,
    offer: Option<&PublishResult>,
) -> ReadBack {
    let Some(offer) = offer else {
        return ReadBack::default();
    };
    let answered: Vec<String> = offer
        .accepted_by
        .iter()
        .chain(offer.rejected_by.iter().map(|(url, _)| url))
        .cloned()
        .collect();
    if answered.is_empty() {
        return ReadBack::default();
    }
    // The reason is classified by its prefix only, and never logged. A
    // verdict that the event is from the future is not cured by signing it
    // again now.
    let refused_as_old: Vec<String> = offer
        .rejected_by
        .iter()
        .filter(|(_, reason)| {
            matches!(
                classify_clock_refusal(reason),
                Some(DeviceClockComplaint::Behind | DeviceClockComplaint::Unspecified)
            )
        })
        .map(|(url, _)| url.clone())
        .collect();
    let mut found = ReadBack::default();
    for read in read_own_per_relay(relay, own_pk, &answered).await {
        match served_against(&own_pk, owed, &read.served) {
            Served::Holds => found.newly_covered.push(read.relay_url),
            Served::Newer => found.newer.extend(read.served),
            Served::Lacks => {
                found.stale |= read.drained && names(&refused_as_old, &read.relay_url);
            }
        }
    }
    found
}

/// Whether `relays` names `relay`, compared as [`uncovered`] compares them.
fn names(relays: &[String], relay: &str) -> bool {
    uncovered(&[relay.to_owned()], relays).is_empty()
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
        assert!(rendered.contains("Published") && rendered.contains("true"));
    }

    #[tokio::test]
    async fn a_pass_that_never_reached_the_network_reports_its_pending_state() {
        // The pending flag is load-bearing: the UI must not read a pass that
        // dialled nothing as either "synced" or "lost".
        let clean = ProfileSyncReport::no_network(ProfileSyncOutcome::NothingPending, false);
        assert_eq!(clean.outcome, ProfileSyncOutcome::NothingPending);
        assert!(!clean.still_pending);

        let underflow = ProfileSyncReport::no_network(ProfileSyncOutcome::PoolUnderflow, true);
        assert_eq!(underflow.outcome, ProfileSyncOutcome::PoolUnderflow);
        assert!(
            underflow.still_pending,
            "a fail-closed pool leaves the save queued, not discarded",
        );

        // The real pass, not just the constructor: an empty outbox whose
        // coverage is settled answers `NothingPending` and "nothing owed"
        // without constructing a relay client.
        let dir = tempfile::TempDir::new().expect("temp dir");
        let keys = Keys::generate();
        let own_hex = keys.public_key().to_hex();
        let manager = CircleManager::new_unencrypted(dir.path(), &keys).expect("manager opens");
        let pool = manager.usable_profile_relays().expect("the curated pool");
        assert!(
            manager
                .profile_pending_state(&own_hex, 1_800_000_000)
                .expect("pending state")
                .pending,
            "an install with no record of what the pool serves owes it a look",
        );
        manager
            .storage
            .settle_profile_coverage(&own_hex, 0, &pool)
            .expect("settle");
        assert!(
            !manager
                .profile_pending_state(&own_hex, 1_800_000_000)
                .expect("pending state")
                .pending
        );
        let report = manager
            .sync_own_profile(&keys.public_key(), Some(&keys), || 1_800_000_000)
            .await
            .expect("an empty outbox is not an error");
        assert_eq!(report, clean);
    }
}
