/// Abstract interface for relay services.
///
/// Provides a platform-agnostic API for Nostr relay operations.
///
/// Implementations:
/// - [NostrRelayService] - Production implementation using Rust core
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/services/circle_service.dart';

/// Exception thrown when relay operations fail.
class RelayServiceException implements Exception {
  /// Creates a [RelayServiceException] with the given message.
  const RelayServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'RelayServiceException: $message';
}

/// Result of publishing an event to relays.
@immutable
class PublishResult {
  /// Creates a new [PublishResult].
  const PublishResult({
    required this.eventId,
    required this.acceptedBy,
    required this.rejectedBy,
    required this.failed,
  });

  /// The event ID that was published.
  final String eventId;

  /// Relay URLs that accepted the event.
  final List<String> acceptedBy;

  /// Relay URLs that rejected the event with reasons.
  final List<RelayRejection> rejectedBy;

  /// Relay URLs that failed to respond.
  final List<String> failed;

  /// Whether the publish was successful (at least one relay accepted).
  bool get isSuccess => acceptedBy.isNotEmpty;

  @override
  String toString() =>
      'PublishResult(eventId: $eventId, accepted: ${acceptedBy.length}, '
      'rejected: ${rejectedBy.length}, failed: ${failed.length})';
}

/// Represents a relay rejection with reason.
@immutable
class RelayRejection {
  /// Creates a new [RelayRejection].
  const RelayRejection({required this.relay, required this.reason});

  /// The relay URL that rejected.
  final String relay;

  /// The reason for rejection.
  final String reason;
}

/// Abstract interface for relay services.
///
/// Handles fetching KeyPackages and publishing events via Nostr relays.
abstract class RelayService {
  /// Fetches a user's KeyPackage relay list (kind 10051).
  ///
  /// Returns the list of relay URLs where the user publishes KeyPackages.
  /// Returns an empty list if no relay list is found.
  ///
  /// Throws [RelayServiceException] if the fetch fails.
  Future<List<String>> fetchKeyPackageRelays(String pubkey);

  /// Fetches the latest KeyPackage (kind 443) for a user.
  ///
  /// First fetches the user's KeyPackage relay list (kind 10051),
  /// then fetches the KeyPackage from those relays.
  ///
  /// Returns `null` if no KeyPackage is found (user may not have Haven).
  ///
  /// Throws [RelayServiceException] if the fetch fails.
  Future<KeyPackageData?> fetchKeyPackage(String pubkey);

  /// Publishes a gift-wrapped welcome event.
  ///
  /// The [welcomeEvent] is already gift-wrapped (kind 1059) and ready
  /// to publish. Simply publishes to the recipient's relays.
  ///
  /// Returns the publish result with success/failure per relay.
  ///
  /// Throws [RelayServiceException] if publishing fails completely.
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  });

  /// Publishes a signed event to relays.
  ///
  /// Returns the publish result with success/failure per relay.
  ///
  /// Throws [RelayServiceException] if publishing fails completely.
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  });

  /// Fetches gift-wrapped events (kind 1059) for a recipient.
  ///
  /// Queries relays for NIP-59 gift wrap events addressed to the given
  /// public key. Use [since] to restrict results to events after a timestamp.
  ///
  /// Returns a list of gift-wrap event JSON strings.
  ///
  /// Throws [RelayServiceException] if fetching fails.
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  });

  /// Fetches MLS group messages (kind 445) from relays.
  ///
  /// Queries relays for encrypted group messages using h-tag routing.
  ///
  /// Returns a list of event JSON strings.
  ///
  /// Throws [RelayServiceException] if fetching fails.
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  });
}
