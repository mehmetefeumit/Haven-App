/// Location sharing service.
///
/// Orchestrates the encrypt-publish-fetch-decrypt pipeline for sharing
/// location data with circle members via MLS-encrypted Nostr events.
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';

/// A circle member's location.
@immutable
class MemberLocation {
  /// Creates a [MemberLocation].
  const MemberLocation({
    required this.pubkey,
    required this.latitude,
    required this.longitude,
    required this.geohash,
    required this.timestamp,
    required this.expiresAt,
    required this.precision,
    this.displayName,
  });

  /// Member's Nostr public key (hex-encoded).
  final String pubkey;

  /// Latitude (obfuscated to sender's precision).
  final double latitude;

  /// Longitude (obfuscated to sender's precision).
  final double longitude;

  /// Geohash of the location.
  final String geohash;

  /// When the location was recorded.
  final DateTime timestamp;

  /// When this location expires.
  final DateTime expiresAt;

  /// Precision level ("Private", "Standard", or "Enhanced").
  final String precision;

  /// Display name from local contacts (if available).
  final String? displayName;

  /// Whether this location has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Freshness based on age.
  LocationFreshness get freshness {
    final age = DateTime.now().difference(timestamp);
    if (age.inMinutes < 1) return LocationFreshness.live;
    if (age.inMinutes < 5) return LocationFreshness.recent;
    if (age.inMinutes < 15) return LocationFreshness.stale;
    return LocationFreshness.old;
  }
}

/// Service for sharing and receiving locations through circles.
///
/// Coordinates the encryption, relay publishing, fetching, and
/// decryption of location data using MLS-encrypted Nostr events.
class LocationSharingService {
  /// Creates a [LocationSharingService].
  LocationSharingService({
    required CircleService circleService,
    required RelayService relayService,
  }) : _circleService = circleService,
       _relayService = relayService;

  final CircleService _circleService;
  final RelayService _relayService;

  /// Seen event IDs for deduplication (in-memory, reset on restart).
  final Set<String> _seenEventIds = {};

  /// Clock skew buffer in seconds.
  ///
  /// We subtract this from the `since` timestamp to handle clock
  /// differences between relays and clients.
  static const int _clockSkewBufferSeconds = 60;

  /// Encrypts and publishes the user's location to a circle.
  ///
  /// Encrypts the location via MLS, then publishes the kind 445 event
  /// to the circle's relays using per-group Tor circuit isolation.
  ///
  /// Returns the publish result.
  Future<PublishResult> publishLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async {
    // Step 1: Encrypt location
    final encrypted = await _circleService.encryptLocation(
      mlsGroupId: mlsGroupId,
      senderPubkeyHex: senderPubkeyHex,
      latitude: latitude,
      longitude: longitude,
    );

    // Step 2: Publish to relays using group circuit
    return _relayService.publishEvent(
      eventJson: encrypted.eventJson,
      relays: encrypted.relays,
      isIdentityOperation: false,
      nostrGroupId: encrypted.nostrGroupId,
    );
  }

  /// Fetches and decrypts member locations for a circle.
  ///
  /// Applies a 60-second overlap buffer to `since` for clock skew
  /// tolerance. Deduplicates events by ID and keeps only the latest
  /// non-expired location per sender.
  Future<List<MemberLocation>> fetchMemberLocations({
    required Circle circle,
    DateTime? since,
  }) async {
    if (circle.membershipStatus != MembershipStatus.accepted) {
      return [];
    }

    // Apply clock skew buffer to since timestamp
    final adjustedSince = since != null
        ? since.subtract(const Duration(seconds: _clockSkewBufferSeconds))
        : null;

    // Step 1: Fetch encrypted events from relays
    final eventJsons = await _relayService.fetchGroupMessages(
      nostrGroupId: circle.nostrGroupId,
      relays: circle.relays,
      since: adjustedSince,
    );

    // Step 2: Decrypt each event, collecting valid locations
    final locations = <MemberLocation>[];
    for (final eventJson in eventJsons) {
      // Deduplicate by event ID (extract from JSON)
      final eventId = _extractEventId(eventJson);
      if (eventId != null && !_seenEventIds.add(eventId)) {
        continue; // Already processed
      }

      try {
        final decrypted = await _circleService.decryptLocation(
          eventJson: eventJson,
        );
        if (decrypted == null || decrypted.isExpired) continue;

        // Look up display name from circle members
        final member = circle.members
            .where((m) => m.pubkey == decrypted.senderPubkey)
            .firstOrNull;

        locations.add(
          MemberLocation(
            pubkey: decrypted.senderPubkey,
            latitude: decrypted.latitude,
            longitude: decrypted.longitude,
            geohash: decrypted.geohash,
            timestamp: decrypted.timestamp,
            expiresAt: decrypted.expiresAt,
            precision: decrypted.precision,
            displayName: member?.displayName,
          ),
        );
      } on Object catch (e) {
        // Log but skip individual decryption failures
        debugPrint('Failed to decrypt location event');
      }
    }

    // Step 3: Keep only the latest location per sender
    return _deduplicateBySender(locations);
  }

  /// Extracts the event ID from a JSON-serialized Nostr event.
  ///
  /// Performs a simple string search to avoid full JSON parsing overhead.
  String? _extractEventId(String eventJson) {
    // Event JSON looks like: {"id":"abc123",...}
    // Find "id":" and extract the value
    const prefix = '"id":"';
    final start = eventJson.indexOf(prefix);
    if (start == -1) return null;
    final valueStart = start + prefix.length;
    final end = eventJson.indexOf('"', valueStart);
    if (end == -1) return null;
    return eventJson.substring(valueStart, end);
  }

  /// Keeps only the latest location per sender public key.
  List<MemberLocation> _deduplicateBySender(List<MemberLocation> locations) {
    final latest = <String, MemberLocation>{};
    for (final loc in locations) {
      final existing = latest[loc.pubkey];
      if (existing == null || loc.timestamp.isAfter(existing.timestamp)) {
        latest[loc.pubkey] = loc;
      }
    }
    return latest.values.toList();
  }
}
