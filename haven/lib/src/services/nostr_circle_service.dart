/// Production implementation of [CircleService] using Rust core.
///
/// This implementation:
/// - Uses haven-core for MLS group operations (via flutter_rust_bridge)
/// - Stores circle metadata in encrypted SQLCipher database
/// - Requires data directory for persistent storage
///
/// # Architecture
///
/// ```text
/// Flutter App
///     │
///     └── NostrCircleService (this class)
///             │
///             └── CircleManagerFfi (Rust via FFI)
///                     │
///                     ├── MLS Manager (group operations)
///                     └── SQLCipher DB (circle metadata)
/// ```
library;

import 'dart:typed_data';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:path_provider/path_provider.dart';

/// Production implementation of [CircleService].
///
/// Uses the Rust core for MLS group operations and persistent storage.
class NostrCircleService implements CircleService {
  /// Creates a new [NostrCircleService].
  ///
  /// The service must be initialized with [initialize] before use.
  NostrCircleService();

  CircleManagerFfi? _manager;
  bool _initialized = false;

  /// Initializes the circle manager with persistent storage.
  ///
  /// Must be called before any other methods.
  /// Uses the application documents directory for storage.
  Future<void> initialize() async {
    if (_initialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    final dataDir = '${appDir.path}/haven';
    _manager = await CircleManagerFfi.newInstance(dataDir: dataDir);
    _initialized = true;
  }

  /// Ensures the manager is initialized.
  Future<CircleManagerFfi> _ensureInitialized() async {
    if (!_initialized || _manager == null) {
      await initialize();
    }
    return _manager!;
  }

  /// Converts a Rust timestamp to DateTime.
  DateTime _timestampToDateTime(num timestamp) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt() * 1000);
  }

  /// Converts a membership status string to enum.
  MembershipStatus _parseMembershipStatus(String status) {
    return switch (status.toLowerCase()) {
      'pending' => MembershipStatus.pending,
      'accepted' => MembershipStatus.accepted,
      'declined' => MembershipStatus.declined,
      _ => MembershipStatus.pending,
    };
  }

  /// Converts a circle type string to enum.
  CircleType _parseCircleType(String circleType) {
    return switch (circleType.toLowerCase()) {
      'location_sharing' => CircleType.locationSharing,
      'direct_share' => CircleType.directShare,
      _ => CircleType.locationSharing,
    };
  }

  /// Converts a CircleType enum to string for FFI.
  String _circleTypeToString(CircleType circleType) {
    return switch (circleType) {
      CircleType.locationSharing => 'location_sharing',
      CircleType.directShare => 'direct_share',
    };
  }

  /// Converts FFI member to service member.
  CircleMember _convertMember(CircleMemberFfi ffiMember) {
    return CircleMember(
      pubkey: ffiMember.pubkey,
      displayName: ffiMember.displayName,
      avatarPath: ffiMember.avatarPath,
      isAdmin: ffiMember.isAdmin,
      // Members in a visible circle have accepted their invitation
      status: MembershipStatus.accepted,
    );
  }

  /// Converts FFI circle with members to service circle.
  Circle _convertCircleWithMembers(CircleWithMembersFfi ffiCircle) {
    return Circle(
      mlsGroupId: ffiCircle.circle.mlsGroupId.toList(),
      nostrGroupId: ffiCircle.circle.nostrGroupId.toList(),
      displayName: ffiCircle.circle.displayName,
      circleType: _parseCircleType(ffiCircle.circle.circleType),
      relays: ffiCircle.circle.relays,
      membershipStatus: _parseMembershipStatus(ffiCircle.membershipStatus),
      members: ffiCircle.members.map(_convertMember).toList(),
      createdAt: _timestampToDateTime(ffiCircle.circle.createdAt),
      updatedAt: _timestampToDateTime(ffiCircle.circle.updatedAt),
    );
  }

  /// Converts FFI invitation to service invitation.
  Invitation _convertInvitation(InvitationFfi ffiInvitation) {
    return Invitation(
      mlsGroupId: ffiInvitation.mlsGroupId.toList(),
      circleName: ffiInvitation.circleName,
      inviterPubkey: ffiInvitation.inviterPubkey,
      memberCount: ffiInvitation.memberCount,
      invitedAt: _timestampToDateTime(ffiInvitation.invitedAt),
    );
  }

  @override
  Future<CircleCreationResult> createCircle({
    required String creatorPubkey,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    String? description,
    CircleType circleType = CircleType.locationSharing,
    List<String>? relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      // Extract KeyPackage JSON strings from KeyPackageData
      final keyPackagesJson =
          memberKeyPackages.map((kp) => kp.eventJson).toList();

      // Collect relay URLs from all members
      final memberRelays =
          memberKeyPackages.expand((kp) => kp.relays).toSet().toList();
      final circleRelays = relays ?? memberRelays;

      final result = await manager.createCircle(
        creatorPubkey: creatorPubkey,
        memberKeyPackagesJson: keyPackagesJson,
        name: name,
        description: description,
        circleType: _circleTypeToString(circleType),
        relays: circleRelays,
      );

      // Convert FFI result to service types
      final circle = Circle(
        mlsGroupId: result.circle.mlsGroupId.toList(),
        nostrGroupId: result.circle.nostrGroupId.toList(),
        displayName: result.circle.displayName,
        circleType: _parseCircleType(result.circle.circleType),
        relays: result.circle.relays,
        membershipStatus: MembershipStatus.accepted, // Creator is accepted
        members: const [], // Members added after invitations are sent
        createdAt: _timestampToDateTime(result.circle.createdAt),
        updatedAt: _timestampToDateTime(result.circle.updatedAt),
      );

      // Convert welcome events
      final welcomeEvents = <WelcomeEvent>[];
      for (var i = 0; i < result.welcomeEvents.length; i++) {
        final welcomeEvent = result.welcomeEvents[i];
        // Map welcome event to recipient based on index
        if (i < memberKeyPackages.length) {
          final recipient = memberKeyPackages[i];
          welcomeEvents.add(
            WelcomeEvent(
              recipientPubkey: recipient.pubkey,
              eventJson: _unsignedEventToJson(welcomeEvent),
              relays: recipient.relays,
            ),
          );
        }
      }

      return CircleCreationResult(
        circle: circle,
        welcomeEvents: welcomeEvents,
      );
    } on Exception catch (e) {
      throw CircleServiceException('Failed to create circle: $e');
    }
  }

  /// Converts an unsigned event FFI object to JSON string.
  String _unsignedEventToJson(UnsignedEventFfi event) {
    // Build JSON representation of the unsigned event
    final tagsJson = event.tags.map((tag) => tag.toList()).toList();

    return '{'
        '"kind":${event.kind},'
        '"content":"${_escapeJson(event.content)}",'
        '"tags":${_tagsToJson(tagsJson)},'
        '"created_at":${event.createdAt},'
        '"pubkey":"${event.pubkey}"'
        '}';
  }

  /// Escapes a string for JSON.
  String _escapeJson(String input) {
    return input
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
  }

  /// Converts tags list to JSON string.
  String _tagsToJson(List<List<String>> tags) {
    final tagStrings = tags.map((tag) {
      final items = tag.map((item) => '"${_escapeJson(item)}"').join(',');
      return '[$items]';
    }).join(',');
    return '[$tagStrings]';
  }

  @override
  Future<List<Circle>> getVisibleCircles() async {
    final manager = await _ensureInitialized();

    try {
      final ffiCircles = manager.getVisibleCircles();
      return ffiCircles.map(_convertCircleWithMembers).toList();
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get circles: $e');
    }
  }

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);
      final ffiCircle = manager.getCircle(mlsGroupId: groupId);
      if (ffiCircle == null) {
        return null;
      }
      return _convertCircleWithMembers(ffiCircle);
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get circle: $e');
    }
  }

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);
      final ffiMembers = manager.getMembers(mlsGroupId: groupId);
      return ffiMembers.map(_convertMember).toList();
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get members: $e');
    }
  }

  @override
  Future<List<Invitation>> getPendingInvitations() async {
    final manager = await _ensureInitialized();

    try {
      final ffiInvitations = manager.getPendingInvitations();
      return ffiInvitations.map(_convertInvitation).toList();
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get pending invitations: $e');
    }
  }

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final ffiCircle = await manager.acceptInvitation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
      return _convertCircleWithMembers(ffiCircle);
    } on Exception catch (e) {
      throw CircleServiceException('Failed to accept invitation: $e');
    }
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      await manager.declineInvitation(mlsGroupId: Uint8List.fromList(mlsGroupId));
    } on Exception catch (e) {
      throw CircleServiceException('Failed to decline invitation: $e');
    }
  }

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      // Leave circle returns an update result with evolution events.
      // These should be published to notify other members.
      final groupId = Uint8List.fromList(mlsGroupId);
      await manager.leaveCircle(mlsGroupId: groupId);
      // TODO(haven): Publish the evolution event via RelayService.
    } on Exception catch (e) {
      throw CircleServiceException('Failed to leave circle: $e');
    }
  }
}
