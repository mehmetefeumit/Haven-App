/// Location sharing service.
///
/// Orchestrates the encrypt-publish-fetch-decrypt pipeline for sharing
/// location data with circle members via MLS-encrypted Nostr events.
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
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
    this.retentionSecs = 0,
    this.isStale = false,
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

  /// Sender-controlled retention preference, in seconds.
  ///
  /// This is the value carried inside the encrypted `LocationMessage`
  /// (already clamped at the FFI boundary to the receiver-side ceiling).
  /// A value of `0` is the sender's "do not store" sentinel — receivers
  /// should drop any persisted last-known row for this sender.
  final int retentionSecs;

  /// `true` when this entry was loaded from the persistent fallback cache
  /// because no fresh relay event has confirmed it in the current session.
  ///
  /// Cleared the moment a fresh relay event arrives for the same sender.
  /// Not persisted — always derived from in-session state.
  final bool isStale;

  /// Whether this location's freshness window has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Returns a copy with the given fields overridden.
  MemberLocation copyWith({bool? isStale, String? displayName}) {
    return MemberLocation(
      pubkey: pubkey,
      latitude: latitude,
      longitude: longitude,
      geohash: geohash,
      timestamp: timestamp,
      expiresAt: expiresAt,
      precision: precision,
      displayName: displayName ?? this.displayName,
      retentionSecs: retentionSecs,
      isStale: isStale ?? this.isStale,
    );
  }

  /// Freshness based on age.
  LocationFreshness get freshness {
    final age = DateTime.now().difference(timestamp);
    if (age.inMinutes < 1) return LocationFreshness.live;
    if (age.inMinutes < 5) return LocationFreshness.recent;
    if (age.inMinutes < 15) return LocationFreshness.stale;
    return LocationFreshness.old;
  }
}

/// Result of fetching member locations for a circle.
@immutable
class LocationFetchResult {
  /// Creates a [LocationFetchResult].
  const LocationFetchResult({
    required this.locations,
    this.groupUpdated = false,
    this.contactsUpdated = false,
  });

  /// Decrypted member locations (non-expired, latest per sender).
  final List<MemberLocation> locations;

  /// Whether any MLS group state change (commit/proposal) was processed
  /// during this fetch. When `true`, the caller should refresh the
  /// circle's member list to reflect roster changes.
  final bool groupUpdated;

  /// Whether any new contact display names were learned from incoming
  /// location messages. When `true`, the caller should refresh the
  /// circle list so member tiles show updated names.
  final bool contactsUpdated;
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
    IdentityService? identityService,
  }) : _circleService = circleService,
       _relayService = relayService,
       _identityService = identityService;

  final CircleService _circleService;
  final RelayService _relayService;
  final IdentityService? _identityService;

  /// Cached lowercase-hex own pubkey. Resolved lazily once per process and
  /// used to skip persisting echoed self-broadcasts. Stored lowercase so the
  /// self-compare is case-insensitive regardless of how the identity service
  /// normalises its output.
  String? _ownPubkeyHex;

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
  /// to the circle's relays.
  ///
  /// [retentionSecs] is the sender-controlled retention preference embedded
  /// in the encrypted message. Receivers honour this as a soft contract,
  /// clamped at the FFI boundary to the receiver-side ceiling. A value of
  /// `0` is the "do not store" sentinel.
  ///
  /// [precisionLabel] is the Rust `LocationPrecision` label string.
  /// When `null`, the Rust core defaults to `Enhanced` (~1.1 m).
  ///
  /// Returns the publish result.
  Future<PublishResult> publishLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int retentionSecs,
    String? displayName,
    String? precisionLabel,
  }) async {
    // Step 1: Encrypt location
    debugPrint('[LocationService] Encrypting location via MLS...');
    final encrypted = await _circleService.encryptLocation(
      mlsGroupId: mlsGroupId,
      senderPubkeyHex: senderPubkeyHex,
      latitude: latitude,
      longitude: longitude,
      displayName: displayName,
      retentionSecs: retentionSecs,
      precisionLabel: precisionLabel,
    );
    debugPrint(
      '[LocationService] Encrypted OK — '
      'publishing to ${encrypted.relays.length} relay(s)',
    );

    // Step 2: Publish to relays
    return _relayService.publishEvent(
      eventJson: encrypted.eventJson,
      relays: encrypted.relays,
    );
  }

  /// Tracks which circles have already been hydrated from the persistent
  /// last-known-location cache. Hydration runs once per circle per session
  /// at the first `fetchMemberLocations` call.
  final Set<String> _hydratedCircles = {};

  /// Hydrates the in-memory cache from the persistent store on first use.
  ///
  /// Entries seeded from disk are marked `isStale: true`. The flag is
  /// cleared when a fresh relay event arrives for the same sender during
  /// the current session.
  Future<void> _hydrateFromStoreIfNeeded(
    Circle circle,
    String circleKey,
  ) async {
    if (_hydratedCircles.contains(circleKey)) return;
    _hydratedCircles.add(circleKey);

    try {
      final rows = await _circleService.snapshotLastKnownForCircle(
        nostrGroupId: circle.nostrGroupId,
      );
      if (rows.isEmpty) {
        debugPrint(
          '[LocationService] No cached last-known rows for '
          '"${circle.displayName}"',
        );
        return;
      }

      final cache = _locationCache.putIfAbsent(circleKey, () => {});
      for (final row in rows) {
        // Look up display name from local contacts (more authoritative).
        final member = circle.members
            .where((m) => m.pubkey == row.senderPubkey)
            .firstOrNull;
        cache[row.senderPubkey] = MemberLocation(
          pubkey: row.senderPubkey,
          latitude: row.latitude,
          longitude: row.longitude,
          geohash: row.geohash,
          timestamp: row.timestamp,
          expiresAt: row.expiresAt,
          precision: row.precision,
          displayName: member?.displayName ?? row.displayName,
          retentionSecs: row.retentionSecs,
          isStale: true,
        );
      }
      debugPrint(
        '[LocationService] Hydrated ${rows.length} stale entry(ies) '
        'for "${circle.displayName}"',
      );
    } on Object catch (e) {
      debugPrint('[LocationService] Hydration failed: $e');
    }
  }

  /// Wipes every cached and persisted last-known location.
  ///
  /// Called from the identity-deletion path. Best-effort: errors are logged
  /// but do not propagate, since the caller is in the middle of an account
  /// teardown.
  Future<void> wipeAll() async {
    _locationCache.clear();
    _seenEventIds.clear();
    _lastFetchTime.clear();
    _hydratedCircles.clear();
    try {
      await _circleService.wipeAllLastKnownLocations();
    } on Object catch (e) {
      debugPrint('[LocationService] wipeAll failed: $e');
    }
  }

  /// Removes every cached and persisted location for a specific circle.
  ///
  /// Called from the leave-circle / circle-deletion flow so no residual
  /// location data for former co-members remains on disk.
  Future<void> removeCircle(List<int> nostrGroupId) async {
    final circleKey = _circleKey(nostrGroupId);
    _locationCache.remove(circleKey);
    _lastFetchTime.remove(circleKey);
    _hydratedCircles.remove(circleKey);
    try {
      await _circleService.removeLastKnownCircle(nostrGroupId: nostrGroupId);
    } on Object catch (e) {
      debugPrint('[LocationService] removeCircle failed: $e');
    }
  }

  /// Fetches and decrypts member locations for a circle.
  ///
  /// Uses incremental fetching (tracks `since` per circle) and a
  /// cumulative per-sender cache so that locations persist across
  /// polling cycles. Only new events are decrypted; already-seen
  /// event IDs are skipped (MLS would return `PreviouslyFailed`).
  ///
  /// Applies a 60-second overlap buffer to `since` for clock skew
  /// tolerance. Returns a [LocationFetchResult] with the latest
  /// non-expired location per sender from the cumulative cache, plus
  /// a flag indicating whether any MLS group state changes were
  /// processed (so the caller can refresh circle membership).
  Future<LocationFetchResult> fetchMemberLocations({
    required Circle circle,
    DateTime? since,
  }) async {
    if (circle.membershipStatus != MembershipStatus.accepted) {
      return const LocationFetchResult(locations: []);
    }

    final circleKey = _circleKey(circle.nostrGroupId);
    await _hydrateFromStoreIfNeeded(circle, circleKey);
    final cache = _locationCache.putIfAbsent(circleKey, () => {});

    // Resolve own pubkey once per process so we can skip persisting echoed
    // self-broadcasts. Cached on the service instance to avoid hitting the
    // identity FFI on every fetch cycle.
    if (_ownPubkeyHex == null && _identityService != null) {
      try {
        final pk = await _identityService.getPubkeyHex();
        _ownPubkeyHex = pk.toLowerCase();
      } on Object catch (e) {
        debugPrint('[LocationService] own pubkey lookup failed: $e');
      }
    }
    final ownPubkeyHex = _ownPubkeyHex;

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

    debugPrint(
      '[LocationService] Fetched ${eventJsons.length} event(s) from '
      '${circle.relays.length} relay(s) for "${circle.displayName}" '
      '(since=$adjustedSince, cached=${cache.length})',
    );

    // Step 2: Decrypt only new events, merge into cache
    var newEvents = 0;
    var skippedSeen = 0;
    var decryptNull = 0;
    var decryptFailed = 0;
    var groupUpdated = false;
    var contactsUpdated = false;
    for (final eventJson in eventJsons) {
      // Skip already-processed events (MLS would return PreviouslyFailed)
      final eventId = _extractEventId(eventJson);
      if (eventId != null && !_seenEventIds.add(eventId)) {
        skippedSeen++;
        continue;
      }

      try {
        final result = await _circleService.decryptLocation(
          eventJson: eventJson,
        );
        if (result == null) {
          decryptNull++;
          continue;
        }

        // Track MLS group state changes (commits, proposals).
        if (result.groupUpdated) {
          groupUpdated = true;
          debugPrint(
            '[LocationService] MLS group update processed for '
            '"${circle.displayName}"',
          );
        }

        final decrypted = result.location;
        if (decrypted == null) {
          // Group update with no location — already tracked above.
          continue;
        }

        // Skip echoed self-broadcasts: never persist our own location to
        // the local last-known store, and never surface it on the map as
        // a peer marker. The live user pin is rendered from the fresh
        // device GPS stream elsewhere in the UI. Lowercase compare is
        // defensive — the FFI already normalises, but we do not want a
        // stray uppercase hex anywhere in the pipeline to break this.
        if (ownPubkeyHex != null &&
            decrypted.senderPubkey.toLowerCase() == ownPubkeyHex) {
          continue;
        }
        newEvents++;

        // Look up display name from circle members
        final member = circle.members
            .where((m) => m.pubkey == decrypted.senderPubkey)
            .firstOrNull;

        // Persist the sender's display name to the contacts database so
        // the member list (and any future consumer of CircleMember) can
        // show it without relying on the location payload. Only writes
        // when no name is stored yet (preserves user-set overrides).
        // Awaited so the write completes before the caller refreshes the
        // circle list — otherwise the provider may re-read stale data.
        final senderName = decrypted.displayName;
        if (senderName != null &&
            senderName.isNotEmpty &&
            member?.displayName == null) {
          await _circleService.setContactDisplayNameIfAbsent(
            pubkey: decrypted.senderPubkey,
            displayName: senderName,
          );
          contactsUpdated = true;
        }

        // Clamp sender retention to receiver-side hard ceiling.
        final maxRetention = _circleService.locationReceiverMaxRetentionSecs;
        final effectiveRetention = decrypted.retentionSecs.clamp(
          0,
          maxRetention,
        );

        final location = MemberLocation(
          pubkey: decrypted.senderPubkey,
          latitude: decrypted.latitude,
          longitude: decrypted.longitude,
          geohash: decrypted.geohash,
          timestamp: decrypted.timestamp,
          expiresAt: decrypted.expiresAt,
          precision: decrypted.precision,
          displayName: member?.displayName ?? decrypted.displayName,
          retentionSecs: effectiveRetention,
        );

        // Persist or wipe according to sender-controlled retention.
        if (effectiveRetention == 0) {
          // Sender requested "do not store" — drop any prior cached row
          // from disk AND evict from the in-memory cache so the map
          // immediately stops surfacing this sender. This path doubles as
          // the "Clear my location from others" sentinel.
          try {
            await _circleService.removeLastKnownMember(
              nostrGroupId: circle.nostrGroupId,
              senderPubkey: decrypted.senderPubkey,
            );
          } on Object catch (e) {
            debugPrint('[LocationService] removeLastKnownMember failed: $e');
          }
          cache.remove(decrypted.senderPubkey);
          continue;
        } else {
          final purgeAfter = decrypted.timestamp.add(
            Duration(seconds: effectiveRetention),
          );
          try {
            await _circleService.upsertLastKnownLocation(
              nostrGroupId: circle.nostrGroupId,
              senderPubkey: decrypted.senderPubkey,
              latitude: decrypted.latitude,
              longitude: decrypted.longitude,
              geohash: decrypted.geohash,
              precision: decrypted.precision,
              timestamp: decrypted.timestamp,
              expiresAt: decrypted.expiresAt,
              retentionSecs: effectiveRetention,
              purgeAfter: purgeAfter,
              updatedAt: DateTime.now(),
              displayName: decrypted.displayName,
            );
          } on Object catch (e) {
            debugPrint('[LocationService] upsertLastKnownLocation failed: $e');
          }
        }

        // Update cache if this is newer than existing entry. Always
        // mark fresh — a relay event has confirmed this sender.
        final existing = cache[location.pubkey];
        if (existing == null ||
            location.timestamp.isAfter(existing.timestamp)) {
          cache[location.pubkey] = location;
        } else if (existing.isStale) {
          // Same-or-older event but the cached entry was hydrated from
          // disk — clear the stale flag now that the sender is confirmed
          // live in this session.
          cache[location.pubkey] = existing.copyWith(isStale: false);
        }
      } on Object catch (e) {
        decryptFailed++;
        debugPrint('[LocationService] Decrypt failed: $e');
      }
    }

    debugPrint(
      '[LocationService] Results: $newEvents new, $skippedSeen seen, '
      '$decryptNull null, $decryptFailed failed'
      '${groupUpdated ? ', group updated' : ''}',
    );

    // Track fetch time for next incremental query
    _lastFetchTime[circleKey] = fetchTime;

    // Note: expired in-memory entries are intentionally retained. The
    // persistent store's `purge_after` column enforces eviction at the
    // row level; the UI marks expired/stale entries with a faded marker.

    // Step 3: Return all cached locations for this circle
    return LocationFetchResult(
      locations: cache.values.toList(),
      groupUpdated: groupUpdated,
      contactsUpdated: contactsUpdated,
    );
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
