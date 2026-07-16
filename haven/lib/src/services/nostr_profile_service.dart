/// Production implementation of [ProfileService] using the Rust core.
///
/// This implementation:
/// - Reuses the already-open [CircleManagerFfi] handle (same SQLCipher DB as
///   circle/MLS state) rather than opening a second manager — mirrors
///   [`CatchupService`]/[`MaintenanceService`], which take the same
///   `Future<CircleManagerFfi> Function()` factory shape for the same reason.
/// - Resolves the caller's own pubkey/secret via the injected
///   [IdentityService], re-fetching secret bytes per call and scrubbing
///   them in a `finally` (Security Rule 9 — mirrors
///   `MaintenanceService._withSecret`).
/// - Publishes unconditionally: `updateOwnProfile`/`setOwnAvatar` carry no
///   consent gate (public-by-default, owner-directed 2026-07-16, matching the
///   White Noise reference app) — see [ProfileService] class doc.
///
/// See `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` (§6.1) for the full design.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';

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
      debugPrint('[Profile] getOwnProfile: identity lookup failed: '
          '${e.runtimeType}');
      throw const ProfileServiceException('Failed to load profile');
    }
    if (identity == null) return null;

    try {
      final manager = await _circleManagerFactory();
      ProfileMetadataFfi? ffi;
      if (forceRefresh) {
        try {
          ffi = await manager.fetchMyProfile(pubkeyHex: identity.pubkeyHex);
        } on Object catch (e) {
          // D7: a network hiccup on an explicit refresh must not clobber an
          // existing cached value — fall back to the cache read instead of
          // propagating.
          debugPrint(
            '[Profile] getOwnProfile: refresh failed, falling back to '
            'cache: ${e.runtimeType}',
          );
          ffi = manager.getCachedProfile(pubkeyHex: identity.pubkeyHex);
        }
      } else {
        ffi = manager.getCachedProfile(pubkeyHex: identity.pubkeyHex);
      }
      if (ffi == null || !ffi.isKnown) return null;
      return await _toProfile(manager, ffi, fullResolution: true);
    } on Object catch (e) {
      debugPrint('[Profile] getOwnProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to load profile');
    }
  }

  @override
  Future<Profile> updateOwnProfile({
    required String displayName,
    String? about,
  }) async {
    Uint8List? secretBuffer;
    try {
      final manager = await _circleManagerFactory();
      secretBuffer = Uint8List.fromList(
        await _identityService.getSecretBytes(),
      );
      final ffi = await manager.publishMyProfile(
        identitySecretBytes: secretBuffer,
        displayName: displayName,
        about: about,
      );
      return await _toProfile(manager, ffi, fullResolution: true);
    } on Object catch (e) {
      debugPrint('[Profile] updateOwnProfile: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to update profile');
    } finally {
      secretBuffer?.fillRange(0, secretBuffer.length, 0);
    }
  }

  @override
  Future<Profile> setOwnAvatar(Uint8List raw) async {
    Uint8List? secretBuffer;
    try {
      final manager = await _circleManagerFactory();
      secretBuffer = Uint8List.fromList(
        await _identityService.getSecretBytes(),
      );
      final ref = await manager.uploadMyProfilePicture(
        identitySecretBytes: secretBuffer,
        raw: raw,
      );
      // `uploadMyProfilePicture` upserts both the picture bytes and the
      // merged kind-0 into the local cache before returning (Rust
      // `upload_my_profile_picture`), so a synchronous cache read already
      // reflects the new state — no extra network round trip needed.
      final cached = manager.getCachedProfile(pubkeyHex: ref.pubkeyHex);
      final pictureBytes = await manager.getProfilePicture(
        pubkeyHex: ref.pubkeyHex,
      );
      return Profile(
        pubkeyHex: ref.pubkeyHex,
        name: cached?.name,
        displayName: cached?.displayName,
        about: cached?.about,
        pictureBytes: pictureBytes,
        // The sha256 is only available here, from the upload response —
        // no other read path (`get_cached_profile`/`fetch_member_profiles`/
        // `fetch_my_profile`) exposes it on `ProfileMetadataFfi`. See the
        // Wave 3b summary for this known FFI-surface gap.
        pictureHash: ref.sha256Hex,
        knownAt: (cached?.isKnown ?? false)
            ? DateTime.fromMillisecondsSinceEpoch(
                cached!.fetchedAt * 1000,
              )
            : null,
      );
    } on Object catch (e) {
      debugPrint('[Profile] setOwnAvatar: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to set profile picture');
    } finally {
      secretBuffer?.fillRange(0, secretBuffer.length, 0);
    }
  }

  @override
  Future<Profile> removeOwnAvatar() async {
    // Retraction is always allowed — see class doc.
    Uint8List? secretBuffer;
    try {
      final manager = await _circleManagerFactory();
      secretBuffer = Uint8List.fromList(
        await _identityService.getSecretBytes(),
      );
      final ffi = await manager.removeMyProfilePicture(
        identitySecretBytes: secretBuffer,
      );
      return await _toProfile(manager, ffi, fullResolution: true);
    } on Object catch (e) {
      debugPrint('[Profile] removeOwnAvatar: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to remove profile picture');
    } finally {
      secretBuffer?.fillRange(0, secretBuffer.length, 0);
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
          force: true,
        );
        ffi = fetched.isEmpty ? null : fetched.first;
      } else {
        ffi = manager.getCachedProfile(pubkeyHex: pubkeyHex);
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
  Future<Map<String, Profile>> refreshMemberProfiles(
    List<String> pubkeyHexes, {
    bool force = false,
  }) async {
    try {
      final manager = await _circleManagerFactory();
      final ffiList = await manager.fetchMemberProfiles(
        pubkeysHex: pubkeyHexes,
        force: force,
      );
      final result = <String, Profile>{};
      for (final ffi in ffiList) {
        // Absent from the result, not an error — mirrors the interface doc
        // ("a pubkey that was never found on any relay ... is simply absent
        // from the result").
        if (!ffi.isKnown) continue;
        // `has_picture` on `ProfileMetadataFfi` means "picture BYTES are
        // already cached" (Rust doc), NOT "a picture URL is set" — so the
        // useful moment to download is when bytes are NOT yet cached.
        // `download_member_picture` is itself a no-op when the cached
        // kind-0 has no `picture` URL, so this is safe to call speculatively.
        if (!ffi.hasPicture) {
          try {
            await manager.downloadMemberPicture(pubkeyHex: ffi.pubkeyHex);
          } on Object catch (e) {
            // Best-effort per plan §7.2 — one member's picture failure must
            // not drop the whole batch.
            debugPrint(
              '[Profile] refreshMemberProfiles picture download failed: '
              '${e.runtimeType}',
            );
          }
        }
        // Force the picture lookup regardless of the (possibly now-stale)
        // `hasPicture` flag above — a download may have just populated it.
        result[ffi.pubkeyHex] = await _toProfile(
          manager,
          ffi,
          fullResolution: false,
          forcePictureLookup: true,
        );
      }
      return result;
    } on Object catch (e) {
      debugPrint('[Profile] refreshMemberProfiles: ${e.runtimeType}');
      throw const ProfileServiceException('Failed to refresh member profiles');
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
      knownAt: ffi.isKnown
          ? DateTime.fromMillisecondsSinceEpoch(ffi.fetchedAt * 1000)
          : null,
    );
  }
}
