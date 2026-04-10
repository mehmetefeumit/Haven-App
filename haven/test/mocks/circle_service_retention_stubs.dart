// ignore_for_file: public_member_api_docs
// Stand-alone mixin for test mocks — docs live on CircleService proper.

/// Stub implementations of the sender-retention + last-known-location
/// surface on `CircleService` for use by inline mock classes in tests.
///
/// Apply via `class Foo extends Object with CircleServiceRetentionStubs
/// implements CircleService {}` on any fake that does not care about
/// the retention surface. Override individual members as needed.
library;

import 'package:haven/src/services/circle_service.dart';

/// No-op stubs for retention + last-known-location methods.
mixin CircleServiceRetentionStubs {
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required String precision,
    required DateTime timestamp,
    required DateTime expiresAt,
    required int retentionSecs,
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

  Future<int> removeLastKnownForSender({required String senderPubkey}) async =>
      0;

  Future<void> wipeAllLastKnownLocations() async {}

  Future<int> pruneExpiredLastKnown({DateTime? now}) async => 0;

  int get locationReceiverMaxRetentionSecs => 30 * 24 * 60 * 60;

  int get defaultSenderRetentionSecs => 24 * 60 * 60;

  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
  }) async {}
}
