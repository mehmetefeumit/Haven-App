// ignore_for_file: public_member_api_docs -- docs live on CircleService proper; stubs add no public API value
// Stand-alone mixin for test mocks — docs live on CircleService proper.

/// Stub implementations of the last-known-location surface on
/// `CircleService` for use by inline mock classes in tests.
///
/// Apply via `class Foo extends Object with CircleServiceRetentionStubs
/// implements CircleService {}` on any fake that does not care about
/// the cache surface. Override individual members as needed.
library;

import 'package:haven/src/services/circle_service.dart';

/// No-op stubs for last-known-location methods.
mixin CircleServiceRetentionStubs {
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required DateTime timestamp,
    required DateTime expiresAt,
    required DateTime purgeAfter,
    required DateTime updatedAt,
    String? displayName,
  }) async {}

  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async => const [];

  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  }) async {}

  Future<void> removeLastKnownCircle({required List<int> nostrGroupId}) async {}

  Future<void> wipeAllLastKnownLocations() async {}

  Future<void> wipeAllStagedCommits() async {}

  Future<void> closeAndInvalidate() async {}

  Future<void> wipeAllMlsState() async {}

  Future<void> pruneProcessedGiftWraps({DateTime? now}) async {}

  Future<void> recordPublishedKeyPackages({
    required List<int> canonicalHashRef,
    required String dTag,
    required String canonicalEventId,
    required String legacyEventId,
  }) async {}

  Future<void> resetAllSyncCursors() async {}

  Future<int> pruneExpiredLastKnown({DateTime? now}) async => 0;

  Future<void> setContactDisplayName({
    required String pubkey,
    String? displayName,
  }) async {}

  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async => true;

  Future<void> advanceGroupCursorToEventSecs(int eventCreatedAtSecs) async {}

  Future<void> advanceInboxCursorToWrapSecs(int wrapCreatedAtSecs) async {}

  Future<void> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  }) async {}

  // Leaver-backstop liveness predicate — stubbed "still a member"; fakes that
  // use this mixin never run a backstop, so the value is inert.
  Future<bool> stillAMember({
    required List<int> mlsGroupId,
    required String ownPubkeyHex,
  }) async => true;

  Future<AddMemberResult> addMember({
    required Future<List<int>> Function() secretProvider,
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
    List<String> creatorFallbackRelays = const [],
  }) async => const AddMemberResult(welcomesSent: 1, welcomesTotal: 1);
}
