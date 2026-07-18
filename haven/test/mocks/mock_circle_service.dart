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
  ///
  /// Settable so a test can flip it after construction (e.g. to simulate a
  /// resume whose re-run leave still fails).
  bool shouldThrowOnLeaveCircle;

  /// The error message to use when throwing exceptions.
  final String errorMessage;

  /// Tracks method calls for verification in tests.
  final List<String> methodCalls = [];

  /// Encrypted location results to return.
  List<EncryptedLocation> encryptLocationResults = [];
  int _encryptIndex = 0;

  /// Decrypted location results to return (empty = no results this call).
  List<List<LocationEventResult>> decryptLocationResults = [];
  int _decryptIndex = 0;

  /// Resets the sequential-result indices for [decryptLocationResults],
  /// [encryptLocationResults], and [getMembersResults].
  ///
  /// Call this before Phase 2 of a two-phase test that reuses the same
  /// [MockCircleService] instance with a new result list, so the new list
  /// is consumed from index 0 rather than wherever Phase 1 left the cursor.
  void resetResultIndices() {
    _decryptIndex = 0;
    _encryptIndex = 0;
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
    return _circles
        .where((c) => _listEquals(c.mlsGroupId, mlsGroupId))
        .firstOrNull;
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

  /// A REFERENCE (not a copy) to the last `identitySecretBytes` passed to
  /// [processGiftWrappedInvitation], so a test can assert the caller zeroized
  /// the buffer after use (Security Rule 9).
  List<int>? processGiftWrappedInvitationSecretRef;

  /// When true, [processGiftWrappedInvitation] throws (to prove the caller's
  /// zeroize still runs on the error path).
  bool shouldThrowOnProcessGiftWrappedInvitation = false;

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    methodCalls.add('processGiftWrappedInvitation');
    processGiftWrappedInvitationSecretRef = identitySecretBytes;
    if (shouldThrowOnProcessGiftWrappedInvitation) {
      throw Exception('mock process failure');
    }
    return Invitation(
      mlsGroupId: const [1, 2, 3, 4],
      circleName: 'Mock Circle',
      inviterPubkey: 'mock_inviter_pubkey',
      memberCount: 2,
      invitedAt: DateTime.now(),
    );
  }

  // NOTE: `finalizePendingCommit` / `clearPendingCommit` /
  // `publishEvolutionEvent` were removed from `CircleService` — the Dark
  // Matter engine owns publish-before-apply for every commit internally
  // (see `NostrCircleService`'s `_publishAndConfirm`), so there is nothing
  // left for the receiver-side decrypt path to publish or finalize.

  /// Hex-encoded `mlsGroupId`s marked via [markCircleBlocked], for test
  /// assertions.
  final Set<String> blockedCircleIdsForTest = {};

  static String _hexGroupId(List<int> mlsGroupId) {
    return mlsGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void markCircleBlocked(List<int> mlsGroupId) {
    methodCalls.add('markCircleBlocked');
    blockedCircleIdsForTest.add(_hexGroupId(mlsGroupId));
  }

  @override
  bool isCircleBlocked(List<int> mlsGroupId) {
    methodCalls.add('isCircleBlocked');
    return blockedCircleIdsForTest.contains(_hexGroupId(mlsGroupId));
  }

  // NOTE: `groupsNeedingSelfUpdate` / `selfUpdate` were removed from
  // `CircleService` — MIP-02/03 leaf-key rotation is now engine-internal
  // under Dark Matter (see `self_update_provider.dart`).

  /// Args captured from each [leaveCircle] call, in order.
  final List<({List<int> mlsGroupId, String selfPubkeyHex})>
  leaveCircleCalledWith = [];

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {
    methodCalls.add('leaveCircle');
    leaveCircleCalledWith.add((
      mlsGroupId: List<int>.of(mlsGroupId),
      selfPubkeyHex: selfPubkeyHex,
    ));
    if (shouldThrowOnLeaveCircle) {
      throw CircleServiceException(errorMessage);
    }
  }

  /// Return value for [stillAMember] (the leaver-backstop liveness predicate).
  bool stillAMemberResult = true;

  /// Whether [stillAMember] should throw.
  bool shouldThrowOnStillAMember = false;

  /// Args captured from each [stillAMember] call, in order.
  final List<({List<int> mlsGroupId, String ownPubkeyHex})> stillAMemberCalls =
      [];

  @override
  Future<bool> stillAMember({
    required List<int> mlsGroupId,
    required String ownPubkeyHex,
  }) async {
    methodCalls.add('stillAMember');
    stillAMemberCalls.add((
      mlsGroupId: List<int>.of(mlsGroupId),
      ownPubkeyHex: ownPubkeyHex,
    ));
    if (shouldThrowOnStillAMember) {
      throw const CircleServiceException('Mock stillAMember error');
    }
    return stillAMemberResult;
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

  /// Calls to [addMember], in order.
  ///
  /// Each entry captures the mlsGroupId, the member pubkeys (parsed from
  /// each [KeyPackageData.pubkey]), the raw [KeyPackageData] list, and
  /// the creatorFallbackRelays passed to the call.
  final List<
    ({
      List<int> mlsGroupId,
      List<String> memberPubkeys,
      List<KeyPackageData> memberKeyPackages,
      List<String> creatorFallbackRelays,
    })
  >
  addMemberCalls = [];

  /// Whether [addMember] should throw a [CircleServiceException].
  bool shouldThrowOnAddMember = false;

  /// Configurable return value for [addMember].
  ///
  /// When non-null, [addMember] returns this value. When null, returns a
  /// default [AddMemberResult] with welcomesSent = 1 and welcomesTotal = 1.
  AddMemberResult? addMemberResult;

  @override
  Future<AddMemberResult> addMember({
    required Future<List<int>> Function() secretProvider,
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
    List<String> creatorFallbackRelays = const [],
  }) async {
    methodCalls.add('addMember');
    addMemberCalls.add((
      mlsGroupId: List<int>.of(mlsGroupId),
      memberPubkeys: memberKeyPackages.map((kp) => kp.pubkey).toList(),
      memberKeyPackages: List<KeyPackageData>.of(memberKeyPackages),
      creatorFallbackRelays: List<String>.of(creatorFallbackRelays),
    ));
    if (shouldThrowOnAddMember) {
      throw const CircleServiceException('Mock addMember error');
    }
    return addMemberResult ??
        const AddMemberResult(welcomesSent: 1, welcomesTotal: 1);
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
  Future<void> resetAllSyncCursors() async {
    methodCalls.add('resetAllSyncCursors');
  }

  @override
  Future<void> closeAndInvalidate() async {
    methodCalls.add('closeAndInvalidate');
  }

  @override
  Future<void> wipeAllMlsState() async {
    methodCalls.add('wipeAllMlsState');
  }

  @override
  Future<void> pruneProcessedGiftWraps({DateTime? now}) async {
    methodCalls.add('pruneProcessedGiftWraps');
  }

  @override
  Future<int> pruneExpiredLastKnown({DateTime? now}) async {
    methodCalls.add('pruneExpiredLastKnown');
    return 0;
  }

  @override
  Future<List<LocationEventResult>> decryptLocation({
    required String eventJson,
  }) async {
    methodCalls.add('decryptLocation');
    decryptCallEventJsons.add(eventJson);
    if (_decryptIndex < decryptLocationResults.length) {
      return decryptLocationResults[_decryptIndex++];
    }
    return const [];
  }

  /// Auto-commits to attach to a [decryptLocationCollectingCommits] call,
  /// keyed by the (0-based) index into [decryptLocationResults] that call
  /// consumes — i.e. set `decryptLocationAutoCommits[0]` to attach
  /// auto-commits to whichever call consumes `decryptLocationResults[0]`.
  /// Unset indices attach no auto-commits, so existing tests that only
  /// populate [decryptLocationResults] are unaffected.
  final Map<int, List<PendingAutoCommit>> decryptLocationAutoCommits = {};

  /// Pending tokens passed to [confirmPendingCommit], in call order.
  final List<PendingCommitToken> confirmPendingCommitCalls = [];

  /// Pending tokens passed to [failPendingCommit], in call order.
  final List<PendingCommitToken> failPendingCommitCalls = [];

  @override
  Future<DecryptLocationOutcome> decryptLocationCollectingCommits({
    required String eventJson,
  }) async {
    // Shares `decryptLocationResults`/`_decryptIndex`/`decryptCallEventJsons`
    // with [decryptLocation] (and records the SAME `methodCalls` entry) so
    // every existing test that only sets `decryptLocationResults` keeps
    // working unchanged against this richer method.
    methodCalls.add('decryptLocation');
    decryptCallEventJsons.add(eventJson);
    if (_decryptIndex < decryptLocationResults.length) {
      final index = _decryptIndex;
      final results = decryptLocationResults[_decryptIndex++];
      return DecryptLocationOutcome(
        results: results,
        autoCommits: decryptLocationAutoCommits[index] ?? const [],
      );
    }
    return const DecryptLocationOutcome(results: [], autoCommits: []);
  }

  @override
  Future<void> confirmPendingCommit(PendingCommitToken pending) async {
    methodCalls.add('confirmPendingCommit');
    confirmPendingCommitCalls.add(pending);
  }

  @override
  Future<void> failPendingCommit(PendingCommitToken pending) async {
    methodCalls.add('failPendingCommit');
    failPendingCommitCalls.add(pending);
  }

  /// Records the last seconds value passed to [advanceGroupCursorToEventSecs],
  /// or `null` if it was never called.
  int? advanceGroupCursorLastSecs;

  /// Records the last seconds value passed to [advanceInboxCursorToWrapSecs],
  /// or `null` if it was never called.
  int? advanceInboxCursorLastSecs;

  @override
  Future<void> advanceGroupCursorToEventSecs(int eventCreatedAtSecs) async {
    methodCalls.add('advanceGroupCursorToEventSecs:$eventCreatedAtSecs');
    advanceGroupCursorLastSecs = eventCreatedAtSecs;
  }

  @override
  Future<void> advanceInboxCursorToWrapSecs(int wrapCreatedAtSecs) async {
    methodCalls.add('advanceInboxCursorToWrapSecs:$wrapCreatedAtSecs');
    advanceInboxCursorLastSecs = wrapCreatedAtSecs;
  }

  // NOTE: `signKeyPackageEvent` / `recordPublishedKeyPackages` were removed
  // from `CircleService` — `KeyPackage` publish now lives entirely behind
  // `RelayService.maintainKeyPackage` (see `key_package_provider.dart`).

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

  /// Local nicknames set (or cleared, via `null`) via
  /// [setContactDisplayName], keyed by pubkey.
  final Map<String, String?> nicknames = {};

  /// Whether [setContactDisplayName] should throw an exception.
  bool shouldThrowOnSetContactDisplayName = false;

  @override
  Future<void> setContactDisplayName({
    required String pubkey,
    String? displayName,
  }) async {
    methodCalls.add('setContactDisplayName');
    if (shouldThrowOnSetContactDisplayName) {
      throw const CircleServiceException('Mock setContactDisplayName error');
    }
    nicknames[pubkey] = displayName;
  }

  /// Calls to [updateCircleRelays], in order.
  final List<({List<int> mlsGroupId, List<String> newRelays})>
  updateCircleRelayCalls = [];

  /// Whether [updateCircleRelays] should throw an exception.
  bool shouldThrowOnUpdateCircleRelays = false;

  @override
  Future<void> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  }) async {
    methodCalls.add('updateCircleRelays');
    updateCircleRelayCalls.add((
      mlsGroupId: List<int>.of(mlsGroupId),
      newRelays: List<String>.of(newRelays),
    ));
    if (shouldThrowOnUpdateCircleRelays) {
      throw const CircleServiceException('Mock updateCircleRelays error');
    }
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
    List<String>? relays,
  }) {
    return Circle(
      mlsGroupId: mlsGroupId ?? [1, 2, 3, 4],
      nostrGroupId: nostrGroupId ?? [5, 6, 7, 8],
      displayName: displayName,
      circleType: CircleType.locationSharing,
      relays: relays ?? const ['wss://relay.example.com'],
      membershipStatus: membershipStatus,
      members: members ?? const [],
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );
  }

  /// Creates a test circle member with default values.
  static CircleMember createMember({
    String? pubkey,
    String? npub,
    String? displayName,
    bool isAdmin = false,
    MembershipStatus status = MembershipStatus.accepted,
  }) {
    return CircleMember(
      pubkey:
          pubkey ??
          'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
      npub:
          npub ??
          'npub140qj8hh5264uzg7773t2hsfrmm69d27py000g44tcy3aaazk40xskwpam3',
      displayName: displayName,
      isAdmin: isAdmin,
      status: status,
    );
  }
}
