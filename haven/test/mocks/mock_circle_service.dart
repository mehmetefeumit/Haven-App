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
  List<DecryptedLocation?> decryptLocationResults = [];
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
    String circleName = 'New Circle',
  }) async {
    methodCalls.add('processGiftWrappedInvitation');
    return Invitation(
      mlsGroupId: const [1, 2, 3, 4],
      circleName: circleName,
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
  Future<void> leaveCircle(List<int> mlsGroupId) async {
    methodCalls.add('leaveCircle');
    if (shouldThrowOnLeaveCircle) {
      throw CircleServiceException(errorMessage);
    }
  }

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async {
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

  @override
  Future<DecryptedLocation?> decryptLocation({
    required String eventJson,
  }) async {
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
