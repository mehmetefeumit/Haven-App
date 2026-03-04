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
///
/// Maintains a per-circle cache of the latest location per sender so
/// that locations persist across polling cycles. Without this cache,
/// MLS `process_message` returns `PreviouslyFailed` for already-decrypted
/// events, causing locations to vanish after the first successful fetch.
class LocationSharingService {
  /// Creates a [LocationSharingService].
  LocationSharingService({
    required CircleService circleService,
    required RelayService relayService,
  }) : _circleService = circleService,
       _relayService = relayService;

  final CircleService _circleService;
  final RelayService _relayService;

  /// Seen event IDs — prevents redundant MLS decryption calls.
  ///
  /// MLS `process_message` returns `PreviouslyFailed` for already-processed
  /// events, so skipping seen IDs avoids wasted decrypt attempts. The
  /// decrypted result is preserved in [_locationCache] instead.
  final Set<String> _seenEventIds = {};

  /// Per-circle location cache: latest non-expired location per sender.
  ///
  /// Keyed by hex-encoded `nostrGroupId`, then by sender pubkey.
  /// Persists across polling cycles so locations remain visible
  /// between fetches.
  final Map<String, Map<String, MemberLocation>> _locationCache = {};

  /// Per-circle timestamp of the last successful fetch.
  ///
  /// Passed as `since` on subsequent fetches to avoid downloading the
  /// full event history from relays every polling cycle.
  final Map<String, DateTime> _lastFetchTime = {};

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

    // Step 2: Publish to relays
    return _relayService.publishEvent(
      eventJson: encrypted.eventJson,
      relays: encrypted.relays,
    );
  }

  /// Fetches and decrypts member locations for a circle.
  ///
  /// Uses incremental fetching (tracks `since` per circle) and a
  /// cumulative per-sender cache so that locations persist across
  /// polling cycles. Only new events are decrypted; already-seen
  /// event IDs are skipped (MLS would return `PreviouslyFailed`).
  ///
  /// Applies a 60-second overlap buffer to `since` for clock skew
  /// tolerance. Returns the latest non-expired location per sender
  /// from the cumulative cache.
  Future<List<MemberLocation>> fetchMemberLocations({
    required Circle circle,
    DateTime? since,
  }) async {
    if (circle.membershipStatus != MembershipStatus.accepted) {
      return [];
    }

    final circleKey = _circleKey(circle.nostrGroupId);
    final cache = _locationCache.putIfAbsent(circleKey, () => {});

    // Use tracked last-fetch time if no explicit since is provided
    final effectiveSince = since ?? _lastFetchTime[circleKey];
    final fetchTime = DateTime.now();

    // Apply clock skew buffer to since timestamp
    final adjustedSince = effectiveSince?.subtract(
      const Duration(seconds: _clockSkewBufferSeconds),
    );

    // Step 1: Fetch encrypted events from relays
    final eventJsons = await _relayService.fetchGroupMessages(
      nostrGroupId: circle.nostrGroupId,
      relays: circle.relays,
      since: adjustedSince,
    );

    // Step 2: Decrypt only new events, merge into cache
    for (final eventJson in eventJsons) {
      // Skip already-processed events (MLS would return PreviouslyFailed)
      final eventId = _extractEventId(eventJson);
      if (eventId != null && !_seenEventIds.add(eventId)) {
        continue;
      }

      try {
        final decrypted = await _circleService.decryptLocation(
          eventJson: eventJson,
        );
        if (decrypted == null) continue;

        // Look up display name from circle members
        final member = circle.members
            .where((m) => m.pubkey == decrypted.senderPubkey)
            .firstOrNull;

        final location = MemberLocation(
          pubkey: decrypted.senderPubkey,
          latitude: decrypted.latitude,
          longitude: decrypted.longitude,
          geohash: decrypted.geohash,
          timestamp: decrypted.timestamp,
          expiresAt: decrypted.expiresAt,
          precision: decrypted.precision,
          displayName: member?.displayName,
        );

        // Update cache if this is newer than existing entry
        final existing = cache[location.pubkey];
        if (existing == null ||
            location.timestamp.isAfter(existing.timestamp)) {
          cache[location.pubkey] = location;
        }
      } on Object {
        // Log but skip individual decryption failures
        debugPrint('Failed to decrypt location event');
      }
    }

    // Track fetch time for next incremental query
    _lastFetchTime[circleKey] = fetchTime;

    // Remove expired entries from cache
    cache.removeWhere((_, loc) => loc.isExpired);

    // Step 3: Return all cached locations for this circle
    return cache.values.toList();
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

  /// Converts a `nostrGroupId` to a hex string for use as a map key.
  static String _circleKey(List<int> nostrGroupId) {
    return nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
