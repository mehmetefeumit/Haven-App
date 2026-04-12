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
    this.shouldThrowOnRelayList = false,
    this.errorMessage = 'Mock error',
  }) : _circles = circles ?? [];

  final List<Circle> _circles;

  /// Whether [getVisibleCircles] should throw an exception.
  final bool shouldThrowOnGetCircles;

  /// Whether [leaveCircle] should throw an exception.
  final bool shouldThrowOnLeaveCircle;

  /// Whether [signRelayListEvent] should throw an exception.
  final bool shouldThrowOnRelayList;

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

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async {
    methodCalls.add('getMembers');
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
  Future<Invitation> processGiftWrappedInvitation({
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

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {
    methodCalls.add('finalizePendingCommit');
  }

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {
    methodCalls.add('clearPendingCommit');
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
  Future<void> leaveCircle(List<int> mlsGroupId) async {
    methodCalls.add('leaveCircle');
    if (shouldThrowOnLeaveCircle) {
      throw CircleServiceException(errorMessage);
    }
  }

  /// The precision label captured from the last [encryptLocation] call.
  String? capturedPrecisionLabel;

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int retentionSecs,
    String? displayName,
    String? precisionLabel,
  }) async {
    capturedPrecisionLabel = precisionLabel;
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
    required String precision,
    required DateTime timestamp,
    required DateTime expiresAt,
    required int retentionSecs,
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
      'precision': precision,
      'timestamp': timestamp,
      'expiresAt': expiresAt,
      'retentionSecs': retentionSecs,
      'purgeAfter': purgeAfter,
      'updatedAt': updatedAt,
      'displayName': displayName,
    });
  }

  @override
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async {
    methodCalls.add('snapshotLastKnownForCircle');
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
  Future<int> removeLastKnownForSender({required String senderPubkey}) async {
    methodCalls.add('removeLastKnownForSender');
    final before = lastKnownRows.length;
    lastKnownRows.removeWhere((row) => row['senderPubkey'] == senderPubkey);
    return before - lastKnownRows.length;
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
  int get locationReceiverMaxRetentionSecs => 30 * 24 * 60 * 60;

  @override
  int get defaultSenderRetentionSecs => 24 * 60 * 60;

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async {
    methodCalls.add('decryptLocation');
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
      eventJson: '{"id":"mock-kp","kind":443}',
      relays: relays,
    );
  }

  @override
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async {
    methodCalls.add('signRelayListEvent');
    if (shouldThrowOnRelayList) {
      throw const CircleServiceException('Mock relay list error');
    }
    return '{"id":"mock-relay-list","kind":10051}';
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
    String displayName = 'Test Circle',
    List<CircleMember>? members,
    MembershipStatus membershipStatus = MembershipStatus.accepted,
  }) {
    return Circle(
      mlsGroupId: mlsGroupId ?? [1, 2, 3, 4],
      nostrGroupId: [5, 6, 7, 8],
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
