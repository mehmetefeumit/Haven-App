/// Mock implementation of [ProfileService] for testing.
///
/// Provides controllable behavior for unit tests without requiring
/// Rust FFI, a relay connection, or a Blossom server. This is what every
/// future profile provider/widget test overrides via
/// `ProviderScope(overrides: [...])`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/services/profile_service.dart';

/// A mock [ProfileService] for testing.
///
/// Allows tests to control:
/// - What the user's own profile and each member's profile look like
/// - Whether individual operations succeed or fail
/// - The local-outbox state [syncOwnProfile]/[pendingSyncState] report,
///   including holding either in flight via a `Completer` gate — the same
///   shape as [refreshGate] — so provider/widget tests can observe an
///   in-flight sync deterministically, with no sleeps or timing races.
///
/// Saving is unconditional (no consent gate) — [updateOwnProfile] and
/// [setOwnAvatar] always run. [pendingSyncState] defaults to "clean"
/// (`pending: false`) so a test that never touches sync state does not
/// accidentally drive [syncOwnProfile] via `OwnProfileSyncController`'s
/// own build()-time `retryIfPending()`.
class MockProfileService implements ProfileService {
  /// Creates a mock profile service.
  ///
  /// By default, [ownProfile] is `null`, [memberProfiles] is empty, and
  /// every operation succeeds.
  MockProfileService({
    this.ownProfile,
    Map<String, Profile>? memberProfiles,
    this.ownPubkeyHex = _defaultOwnPubkeyHex,
  }) : memberProfiles = memberProfiles ?? {};

  static const _defaultOwnPubkeyHex =
      'abc123def456abc123def456abc123def456abc123def456abc123def456abcd';

  /// The profile returned by [getOwnProfile], and the base profile
  /// mutated in place by [updateOwnProfile] / [setOwnAvatar] /
  /// [removeOwnAvatar]. Settable directly by tests.
  Profile? ownProfile;

  /// Member profiles keyed by pubkeyHex, backing [getMemberProfile] and
  /// [refreshMemberProfiles]. Settable directly by tests.
  final Map<String, Profile> memberProfiles;

  /// Pubkey used to synthesize a fresh [ownProfile] the first time
  /// [updateOwnProfile] or [setOwnAvatar] is called with no pre-seeded
  /// [ownProfile].
  final String ownPubkeyHex;

  /// Records every method invocation as `(method, args)`, in call order.
  ///
  /// `args` uses each parameter's name as the map key (e.g. `pubkeyHex`,
  /// `forceRefresh`) so tests can assert both which method fired and what
  /// it was called with in one place, instead of a separate
  /// `*CalledWith` field per method.
  final List<({String method, Map<String, Object?> args})> methodCalls = [];

  /// Set to make [getOwnProfile] throw.
  bool shouldThrowOnGetOwnProfile = false;

  /// Set to make [updateOwnProfile] throw.
  bool shouldThrowOnUpdateOwnProfile = false;

  /// Set to make [setOwnAvatar] throw.
  bool shouldThrowOnSetOwnAvatar = false;

  /// Set to make [removeOwnAvatar] throw.
  bool shouldThrowOnRemoveOwnAvatar = false;

  /// Set to make [getMemberProfile] throw.
  bool shouldThrowOnGetMemberProfile = false;

  /// Set to make [getCachedMemberProfiles] throw.
  ///
  /// The real implementation never throws — an unreadable row costs that
  /// person their name and a store that will not open yields an empty map —
  /// so this models a NON-CONFORMING implementation, and exists to prove the
  /// callers above it stay usable even then.
  bool shouldThrowOnGetCachedMemberProfiles = false;

  /// Set to make [refreshMemberProfiles] throw.
  bool shouldThrowOnRefreshMemberProfiles = false;

  /// When set, [refreshMemberProfiles] blocks on this until it completes,
  /// holding the call in flight deterministically.
  ///
  /// Preferred over a wall-clock delay for coalescing tests: it makes the
  /// in-flight window explicit rather than racing the scheduler, so the test
  /// cannot flake under parallel load.
  Completer<void>? refreshGate;

  /// Profiles returned by [resolveTypedStrangerProfile], keyed by the EXACT
  /// npub argument — not by hex, since the whole point of that method is
  /// accepting a key nothing local has decoded to hex yet. Settable directly
  /// by tests.
  final Map<String, Profile> strangerProfiles = {};

  /// Set to make [resolveTypedStrangerProfile] throw.
  bool shouldThrowOnResolveTypedStrangerProfile = false;

  /// When set, [resolveTypedStrangerProfile] blocks on this until it
  /// completes — same shape as [refreshGate], so a widget test can hold the
  /// picker's stranger-row resolve in flight deterministically (no sleeps,
  /// no timing races).
  Completer<void>? resolveTypedStrangerProfileGate;

  /// When set, [updateOwnProfile] blocks on this until it completes.
  Completer<void>? updateOwnProfileGate;

  /// When set, [setOwnAvatar] blocks on this until it completes.
  Completer<void>? setOwnAvatarGate;

  /// When set, [removeOwnAvatar] blocks on this until it completes.
  Completer<void>? removeOwnAvatarGate;

  /// When set, [syncOwnProfile] blocks on this until it completes.
  Completer<void>? syncOwnProfileGate;

  /// Set to make [syncOwnProfile] throw.
  bool shouldThrowOnSyncOwnProfile = false;

  /// Set to make [pendingSyncState] throw (in production this can never
  /// actually happen — `NostrProfileService.pendingSyncState` fails closed
  /// internally — but the mock still models a non-conforming call site).
  bool shouldThrowOnPendingSyncState = false;

  /// The result [syncOwnProfile] returns. Defaults to
  /// [ProfileSyncOutcome.nothingPending] (nothing queued, no network
  /// touched) so a test that never configures this does not need to.
  ///
  /// Ignored while [syncResultQueue] is non-empty.
  ProfileSyncResult nextSyncResult = const ProfileSyncResult(
    outcome: ProfileSyncOutcome.nothingPending,
    relaysAcked: 0,
    relaysAttempted: 0,
    stillPending: false,
  );

  /// When non-empty, each [syncOwnProfile] call consumes (removes) the
  /// FIRST entry instead of returning [nextSyncResult] — lets a test give
  /// consecutive calls (e.g. an initial pass and the follow-up it queues)
  /// different, deterministic answers without racing a field mutation
  /// against exactly when each call reads it.
  final List<ProfileSyncResult> syncResultQueue = [];

  /// The state [pendingSyncState] returns. Defaults to "clean" (nothing
  /// pending) — see the class doc for why that default matters.
  ProfilePendingState nextPendingState = const ProfilePendingState(
    pending: false,
    partial: false,
    retryDue: false,
  );

  /// Every `shouldThrowOn*` flag throws this exact exception, matching
  /// the real implementation's convention of never leaking a raw `$e` /
  /// internal detail to callers.
  static const _genericError = ProfileServiceException('generic');

  @override
  Future<Profile?> getOwnProfile({bool forceRefresh = false}) async {
    methodCalls.add((
      method: 'getOwnProfile',
      args: {'forceRefresh': forceRefresh},
    ));
    if (shouldThrowOnGetOwnProfile) throw _genericError;
    return ownProfile;
  }

  @override
  Future<Profile> updateOwnProfile({
    required String displayName,
    String? about,
  }) async {
    methodCalls.add((
      method: 'updateOwnProfile',
      args: {'displayName': displayName, 'about': about},
    ));
    final gate = updateOwnProfileGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnUpdateOwnProfile) throw _genericError;
    final updated = (ownProfile ?? Profile(pubkeyHex: ownPubkeyHex)).copyWith(
      displayName: displayName,
      about: about,
    );
    ownProfile = updated;
    return updated;
  }

  @override
  Future<Profile> setOwnAvatar(Uint8List raw) async {
    methodCalls.add((method: 'setOwnAvatar', args: {'raw': raw}));
    final gate = setOwnAvatarGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnSetOwnAvatar) throw _genericError;
    final updated = (ownProfile ?? Profile(pubkeyHex: ownPubkeyHex)).copyWith(
      pictureBytes: raw,
      pictureHash: 'mock-picture-hash',
    );
    ownProfile = updated;
    return updated;
  }

  @override
  Future<Profile> removeOwnAvatar() async {
    methodCalls.add((method: 'removeOwnAvatar', args: const {}));
    final gate = removeOwnAvatarGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnRemoveOwnAvatar) throw _genericError;
    final current = ownProfile ?? Profile(pubkeyHex: ownPubkeyHex);
    final cleared = Profile(
      pubkeyHex: current.pubkeyHex,
      name: current.name,
      displayName: current.displayName,
      about: current.about,
      knownAt: current.knownAt,
    );
    ownProfile = cleared;
    return cleared;
  }

  @override
  Future<ProfileSyncResult> syncOwnProfile() async {
    methodCalls.add((method: 'syncOwnProfile', args: const {}));
    final gate = syncOwnProfileGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnSyncOwnProfile) throw _genericError;
    return syncResultQueue.isNotEmpty
        ? syncResultQueue.removeAt(0)
        : nextSyncResult;
  }

  @override
  Future<ProfilePendingState> pendingSyncState() async {
    methodCalls.add((method: 'pendingSyncState', args: const {}));
    if (shouldThrowOnPendingSyncState) throw _genericError;
    return nextPendingState;
  }

  @override
  Future<Profile?> getMemberProfile(
    String pubkeyHex, {
    bool forceRefresh = false,
  }) async {
    methodCalls.add((
      method: 'getMemberProfile',
      args: {'pubkeyHex': pubkeyHex, 'forceRefresh': forceRefresh},
    ));
    if (shouldThrowOnGetMemberProfile) throw _genericError;
    return memberProfiles[pubkeyHex];
  }

  @override
  Future<Map<String, Profile>> getCachedMemberProfiles(
    List<String> pubkeyHexes,
  ) async {
    methodCalls.add((
      method: 'getCachedMemberProfiles',
      args: {'pubkeyHexes': List<String>.of(pubkeyHexes)},
    ));
    if (shouldThrowOnGetCachedMemberProfiles) throw _genericError;
    return {
      for (final pubkeyHex in pubkeyHexes)
        if (memberProfiles.containsKey(pubkeyHex))
          // Bytes stripped, as the real read strips them: a double that
          // handed back picture bytes would let a caller depend on bytes
          // production never supplies.
          pubkeyHex: _withoutPictureBytes(memberProfiles[pubkeyHex]!),
    };
  }

  static Profile _withoutPictureBytes(Profile profile) {
    return Profile(
      pubkeyHex: profile.pubkeyHex,
      name: profile.name,
      displayName: profile.displayName,
      about: profile.about,
      pictureHash: profile.pictureHash,
      knownAt: profile.knownAt,
    );
  }

  @override
  Future<Map<String, Profile>> refreshMemberProfiles(
    List<String> pubkeyHexes, {
    Duration maxAge = profileInteractiveMaxAge,
  }) async {
    methodCalls.add((
      method: 'refreshMemberProfiles',
      args: {'pubkeyHexes': List<String>.of(pubkeyHexes), 'maxAge': maxAge},
    ));
    final gate = refreshGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnRefreshMemberProfiles) throw _genericError;
    return {
      for (final pubkeyHex in pubkeyHexes)
        if (memberProfiles.containsKey(pubkeyHex))
          pubkeyHex: memberProfiles[pubkeyHex]!,
    };
  }

  @override
  Future<Profile?> resolveTypedStrangerProfile(String npub) async {
    methodCalls.add((
      method: 'resolveTypedStrangerProfile',
      args: {'npub': npub},
    ));
    final gate = resolveTypedStrangerProfileGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnResolveTypedStrangerProfile) throw _genericError;
    return strangerProfiles[npub];
  }
}
