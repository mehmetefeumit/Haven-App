/// Production implementation of [ProfileService] using the Rust core.
///
/// This implementation:
/// - Reuses the already-open [CircleManagerFfi] handle (same SQLCipher DB as
///   circle/MLS state) rather than opening a second manager — mirrors
///   [`CatchupService`]/[`MaintenanceService`], which take the same
///   `Future<CircleManagerFfi> Function()` factory shape for the same reason.
/// - Resolves the caller's own pubkey/secret via the injected
///   [IdentityService], re-fetching per call through `withFreshSecret`, which
///   owns the fetched buffer and scrubs it the instant the FFI call settles —
///   before the returned profile is assembled, so the secret does not stay
///   live across `_toProfile`'s cache and picture work (Security Rule 9).
/// - Saves unconditionally: `updateOwnProfile`/`setOwnAvatar` carry no
///   consent gate (public-by-default, owner-directed 2026-07-16, matching the
///   White Noise reference app) — see [ProfileService] class doc. They are
///   now LOCAL-FIRST: they merge onto the cache and queue the edit, without
///   touching a relay or Blossom. `syncOwnProfile` is what actually
///   publishes. It fetches the secret, fresh via `withFreshSecret` for that
///   one FFI call, only when a save is waiting to be signed (Security Rule
///   9): a pass that re-sends the published profile to a relay that lacks it
///   signs nothing and reads no secret. The local-only methods need none at
///   all, since the pubkey comes from the manager's own construction keys,
///   never from Dart.
///
/// See `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` (§6.1) for the full design.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';

/// Selects the members from [ffiList] whose picture bytes are not yet
/// cached (`!hasPicture`) — the set worth handing to
/// [CircleManagerFfi.downloadMemberPictures] in [NostrProfileService
/// .refreshMemberProfiles].
///
/// `has_picture` on [ProfileMetadataFfi] means "picture BYTES are already
/// cached" (Rust doc), NOT "a picture URL is set", so this is the useful
/// gate — members that already have bytes cached are left out, exactly as
/// the pre-batch per-member loop did.
///
/// Extracted and `@visibleForTesting` so the selection is unit-testable
/// without the Rust FFI bridge (mirrors `sheetExpansionForSize` in
/// `circles_bottom_sheet.dart`).
@visibleForTesting
List<String> membersNeedingPictureDownload(List<ProfileMetadataFfi> ffiList) {
  return [
    for (final ffi in ffiList)
      if (!ffi.hasPicture) ffi.pubkeyHex,
  ];
}

/// Converts [ffi] to the Dart-layer [ProfileSyncResult] — a pure, exhaustive
/// mapping so no [ProfileSyncOutcomeFfi] value ever leaks above this file.
///
/// `@visibleForTesting`: [ProfileSyncResultFfi] is a plain (non-opaque) data
/// class, so this is the one piece of [NostrProfileService.syncOwnProfile]
/// testable without the Rust bridge.
@visibleForTesting
ProfileSyncResult toProfileSyncResult(ProfileSyncResultFfi ffi) {
  return ProfileSyncResult(
    outcome: switch (ffi.outcome) {
      ProfileSyncOutcomeFfi.nothingPending => ProfileSyncOutcome.nothingPending,
      ProfileSyncOutcomeFfi.published => ProfileSyncOutcome.published,
      ProfileSyncOutcomeFfi.uploadFailed => ProfileSyncOutcome.uploadFailed,
      ProfileSyncOutcomeFfi.publishFailed => ProfileSyncOutcome.publishFailed,
      ProfileSyncOutcomeFfi.poolUnderflow => ProfileSyncOutcome.poolUnderflow,
    },
    stillPending: ffi.stillPending,
  );
}

/// Runs [sync] with the identity secret when [savePending], and with `null`
/// otherwise, so a pass with nothing to sign never takes the secret out of
/// secure storage (Security Rule 9).
///
/// Pure, so the rule is testable without the Rust bridge.
@visibleForTesting
Future<T> syncWithSecretOnlyToSign<T>({
  required bool savePending,
  required Future<List<int>> Function() secretProvider,
  required Future<T> Function(Uint8List? secret) sync,
}) => savePending ? withFreshSecret(secretProvider, sync) : sync(null);

/// Converts [ffi] to the Dart-layer [ProfilePendingState] — see
/// [toProfileSyncResult] for why this is pulled out and testable.
@visibleForTesting
ProfilePendingState toProfilePendingState(ProfilePendingStateFfi ffi) {
  return ProfilePendingState(
    pending: ffi.pending,
    retryDue: ffi.retryDue,
    nextRetryInSecs: ffi.nextRetryInSecs,
  );
}

/// Production implementation of [ProfileService].
///
/// Uses the Rust core (via the shared [CircleManagerFfi] handle) for all
/// kind-0 relay I/O, Blossom I/O, and SQLCipher caching.
class NostrProfileService implements ProfileService {
  /// Creates a [NostrProfileService].
  ///
  /// [circleManagerFactory] MUST return the same authoritative
  /// [CircleManagerFfi] instance the circle service uses (e.g.
  /// `(ref.read(circleServiceProvider) as NostrCircleService)`'s
  /// `getCircleManagerFfi`) — holding a second manager over the same
  /// SQLCipher database would split state across two in-memory MDK/cache
  /// instances.
  NostrProfileService({
    required IdentityService identityService,
    required Future<CircleManagerFfi> Function() circleManagerFactory,
  }) : _identityService = identityService,
       _circleManagerFactory = circleManagerFactory;

  final IdentityService _identityService;
  final Future<CircleManagerFfi> Function() _circleManagerFactory;

  @override
  Future<Profile?> getOwnProfile({bool forceRefresh = false}) async {
    final Identity? identity;
    try {
      identity = await _identityService.getIdentity();
    } on Object catch (e) {
      debugPrint(
        '[Profile] getOwnProfile: identity lookup failed: '
        '${e.runtimeType}',
      );
      throw const ProfileServiceException('Failed to load profile');
    }
    if (identity == null) return null;

    try {
      final manager = await _circleManagerFactory();
      ProfileMetadataFfi? ffi;
      if (forceRefresh) {
        try {
          ffi = await manager.fetchMyProfile(
            pubkeyHex: identity.pubkeyHex,
            force: true,
          );
        } on Object catch (e) {
          // D7: a network hiccup on an explicit refresh must not clobber an
          // existing cached value — fall back to the cache read instead of
          // propagating.
          debugPrint(
            '[Profile] getOwnProfile: refresh failed, falling back to '
            'cache: ${e.runtimeType}',
          );
          ffi = await manager.getCachedProfile(pubkeyHex: identity.pubkeyHex);
        }
      } else {
        ffi = await manager.getCachedProfile(pubkeyHex: identity.pubkeyHex);
      }
      if (ffi == null || !ffi.isKnown) return null;
      return await _toProfile(manager, ffi, fullResolution: true);
    } on Object catch (e) {
      debugPrint('[Profile] getOwnProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to load profile');
    }
  }

  @override
  Future<PublishedOwnProfile> fetchOwnPublishedProfile() async {
    final Identity? identity;
    try {
      identity = await _identityService.getIdentity();
    } on Object catch (e) {
      debugPrint(
        '[Profile] fetchOwnPublishedProfile: identity lookup failed: '
        '${e.runtimeType}',
      );
      throw const ProfileServiceException('Failed to load profile');
    }
    if (identity == null) return const PublishedOwnProfile.unanswered();
    try {
      final manager = await _circleManagerFactory();
      final ffi = await manager.fetchMyProfile(
        pubkeyHex: identity.pubkeyHex,
        force: false,
      );
      return switch (ffi.relayAnswer) {
        OwnProfileRelayAnswerFfi.unanswered =>
          const PublishedOwnProfile.unanswered(),
        OwnProfileRelayAnswerFfi.absent => const PublishedOwnProfile.answered(
          null,
        ),
        OwnProfileRelayAnswerFfi.published => PublishedOwnProfile.answered(
          Profile(
            pubkeyHex: ffi.pubkeyHex,
            name: ffi.name,
            displayName: ffi.displayName,
            about: ffi.about,
            knownAt: DateTime.fromMillisecondsSinceEpoch(ffi.fetchedAt * 1000),
          ),
        ),
      };
    } on Object catch (e) {
      debugPrint('[Profile] fetchOwnPublishedProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to load profile');
    }
  }

  @override
  Future<Profile> updateOwnProfile({
    required String displayName,
    String? about,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      final ffi = await manager.saveMyProfileLocal(
        displayName: displayName,
        about: about,
      );
      return await _toProfile(manager, ffi, fullResolution: true);
    } on Object catch (e) {
      debugPrint('[Profile] updateOwnProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to update profile');
    }
  }

  @override
  Future<Profile> setOwnAvatar(Uint8List raw) async {
    try {
      final manager = await _circleManagerFactory();
      final ref = await manager.saveMyProfilePictureLocal(raw: raw);
      // `saveMyProfilePictureLocal` upserts both the picture bytes and the
      // merged kind-0 into the local cache before returning, so a fresh
      // cache read already reflects the new state — no network round trip.
      final cached = await manager.getCachedProfile(pubkeyHex: ref.pubkeyHex);
      final pictureBytes = await manager.getProfilePicture(
        pubkeyHex: ref.pubkeyHex,
      );
      return Profile(
        pubkeyHex: ref.pubkeyHex,
        name: cached?.name,
        displayName: cached?.displayName,
        about: cached?.about,
        pictureBytes: pictureBytes,
        // Taken from the save response rather than the cache read purely
        // because it is already in hand here. Every read path now also
        // exposes it (`ProfileMetadataFfi.pictureSha256Hex`), so this is no
        // longer the only source — the two agree, both being the sha256 of
        // the same stored bytes.
        pictureHash: ref.sha256Hex,
        knownAt: (cached?.isKnown ?? false)
            ? DateTime.fromMillisecondsSinceEpoch(cached!.fetchedAt * 1000)
            : null,
      );
    } on Object catch (e) {
      debugPrint('[Profile] setOwnAvatar: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to set profile picture');
    }
  }

  @override
  Future<ProfileSyncResult> syncOwnProfile() async {
    try {
      final manager = await _circleManagerFactory();
      final state = await manager.profilePendingState();
      final ffi = await syncWithSecretOnlyToSign(
        savePending: state.savePending,
        secretProvider: _identityService.getSecretBytes,
        sync: (secret) => manager.syncMyProfile(identitySecretBytes: secret),
      );
      return toProfileSyncResult(ffi);
    } on Object catch (e) {
      debugPrint('[Profile] syncOwnProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to sync profile');
    }
  }

  @override
  Future<ProfilePendingState> pendingSyncState() async {
    try {
      final manager = await _circleManagerFactory();
      final ffi = await manager.profilePendingState();
      return toProfilePendingState(ffi);
    } on Object catch (e) {
      debugPrint('[Profile] pendingSyncState: ${e.runtimeType}');
      // Fails closed (see ProfileService.pendingSyncState doc): never report
      // "clean" on a read failure, but never force an automatic retry loop
      // on a persistent local fault either.
      return const ProfilePendingState(pending: true, retryDue: false);
    }
  }

  @override
  Future<Profile> removeOwnAvatar() async {
    // Local-only in Rust, so no secret is fetched (Rule 9).
    try {
      final manager = await _circleManagerFactory();
      final ffi = await manager.removeMyProfilePicture();
      return await _toProfile(manager, ffi, fullResolution: true);
    } on Object catch (e) {
      debugPrint('[Profile] removeOwnAvatar: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to remove profile picture');
    }
  }

  @override
  Future<Profile?> getMemberProfile(
    String pubkeyHex, {
    bool forceRefresh = false,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      ProfileMetadataFfi? ffi;
      if (forceRefresh) {
        final fetched = await manager.fetchMemberProfiles(
          pubkeysHex: [pubkeyHex],
          maxAgeSecs: profileForceMaxAge.inSeconds,
        );
        ffi = fetched.isEmpty ? null : fetched.first;
      } else {
        ffi = await manager.getCachedProfile(pubkeyHex: pubkeyHex);
      }
      if (ffi == null || !ffi.isKnown) return null;
      // Thumbnail-only: this is the lightweight single-pubkey read path
      // (e.g. a member tile). No network picture download is initiated
      // here — that only happens in the batched `refreshMemberProfiles`
      // path, triggered explicitly on circle open/refresh (plan §6.2).
      return await _toProfile(manager, ffi, fullResolution: false);
    } on Object catch (e) {
      debugPrint('[Profile] getMemberProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to load member profile');
    }
  }

  @override
  Future<Map<String, Profile>> getCachedMemberProfiles(
    List<String> pubkeyHexes,
  ) async {
    if (pubkeyHexes.isEmpty) return const {};
    final List<ProfileMetadataFfi> rows;
    try {
      final manager = await _circleManagerFactory();
      // ONE FFI hop resolved under a single connection lock, not a fan-out of
      // one call (and three SQLCipher queries) per pubkey — see
      // `getCachedProfiles`'s own doc for the measured cost of the fan-out
      // this replaced. Returns one row per input pubkey, in input order.
      rows = await manager.getCachedProfiles(pubkeysHex: pubkeyHexes);
    } on Object catch (e) {
      debugPrint('[Profile] getCachedMemberProfiles: ${e.runtimeType}');
      return const {};
    }

    final profiles = <String, Profile>{};
    for (final ffi in rows) {
      // `isKnown: false` is a NEGATIVE-CACHE row: the pubkey was looked up
      // and nothing was found (or never resolved at all — the batch read
      // synthesizes the same row for both), so its blank metadata would
      // claim a name the person does not have. Absent, exactly like a row
      // that never existed.
      if (!ffi.isKnown) continue;
      profiles[ffi.pubkeyHex] = Profile(
        pubkeyHex: ffi.pubkeyHex,
        name: ffi.name,
        displayName: ffi.displayName,
        about: ffi.about,
        // No `pictureBytes`, deliberately — see the interface contract. The
        // hash is what a row uses to fetch its own bytes when it scrolls
        // into view, and to key the decode cache.
        pictureHash: ffi.pictureSha256Hex,
        knownAt: DateTime.fromMillisecondsSinceEpoch(ffi.fetchedAt * 1000),
      );
    }
    return profiles;
  }

  @override
  Future<List<String>> refreshMemberProfiles(
    List<String> pubkeyHexes, {
    Duration maxAge = profileInteractiveMaxAge,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      final ffiList = await manager.fetchMemberProfiles(
        pubkeysHex: pubkeyHexes,
        maxAgeSecs: maxAge.inSeconds,
      );
      return membersNeedingPictureDownload(ffiList);
    } on Object catch (e) {
      debugPrint('[Profile] refreshMemberProfiles: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to refresh member profiles');
    }
  }

  @override
  Future<void> downloadMemberPictures(List<String> pubkeyHexes) async {
    if (pubkeyHexes.isEmpty) return;
    try {
      final manager = await _circleManagerFactory();
      // ONE batched call, not a per-member loop: looping
      // `download_member_picture` from Dart fired the whole roster
      // back-to-back at whatever Blossom host each member chose — commonly
      // the same operator as a default circle relay — which is directly
      // readable as "these are the N people in this user's circles" in one
      // burst. `download_member_pictures` shuffles the order (OS CSPRNG) and
      // downloads strictly one at a time with a randomized delay between
      // requests, bounded by an overall deadline, so there is no burst to
      // fingerprint. Do not "fix" the latency by re-parallelizing.
      await manager.downloadMemberPictures(pubkeysHex: pubkeyHexes);
    } on Object catch (e) {
      // Best-effort per plan §7.2: individual per-member failures are
      // already absorbed on the Rust side.
      debugPrint('[Profile] downloadMemberPictures: ${e.runtimeType}');
    }
  }

  @override
  Future<Profile?> resolveTypedStrangerProfile(String npub) async {
    try {
      final manager = await _circleManagerFactory();
      final ffi = await manager.resolveStrangerProfile(
        pubkey: npub,
        maxAgeSecs: profileInteractiveMaxAge.inSeconds,
      );
      if (ffi == null || !ffi.isKnown) return null;
      // Thumbnail-only, `forcePictureLookup` left at its default `false`:
      // mirrors getMemberProfile exactly. The picture is downloaded by the
      // caller AFTER this returns (`strangerPictureProvider`), never here:
      // waiting on a GET to the person's own server would hold back the name.
      return await _toProfile(manager, ffi, fullResolution: false);
    } on Object catch (e) {
      debugPrint('[Profile] resolveTypedStrangerProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to resolve profile');
    }
  }

  /// Converts [ffi] to a [Profile], loading picture bytes from the local
  /// cache when `ffi.hasPicture` (or [forcePictureLookup]) is `true`.
  ///
  /// [fullResolution] selects [CircleManagerFfi.getProfilePicture] (own
  /// profile / header use) vs. [CircleManagerFfi.getProfileThumbnail]
  /// (member tiles/markers). Never throws — a picture-bytes lookup failure
  /// is logged and the resulting [Profile] simply has no picture.
  ///
  /// Always returns a non-null [Profile] regardless of `ffi.isKnown` — the
  /// nullable "never fetched/published" contract belongs to the callers
  /// that return [Profile]? ([getOwnProfile], [getMemberProfile]); the three
  /// mutators ([updateOwnProfile], [setOwnAvatar], [removeOwnAvatar]) always
  /// have a concrete result to return.
  Future<Profile> _toProfile(
    CircleManagerFfi manager,
    ProfileMetadataFfi ffi, {
    required bool fullResolution,
    bool forcePictureLookup = false,
  }) async {
    Uint8List? pictureBytes;
    if (ffi.hasPicture || forcePictureLookup) {
      try {
        pictureBytes = fullResolution
            ? await manager.getProfilePicture(pubkeyHex: ffi.pubkeyHex)
            : await manager.getProfileThumbnail(pubkeyHex: ffi.pubkeyHex);
      } on Object catch (e) {
        debugPrint('[Profile] picture bytes fetch failed: ${e.runtimeType}');
      }
    }
    return Profile(
      pubkeyHex: ffi.pubkeyHex,
      name: ffi.name,
      displayName: ffi.displayName,
      about: ffi.about,
      pictureBytes: pictureBytes,
      // The avatar decode-cache key. Rust returns this for every read path
      // (not just uploads) and guarantees it is null whenever the cached bytes
      // are stale, so a member swapping their photo yields a new hash and the
      // marker layer re-decodes instead of serving the old avatar forever.
      pictureHash: ffi.pictureSha256Hex,
      knownAt: ffi.isKnown
          ? DateTime.fromMillisecondsSinceEpoch(ffi.fetchedAt * 1000)
          : null,
    );
  }
}
