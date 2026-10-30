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
  Future<List<RejoinOffer>> rejoinOffersForInvitation(
    List<int> invitationId,
  ) async => const [];

  Future<Circle> confirmGroupRejoin(
    List<int> invitationId,
    RejoinOffer offer,
  ) => throw UnimplementedError('confirmGroupRejoin');

  Future<void> declineGroupRejoin(List<int> invitationId) async {}

  Future<void> leaveDisbandedCircle({required List<int> mlsGroupId}) async {}

  /// The epoch repair is a foreground user action no retention-surface fake
  /// exercises; a fake that DOES care overrides this.
  Future<EpochRepairResult> repairCircleEpoch(
    Circle circle, {
    required String selfPubkeyHex,
  }) async => const EpochRepairApplied();

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

  Future<void> closeAndInvalidate() async {}

  Future<void> wipeAllMlsState() async {}

  Future<void> acknowledgeStorageReset() async {}

  Future<bool> retryQuarantinedCircle(List<int> mlsGroupId) async => false;

  Future<KeyPackageAdmission> checkMemberKeyPackage({
    required String keyPackageJson,
    List<int>? mlsGroupId,
  }) async => KeyPackageAdmission.admissible;

  Future<void> pruneProcessedGiftWraps({DateTime? now}) async {}

  Future<void> resetAllSyncCursors() async {}

  Future<int> pruneExpiredLastKnown({DateTime? now}) async => 0;

  Future<List<DirectoryEntry>> rankedDirectoryMembers({DateTime? now}) async =>
      const [];

  Future<bool> reconcileMemberDirectory({DateTime? now}) async => true;

  Future<Map<String, String>> allContactDisplayNames() async => const {};

  Future<String?> getContactDisplayName({required String pubkey}) async => null;

  Future<void> setContactDisplayName({
    required String pubkey,
    String? displayName,
  }) async {}

  /// Nothing holds a circle for a fake that does not exercise the recovery
  /// read.
  Future<CircleRecoveryCause?> circleRecovery(Circle circle) async => null;

  Future<List<String>> unmadeRemovalMembers(List<int> mlsGroupId) async =>
      const [];

  Future<ChangeDelivery> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  }) async => ChangeDelivery.applied;

  Future<AddMemberResult> addMember({
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
  }) async => const AddMemberResult(
    delivery: ChangeDelivery.applied,
    welcomesDelivered: 1,
    welcomesTotal: 1,
  );

  // The driver's ingest — an inert default for fakes that receive nothing.
  Future<IngestResult> ingestEvent({required String eventJson}) async =>
      const IngestResult(results: [], held: false);
}
