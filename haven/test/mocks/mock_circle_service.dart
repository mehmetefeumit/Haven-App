/// Mock implementation of [CircleService] for testing.
///
/// Provides controllable behavior for unit tests without requiring
/// Rust FFI or system keyring access.
library;

import 'package:haven/src/services/circle_service.dart';

/// A mock [CircleService] for testing.
///
/// Allows tests to control:
/// - What circles are returned
/// - Whether operations succeed or fail
/// - Simulation of various error conditions
class MockCircleService implements CircleService {
  /// Creates a mock circle service.
  ///
  /// By default, returns empty lists and succeeds on all operations.
  MockCircleService({
    List<Circle>? circles,
    this.shouldThrowOnGetCircles = false,
    this.shouldThrowOnLeaveCircle = false,
    this.errorMessage = 'Mock error',
  }) : _circles = circles ?? [];

  final List<Circle> _circles;

  /// Whether [getVisibleCircles] should throw an exception.
  final bool shouldThrowOnGetCircles;

  /// Whether [leaveCircle] should throw an exception.
  final bool shouldThrowOnLeaveCircle;

  /// The error message to use when throwing exceptions.
  final String errorMessage;

  /// Tracks method calls for verification in tests.
  final List<String> methodCalls = [];

  /// Encrypted location results to return.
  List<EncryptedLocation> encryptLocationResults = [];
  int _encryptIndex = 0;

  /// Decrypted location results to return (null = non-location message).
  List<DecryptResult?> decryptLocationResults = [];
  int _decryptIndex = 0;

  /// Resets the sequential-result indices for [decryptLocationResults],
  /// [encryptLocationResults], [publishEvolutionEventResults], and
  /// [getMembersResults].
  ///
  /// Call this before Phase 2 of a two-phase test that reuses the same
  /// [MockCircleService] instance with a new result list, so the new list
  /// is consumed from index 0 rather than wherever Phase 1 left the cursor.
  void resetResultIndices() {
    _decryptIndex = 0;
    _encryptIndex = 0;
    _publishEvolutionEventIndex = 0;
    _getMembersIndex = 0;
  }

  /// Event JSONs passed to [decryptLocation], in call order.
  ///
  /// Exposed so tests can assert the order in which events were
  /// decrypted — notably that the service sorts events ascending by
  /// `created_at` before the decrypt loop. Distinct from [methodCalls]
  /// which only records that the method fired.
  final List<String> decryptCallEventJsons = [];

  @override
  Future<List<Circle>> getVisibleCircles() async {
    methodCalls.add('getVisibleCircles');
    if (shouldThrowOnGetCircles) {
      throw CircleServiceException(errorMessage);
    }
    return _circles;
  }

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async {
    methodCalls.add('getCircle');
    try {
      return _circles.firstWhere((c) => _listEquals(c.mlsGroupId, mlsGroupId));
    } on StateError {
      return null;
    }
  }

  /// Optional override for [getMembers].
  ///
  /// When non-null, successive [getMembers] calls consume entries from this
  /// list in order (each call pops the first entry). This lets tests simulate
  /// the post-commit member roster returned after [finalizePendingCommit].
  /// When the list is exhausted, falls back to the default (looks up the
  /// circle's member list).
  List<List<CircleMember>>? getMembersResults;
  int _getMembersIndex = 0;

  /// Number of leading [getMembers] calls that should throw before
  /// falling back to the regular result pipeline. Used to simulate a
  /// transient FFI failure on the first call and success on retries.
  int getMembersThrowCount = 0;

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async {
    methodCalls.add('getMembers');
    if (getMembersThrowCount > 0) {
      getMembersThrowCount--;
      throw const CircleServiceException(
        'simulated transient getMembers failure',
      );
    }
    final results = getMembersResults;
    if (results != null && _getMembersIndex < results.length) {
      return results[_getMembersIndex++];
    }
    final circle = await getCircle(mlsGroupId);
    return circle?.members ?? [];
  }

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
    List<String> creatorFallbackRelays = const [],
  }) async {
    methodCalls.add('createCircle');
    throw UnimplementedError('createCircle not implemented in mock');
  }

  @override
  Future<List<Invitation>> getPendingInvitations() async {
    methodCalls.add('getPendingInvitations');
    return [];
  }

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    methodCalls.add('acceptInvitation');
    throw UnimplementedError('acceptInvitation not implemented in mock');
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {
    methodCalls.add('declineInvitation');
  }

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    methodCalls.add('processGiftWrappedInvitation');
    return Invitation(
      mlsGroupId: const [1, 2, 3, 4],
      circleName: 'Mock Circle',
      inviterPubkey: 'mock_inviter_pubkey',
      memberCount: 2,
      invitedAt: DateTime.now(),
    );
  }

  /// MLS group IDs passed to [finalizePendingCommit], in call order.
  final List<List<int>> finalizePendingCommitCalledWith = [];

  /// MLS group IDs passed to [clearPendingCommit], in call order.
  final List<List<int>> clearPendingCommitCalledWith = [];

  /// Whether [finalizePendingCommit] should throw an exception.
  bool shouldThrowOnFinalizePendingCommit = false;

  /// Whether [clearPendingCommit] should throw an exception.
  bool shouldThrowOnClearPendingCommit = false;

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {
    methodCalls.add('finalizePendingCommit');
    finalizePendingCommitCalledWith.add(List<int>.of(mlsGroupId));
    if (shouldThrowOnFinalizePendingCommit) {
      throw const CircleServiceException('Mock finalizePendingCommit error');
    }
  }

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {
    methodCalls.add('clearPendingCommit');
    clearPendingCommitCalledWith.add(List<int>.of(mlsGroupId));
    if (shouldThrowOnClearPendingCommit) {
      throw const CircleServiceException('Mock clearPendingCommit error');
    }
  }

  /// Arguments captured from each [publishEvolutionEvent] call, in order.
  ///
  /// Each entry is a 3-tuple-like map with keys `eventJson`, `relays`,
  /// and `label`. Tests use this to verify the service delegated the
  /// correct payload to the mock.
  final List<Map<String, Object?>> publishEvolutionEventCalls = [];

  /// Return values queued for successive [publishEvolutionEvent] calls.
  ///
  /// When empty, [publishEvolutionEvent] returns `true` by default.
  /// Lets tests simulate a rejected publish without constructing a
  /// failure relay mock.
  List<bool> publishEvolutionEventResults = [];
  int _publishEvolutionEventIndex = 0;

  /// Whether [publishEvolutionEvent] should throw an exception.
  bool shouldThrowOnPublishEvolutionEvent = false;

  @override
  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async {
    methodCalls.add('publishEvolutionEvent');
    publishEvolutionEventCalls.add({
      'eventJson': eventJson,
      'relays': List<String>.of(relays),
      'label': label,
    });
    if (shouldThrowOnPublishEvolutionEvent) {
      throw const CircleServiceException('Mock publishEvolutionEvent error');
    }
    if (_publishEvolutionEventIndex < publishEvolutionEventResults.length) {
      return publishEvolutionEventResults[_publishEvolutionEventIndex++];
    }
    return true;
  }

  /// Groups returned by [groupsNeedingSelfUpdate].
  List<List<int>> groupsNeedingUpdate = [];

  /// Whether [groupsNeedingSelfUpdate] should throw.
  bool shouldThrowOnGroupsNeedingSelfUpdate = false;

  /// The threshold argument captured from the last [groupsNeedingSelfUpdate] call.
  int? capturedThresholdSecs;

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async {
    methodCalls.add('groupsNeedingSelfUpdate');
    capturedThresholdSecs = thresholdSecs;
    if (shouldThrowOnGroupsNeedingSelfUpdate) {
      throw const CircleServiceException(
        'Mock groups needing self-update error',
      );
    }
    return groupsNeedingUpdate;
  }

  /// Whether [selfUpdate] should throw an exception.
  bool shouldThrowOnSelfUpdate = false;

  /// Group IDs passed to [selfUpdate], in call order.
  List<List<int>> selfUpdateCalledWith = [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {
    methodCalls.add('selfUpdate');
    selfUpdateCalledWith.add(mlsGroupId);
    if (shouldThrowOnSelfUpdate) {
      throw const CircleServiceException('Mock self-update error');
    }
  }

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {
    methodCalls.add('leaveCircle');
    if (shouldThrowOnLeaveCircle) {
      throw CircleServiceException(errorMessage);
    }
  }

  /// Pubkeys passed to [removeMember], in call order, paired with the group id.
  final List<({List<int> mlsGroupId, String memberPubkeyHex})>
  removeMemberCalls = [];

  /// Whether [removeMember] should throw an exception.
  bool shouldThrowOnRemoveMember = false;

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {
    methodCalls.add('removeMember');
    removeMemberCalls.add((
      mlsGroupId: List<int>.of(mlsGroupId),
      memberPubkeyHex: memberPubkeyHex,
    ));
    if (shouldThrowOnRemoveMember) {
      throw const CircleServiceException('Mock removeMember error');
    }
  }

  /// The update-interval hint captured from the last [encryptLocation] call.
  int? capturedUpdateIntervalSecs;

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  }) async {
    capturedUpdateIntervalSecs = updateIntervalSecs;
    methodCalls.add('encryptLocation');
    if (_encryptIndex < encryptLocationResults.length) {
      return encryptLocationResults[_encryptIndex++];
    }
    return EncryptedLocation(
      eventJson: '{"id":"mock-event-${_encryptIndex++}","kind":445}',
      nostrGroupId: List.generate(32, (i) => i),
      relays: const ['wss://relay.example.com'],
    );
  }

  /// Last-known location rows stored in the mock.
  final List<Map<String, Object?>> lastKnownRows = [];

  @override
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
  }) async {
    methodCalls.add('upsertLastKnownLocation');
    lastKnownRows.add({
      'nostrGroupId': nostrGroupId,
      'senderPubkey': senderPubkey,
      'latitude': latitude,
      'longitude': longitude,
      'geohash': geohash,
      'timestamp': timestamp,
      'expiresAt': expiresAt,
      'purgeAfter': purgeAfter,
      'updatedAt': updatedAt,
      'displayName': displayName,
    });
  }

  /// Optional override: when non-null, [snapshotLastKnownForCircle]
  /// returns these rows filtered by `nostrGroupId` instead of the
  /// default empty list. Lets tests simulate rehydration from the
  /// persistent store after e.g. an `onAppPaused` cycle.
  List<DecryptedLocation>? snapshotLastKnownRows;

  @override
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async {
    methodCalls.add('snapshotLastKnownForCircle');
    final override = snapshotLastKnownRows;
    if (override != null) return List<DecryptedLocation>.of(override);
    return const [];
  }

  @override
  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  }) async {
    methodCalls.add('removeLastKnownMember');
    lastKnownRows.removeWhere(
      (row) =>
          _listEquals(row['nostrGroupId']! as List<int>, nostrGroupId) &&
          row['senderPubkey'] == senderPubkey,
    );
  }

  @override
  Future<void> removeLastKnownCircle({required List<int> nostrGroupId}) async {
    methodCalls.add('removeLastKnownCircle');
    lastKnownRows.removeWhere(
      (row) => _listEquals(row['nostrGroupId']! as List<int>, nostrGroupId),
    );
  }

  @override
  Future<void> wipeAllLastKnownLocations() async {
    methodCalls.add('wipeAllLastKnownLocations');
    lastKnownRows.clear();
  }

  @override
  Future<int> pruneExpiredLastKnown({DateTime? now}) async {
    methodCalls.add('pruneExpiredLastKnown');
    return 0;
  }

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async {
    methodCalls.add('decryptLocation');
    decryptCallEventJsons.add(eventJson);
    if (_decryptIndex < decryptLocationResults.length) {
      return decryptLocationResults[_decryptIndex++];
    }
    return null;
  }

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async {
    methodCalls.add('signKeyPackageEvent');
    return SignedKeyPackageEvent(
      eventJson: '{"id":"mock-kp-30443","kind":30443}',
      legacyEventJson: '{"id":"mock-kp-443","kind":443}',
      relays: relays,
    );
  }

  /// Whether [signDeletionEvent] should throw an exception.
  bool shouldThrowOnDeletion = false;

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async {
    methodCalls.add('signDeletionEvent');
    if (shouldThrowOnDeletion) {
      throw const CircleServiceException('Mock deletion error');
    }
    return '{"id":"mock-deletion","kind":5}';
  }

  /// Contact display names saved via [setContactDisplayNameIfAbsent].
  final Map<String, String> savedContactNames = {};

  @override
  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
  }) async {
    methodCalls.add('setContactDisplayNameIfAbsent');
    savedContactNames.putIfAbsent(pubkey, () => displayName);
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Creates test circle data for use in tests.
class TestCircleFactory {
  /// Creates a test circle with default values.
  static Circle createCircle({
    List<int>? mlsGroupId,
    List<int>? nostrGroupId,
    String displayName = 'Test Circle',
    List<CircleMember>? members,
    MembershipStatus membershipStatus = MembershipStatus.accepted,
  }) {
    return Circle(
      mlsGroupId: mlsGroupId ?? [1, 2, 3, 4],
      nostrGroupId: nostrGroupId ?? [5, 6, 7, 8],
      displayName: displayName,
      circleType: CircleType.locationSharing,
      relays: const ['wss://relay.example.com'],
      membershipStatus: membershipStatus,
      members: members ?? const [],
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );
  }

  /// Creates a test circle member with default values.
  static CircleMember createMember({
    String? pubkey,
    String? displayName,
    bool isAdmin = false,
    MembershipStatus status = MembershipStatus.accepted,
  }) {
    return CircleMember(
      pubkey:
          pubkey ??
          'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
      displayName: displayName,
      isAdmin: isAdmin,
      status: status,
    );
  }
}
