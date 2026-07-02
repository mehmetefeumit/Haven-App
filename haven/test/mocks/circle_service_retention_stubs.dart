// ignore_for_file: public_member_api_docs -- docs live on CircleService proper; stubs add no public API value
// Stand-alone mixin for test mocks — docs live on CircleService proper.

/// Stub implementations of the last-known-location surface on
/// `CircleService` for use by inline mock classes in tests.
///
/// Apply via `class Foo extends Object with CircleServiceRetentionStubs
/// implements CircleService {}` on any fake that does not care about
/// the cache surface. Override individual members as needed.
library;

import 'dart:typed_data';

import 'package:haven/src/rust/api.dart' show AvatarMetaFfi;
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

  Future<void> resetAllSyncCursors() async {}

  Future<int> pruneExpiredLastKnown({DateTime? now}) async => 0;

  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
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

  Future<AddMemberResult> addMember({
    required List<int> identitySecretBytes,
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
    List<String> creatorFallbackRelays = const [],
  }) async => const AddMemberResult(welcomesSent: 1, welcomesTotal: 1);

  Future<AvatarMetaFfi> setMyAvatar(String ownPubkey, Uint8List raw) async =>
      const AvatarMetaFfi(
        contentHashHex:
            'aabbcc0000000000000000000000000000000000000000000000000000000000',
        mime: 'image/jpeg',
        width: 512,
        height: 512,
        version: 1,
      );

  Future<void> clearMyAvatar(String ownPubkey) async {}

  Future<Uint8List?> getMyAvatarThumbnail(String ownPubkey) async => null;

  Future<Uint8List?> getMyAvatar(String ownPubkey) async => null;

  // ==================== M2 Avatar Network stubs ====================

  Future<List<String>> buildAvatarShareEvents({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required int updateIntervalSecs,
  }) async => const [];

  Future<String> buildAvatarClearEvent({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required int updateIntervalSecs,
  }) async => '{"id":"stub-clear","kind":445,"content":""}';

  Future<AvatarIngestResult> ingestIncomingAvatarMessage({
    required String eventJson,
  }) async => const AvatarIngestResult(accepted: false, complete: false);

  Future<Uint8List?> getMemberAvatarThumbnail({
    required List<int> mlsGroupId,
    required String pubkey,
  }) async => null;

  Future<Uint8List?> getMemberAvatar({
    required List<int> mlsGroupId,
    required String pubkey,
  }) async => null;
}
