/// Mock implementation of [ProfileService] for testing.
///
/// Provides controllable behavior for unit tests without requiring
/// Rust FFI, a relay connection, or a Blossom server. This is what every
/// future profile provider/widget test overrides via
/// `ProviderScope(overrides: [...])`.
library;

import 'dart:typed_data';

import 'package:haven/src/services/profile_service.dart';

/// A mock [ProfileService] for testing.
///
/// Allows tests to control:
/// - What the user's own profile and each member's profile look like
/// - Whether individual operations succeed or fail
///
/// Publishing is unconditional (no consent gate) — [updateOwnProfile] and
/// [setOwnAvatar] always run.
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

  /// Set to make [refreshMemberProfiles] throw.
  bool shouldThrowOnRefreshMemberProfiles = false;

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
  Future<Map<String, Profile>> refreshMemberProfiles(
    List<String> pubkeyHexes, {
    bool force = false,
  }) async {
    methodCalls.add((
      method: 'refreshMemberProfiles',
      args: {'pubkeyHexes': List<String>.of(pubkeyHexes), 'force': force},
    ));
    if (shouldThrowOnRefreshMemberProfiles) throw _genericError;
    return {
      for (final pubkeyHex in pubkeyHexes)
        if (memberProfiles.containsKey(pubkeyHex))
          pubkeyHex: memberProfiles[pubkeyHex]!,
    };
  }
}
