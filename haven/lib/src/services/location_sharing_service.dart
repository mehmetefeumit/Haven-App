/// Location sharing service.
///
/// Orchestrates the encrypt-publish-fetch-decrypt pipeline for sharing
/// location data with circle members via MLS-encrypted Nostr events.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:haven/src/constants/location.dart';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

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
    this.displayName,
    this.avatarContentHash,
  });

  /// Member's Nostr public key (hex-encoded).
  final String pubkey;

  /// Latitude (exact GPS reading).
  final double latitude;

  /// Longitude (exact GPS reading).
  final double longitude;

  /// Geohash of the location.
  final String geohash;

  /// When the location was recorded.
  final DateTime timestamp;

  /// When this location expires.
  final DateTime expiresAt;

  /// Display name from local contacts (if available).
  final String? displayName;

  /// Short content-hash for the member's current avatar (for change-detection
  /// and provider keying). NOT the image bytes — holds only the hash string
  /// so this value class stays lightweight. Null when no avatar is available.
  ///
  /// M2: populated when an ingest-complete event updates the member's avatar.
  /// Drives `memberAvatarThumbnailProvider` invalidation and re-fetch.
  final String? avatarContentHash;

  /// Whether this location's freshness window has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Returns a copy with the given fields overridden.
  MemberLocation copyWith({
    String? displayName,
    String? avatarContentHash,
  }) {
    return MemberLocation(
      pubkey: pubkey,
      latitude: latitude,
      longitude: longitude,
      geohash: geohash,
      timestamp: timestamp,
      expiresAt: expiresAt,
      displayName: displayName ?? this.displayName,
      avatarContentHash: avatarContentHash ?? this.avatarContentHash,
    );
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
///
/// ## Memory bounds
///
/// The in-memory caches are bounded so a long-running session cannot
/// accumulate an unbounded plaintext history:
///
/// - [_locationCache] entries are evicted on each fetch once they pass
///   [cacheEvictionGrace] past their `expiresAt`. The SQLCipher-encrypted
///   `last_known_location` store is the long-term source of truth — it
///   enforces sender-controlled retention via `purge_after`, and the
///   in-memory cache rehydrates from it on first fetch per session.
///   Rehydrated entries are treated identically to live relay events;
///   the marker age pill is computed from [MemberLocation.timestamp].
/// - [_seenEventIds] is FIFO-capped at [maxSeenEventIds]. Oldest IDs
///   are dropped first; any refetch of an already-processed event will
///   produce a benign `PreviouslyFailed` from MLS and be recorded as a
///   `decryptFailed` count.
/// - [onAppPaused] drops all in-memory caches when the app is
///   backgrounded. The persistent store is untouched, and the next
///   `fetchMemberLocations` call transparently rehydrates it.
///
/// ## Avatar completion callback
///
/// When an ingest returns `complete == true`, [onAvatarComplete] is
/// invoked with the circle's MLS group ID and the sender's pubkey hex.
/// The Riverpod layer uses this to invalidate `memberAvatarThumbnailProvider`
/// for that specific (circle, member) key so open member tiles re-fetch
/// the newly stored bytes without waiting for a dispose/rebuild cycle.
/// Register the callback at construction time via [onAvatarComplete].
class LocationSharingService {
  /// Creates a [LocationSharingService].
  ///
  /// [maxSeenEventIds] and [cacheEvictionGrace] are exposed for tests
  /// to exercise eviction behaviour at small scales. Production code
  /// should accept the defaults.
  ///
  /// [onAvatarComplete] is an optional callback invoked when an avatar
  /// ingest completes (`complete == true`). The caller receives the
  /// MLS group ID bytes and sender pubkey hex so it can invalidate the
  /// `memberAvatarThumbnailProvider` family entry for that member.
  LocationSharingService({
    required CircleService circleService,
    required RelayService relayService,
    IdentityService? identityService,
    this.maxSeenEventIds = _defaultMaxSeenEventIds,
    this.cacheEvictionGrace = _defaultCacheEvictionGrace,
    DateTime Function() now = DateTime.now,
    this.onAvatarComplete,
  }) : assert(maxSeenEventIds > 0, 'maxSeenEventIds must be positive'),
       assert(
         cacheEvictionGrace >= Duration.zero,
         'cacheEvictionGrace must be non-negative',
       ),
       _circleService = circleService,
       _relayService = relayService,
       _identityService = identityService,
       _now = now;

  /// Optional callback fired when an avatar ingest completes.
  ///
  /// Invoked with `(mlsGroupId, senderPubkeyHex)` when [_ingestAvatar]
  /// returns `complete == true`. The Riverpod layer wires this to
  /// `ref.invalidate(memberAvatarThumbnailProvider(key))` so a member tile
  /// that is already on screen re-fetches the new avatar bytes without
  /// waiting for a dispose/rebuild cycle.
  ///
  /// The callback must not throw — errors are the caller's responsibility.
  final void Function(List<int> mlsGroupId, String pubkeyHex)? onAvatarComplete;

  /// Maximum number of event IDs retained in [_seenEventIds] before
  /// FIFO eviction kicks in. ~2048 × 64-byte ids ≈ 128 KiB, well below
  /// any reasonable mobile budget, and large enough to cover a polling
  /// cycle's worth of events across all active circles.
  static const int _defaultMaxSeenEventIds = 2048;

  /// Default grace period retained after [MemberLocation.expiresAt]
  /// before an in-memory cache entry is evicted. Chosen to cover a
  /// plausible "last known" display window for members that have
  /// recently gone offline, while bounding session memory.
  static const Duration _defaultCacheEvictionGrace = Duration(minutes: 30);

  /// Maximum number of event IDs retained for dedup. See class docs.
  final int maxSeenEventIds;

  /// Grace period past `expiresAt` before a cached location is evicted.
  /// See class docs.
  final Duration cacheEvictionGrace;

  final CircleService _circleService;
  final RelayService _relayService;
  final IdentityService? _identityService;
  final DateTime Function() _now;

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
  ///
  /// Uses a `LinkedHashSet` (Dart's default `{}` literal) so iteration
  /// is insertion-ordered — this lets us FIFO-evict the oldest entries
  /// once [maxSeenEventIds] is exceeded. See [_enforceSeenEventIdsCap].
  ///
  /// The set is intentionally **global across circles** rather than
  /// partitioned per-circle: Nostr event IDs are already public on every
  /// relay the event reaches, so coexisting IDs from different circles in
  /// one local set does not create a new cross-circle correlation
  /// surface. A shared bound is also more memory-efficient than
  /// N per-circle bounds, and the set never crosses the FFI boundary or
  /// is persisted. Do not partition this without a concrete privacy gain.
  final Set<String> _seenEventIds = <String>{};

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

  /// Monotonic pause generation counter.
  ///
  /// Incremented by [onAppPaused] so any [fetchMemberLocations] call that
  /// was mid-await when the app backgrounded can detect it and bail out
  /// without re-populating the in-memory caches that pause just cleared.
  /// Dart is single-threaded, but `await` resumption is interleaved with
  /// other tasks — without this fence, a pause that lands between the
  /// relay fetch and its post-processing would appear to have "worked",
  /// yet the continuing fetch would refill `_locationCache` and
  /// `_seenEventIds` with the very data we intended to drop.
  int _pauseGeneration = 0;

  /// Encrypts and publishes the user's location to a circle.
  ///
  /// Encrypts the location via MLS, then publishes the kind 445 event
  /// to the circle's relays.
  ///
  /// Returns the publish result.
  Future<PublishResult> publishLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    String? displayName,
  }) async {
    // Step 1: Encrypt location
    debugPrint('[LocationService] Encrypting location via MLS...');
    final encrypted = await _circleService.encryptLocation(
      mlsGroupId: mlsGroupId,
      senderPubkeyHex: senderPubkeyHex,
      latitude: latitude,
      longitude: longitude,
      displayName: displayName,
      // Pass `kLocationPublishMaxInterval + kTtlNetworkBufferSeconds`
      // (168 + 30 = 198 s). Rust samples the outer NIP-40 `expiration`
      // tag uniformly in `[interval, 2 * interval]`, so this yields a
      // TTL window of `[198, 396] s`. The floor (198 s) exceeds the
      // maximum jittered publish delay (168 s) by 30 s, providing a
      // network-propagation buffer so L₁ reaches the relay before
      // L₀'s TTL expires even under moderate latency.
      //
      // The two jitters (publish interval and TTL) remain sampled
      // independently — only the range parameter of the TTL jitter
      // is lifted from `nominal` to `publish_max + buffer`.
      //
      // Receiver contract: `RECEIVER_EXPIRATION_GRACE_SECS = 60 s` in
      // `haven-core/src/location/ttl.rs` sits on top as clock-skew
      // defense-in-depth; it is NOT relied on to cover the publish/
      // TTL gap.
      updateIntervalSecs:
          kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
    );
    // Surface the event id prefix (8 hex chars, public on relays) so that
    // when a receiver later logs an `evt=<prefix>` line we can correlate
    // it back to the originating publish. The full event id never lands in
    // the log — a prefix collision space of ~4 billion is plenty for
    // session-level correlation and far too small to be a tracking vector.
    final encryptedEventId = _extractEventId(encrypted.eventJson);
    final encryptedEvtTag = _evtTag(encryptedEventId);
    debugPrint(
      '[LocationService] evt=$encryptedEvtTag encrypted OK — '
      'publishing to ${encrypted.relays.length} relay(s)',
    );

    // Step 2: Publish to relays
    final publishResult = await _relayService.publishEvent(
      eventJson: encrypted.eventJson,
      relays: encrypted.relays,
    );
    debugPrint(
      '[LocationService] evt=$encryptedEvtTag publish done — '
      'accepted=${publishResult.acceptedBy.length}, '
      'rejected=${publishResult.rejectedBy.length}, '
      'failed=${publishResult.failed.length}',
    );
    return publishResult;
  }

  /// Tracks which circles have already been hydrated from the persistent
  /// last-known-location cache. Hydration runs once per circle per session
  /// at the first `fetchMemberLocations` call.
  final Set<String> _hydratedCircles = {};

  /// Hydrates the in-memory cache from the persistent store on first use.
  ///
  /// Cached rows from the persistent store are treated identically to
  /// freshly decrypted rows — no stale flag is applied. The age pill
  /// on each marker is computed from [MemberLocation.timestamp] at
  /// render time.
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
        debugPrint('[LocationService] No cached last-known rows for circle');
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
          displayName: member?.displayName ?? row.displayName,
        );
      }
      debugPrint(
        '[LocationService] Hydrated ${rows.length} cached entry(ies) for circle',
      );
    } on Object catch (e) {
      debugPrint('[LocationService] Hydration failed: ${e.runtimeType}');
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
    _lastEvolutionFetchTime.clear();
    _pendingEvictionRetries.clear();
    _hydratedCircles.clear();
    try {
      await _circleService.wipeAllLastKnownLocations();
    } on Object catch (e) {
      debugPrint('[LocationService] wipeAll failed: ${e.runtimeType}');
    }
  }

  /// Drops every in-memory cache when the app is backgrounded.
  ///
  /// The persistent SQLCipher `last_known_location` store is left
  /// untouched — it is the source of truth for the receiver's 1-day
  /// retention window. The next `fetchMemberLocations` call per circle
  /// will transparently rehydrate the in-memory cache from disk.
  ///
  /// What is cleared:
  ///  - [_locationCache] (plaintext coordinates & display names)
  ///  - [_hydratedCircles] (so rehydration re-runs on resume)
  ///  - [_seenEventIds] (a small overlap-window of events may be
  ///    re-decrypted on resume; MLS reports `PreviouslyFailed` for any
  ///    true duplicate, which the fetch loop already tolerates)
  ///
  /// What is retained:
  ///  - [_lastFetchTime] — a relay timestamp, used as the `since` cursor
  ///    for the first fetch after resume. Retaining it avoids re-pulling
  ///    the full event history.
  ///  - [_ownPubkeyHex] — a non-secret hex pubkey, retained to avoid an
  ///    FFI round-trip on resume.
  ///
  /// Safe to call repeatedly and at any point in the app lifecycle.
  void onAppPaused() {
    _pauseGeneration++;
    _locationCache.clear();
    _hydratedCircles.clear();
    _seenEventIds.clear();
    // Reset the evolution-poll cursors so resume re-fetches from the
    // clock-skew buffer rather than from before the pause (which may
    // span hours). The location-fetch cursor (_lastFetchTime) is
    // intentionally retained — see field doc.
    _lastEvolutionFetchTime.clear();
    // Deferred-eviction state is irrelevant after a cache wipe — the
    // post-resume rehydrate reconciles against the then-current roster.
    _pendingEvictionRetries.clear();
    debugPrint('[LocationService] in-memory caches cleared on pause');
  }

  /// Evicts entries from [cache] whose `expiresAt` is more than
  /// [cacheEvictionGrace] in the past.
  ///
  /// Called at the end of each fetch cycle so long-running sessions
  /// cannot accumulate plaintext location data beyond the configured
  /// grace window. Entries that are merely `isExpired` are retained
  /// (they are still useful as "last known" map markers) — eviction
  /// only removes entries that are stale enough that the persistent
  /// store would normally surface them on re-hydration anyway.
  int _evictStaleLocations(Map<String, MemberLocation> cache) {
    final cutoff = _now().subtract(cacheEvictionGrace);
    final before = cache.length;
    // Boundary is strict (`isBefore`, not `isAtOrBefore`): an entry
    // whose `expiresAt` is exactly `now - grace` is retained. This
    // keeps the semantics identical to a "within the grace window"
    // check and avoids flapping at the cutoff.
    cache.removeWhere((_, loc) => loc.expiresAt.isBefore(cutoff));
    return before - cache.length;
  }

  /// Test-only: drives [_evictStaleLocations] against a caller-supplied
  /// cache so eviction can be verified with an injected clock, without a
  /// live relay/FFI round-trip. Returns the number evicted.
  @visibleForTesting
  int evictStaleLocationsForTest(Map<String, MemberLocation> cache) =>
      _evictStaleLocations(cache);

  /// Enforces [maxSeenEventIds] as a FIFO cap on [_seenEventIds].
  ///
  /// Dart's default `Set` literal is a `LinkedHashSet`, which preserves
  /// insertion order, so `_seenEventIds.first` is always the oldest
  /// entry. Eviction is amortised O(1) per insert because we remove at
  /// most one entry for each one added.
  void _enforceSeenEventIdsCap() {
    while (_seenEventIds.length > maxSeenEventIds) {
      _seenEventIds.remove(_seenEventIds.first);
    }
  }

  /// Number of cached locations across all circles. Exposed for tests.
  @visibleForTesting
  int get debugCachedLocationCount =>
      _locationCache.values.fold<int>(0, (n, m) => n + m.length);

  /// Current size of the seen-event-ids set. Exposed for tests.
  @visibleForTesting
  int get debugSeenEventIdsCount => _seenEventIds.length;

  /// Removes every cached and persisted location for a specific circle.
  ///
  /// Called from the leave-circle / circle-deletion flow so no residual
  /// location data for former co-members remains on disk.
  Future<void> removeCircle(List<int> nostrGroupId) async {
    final circleKey = _circleKey(nostrGroupId);
    _locationCache.remove(circleKey);
    _lastFetchTime.remove(circleKey);
    _lastEvolutionFetchTime.remove(circleKey);
    _pendingEvictionRetries.remove(circleKey);
    _hydratedCircles.remove(circleKey);
    try {
      await _circleService.removeLastKnownCircle(nostrGroupId: nostrGroupId);
    } on Object catch (e) {
      debugPrint('[LocationService] removeCircle failed: ${e.runtimeType}');
    }
  }

  /// Persists a peer-decrypted location into both the in-memory cache
  /// and the SQLCipher-backed `last_known_location` store, and
  /// best-effort writes the sender's display name to the contacts
  /// table.
  ///
  /// Returns whether a contact display-name write happened so the
  /// caller can mark `contactsUpdated` for downstream refresh signals.
  /// Self-echo filtering is the caller's responsibility (the call sites
  /// already log a distinguishing "self-echo, dropped" line before
  /// hitting this helper).
  ///
  /// ## Why this is shared between fetchMemberLocations and the
  /// evolution poller
  ///
  /// Both code paths fetch the same kind-445 stream from the same
  /// relay and both mark `_seenEventIds` after a successful decrypt.
  /// Without this shared helper the two paths would race: whichever
  /// observed the event first added the ID to `_seenEventIds`, but
  /// only `fetchMemberLocations` actually persisted to
  /// `_locationCache`. When the evolution poller won the race the
  /// decrypted plaintext was silently dropped — the next
  /// `fetchMemberLocations` would short-circuit at the
  /// `_seenEventIds.contains` check and the peer's location never
  /// reached `memberLocationsProvider`. The race was symmetric for
  /// every joiner, but only surfaced visibly on a CI run with very
  /// tight evolution-poll cadence (~3-user e2e_combined scenario,
  /// strict ordering of accept_invitation → poll → fetch). See
  /// `docs/CIRCLE_CREATION_BACKLOG.md` for the original failure mode.
  Future<({bool contactWritten})> _persistDecryptedLocation({
    required Circle circle,
    required String circleKey,
    required DecryptedLocation decrypted,
    required String? ownPubkeyHex,
  }) async {
    // Look up the existing member entry — used both for the display
    // name (so the cache row carries the user-set override if any)
    // and for the `setContactDisplayNameIfAbsent` short-circuit.
    final member = circle.members
        .where((m) => m.pubkey == decrypted.senderPubkey)
        .firstOrNull;

    // Persist the sender's display name to the contacts database so
    // the member list (and any future CircleMember consumer) shows it
    // without depending on the location payload. Only writes when
    // no name is stored yet (preserves user-set overrides). Awaited
    // so the write completes before the caller refreshes the circle
    // list — otherwise the provider may re-read stale data.
    var contactWritten = false;
    final senderName = decrypted.displayName;
    if (senderName != null &&
        senderName.isNotEmpty &&
        member?.displayName == null) {
      await _circleService.setContactDisplayNameIfAbsent(
        pubkey: decrypted.senderPubkey,
        displayName: senderName,
      );
      contactWritten = true;
    }

    final location = MemberLocation(
      pubkey: decrypted.senderPubkey,
      latitude: decrypted.latitude,
      longitude: decrypted.longitude,
      geohash: decrypted.geohash,
      timestamp: decrypted.timestamp,
      expiresAt: decrypted.expiresAt,
      displayName: member?.displayName ?? decrypted.displayName,
    );

    // Persist with the fixed 1-day receiver retention window. The
    // Rust layer recomputes `purge_after` authoritatively as
    // `timestamp + LOCATION_RETENTION_SECS`; the value passed here
    // is advisory.
    final purgeAfter = decrypted.timestamp.add(const Duration(days: 1));
    try {
      await _circleService.upsertLastKnownLocation(
        nostrGroupId: circle.nostrGroupId,
        senderPubkey: decrypted.senderPubkey,
        latitude: decrypted.latitude,
        longitude: decrypted.longitude,
        geohash: decrypted.geohash,
        timestamp: decrypted.timestamp,
        expiresAt: decrypted.expiresAt,
        purgeAfter: purgeAfter,
        updatedAt: DateTime.now(),
        displayName: decrypted.displayName,
      );
    } on Object catch (e) {
      debugPrint(
        '[LocationService] upsertLastKnownLocation failed: ${e.runtimeType}',
      );
    }

    // Merge into the in-memory cache. Newer-timestamp wins.
    final cache = _locationCache.putIfAbsent(circleKey, () => {});
    final existing = cache[location.pubkey];
    if (existing == null ||
        location.timestamp.isAfter(existing.timestamp)) {
      cache[location.pubkey] = location;
    }

    return (contactWritten: contactWritten);
  }

  /// Lazily resolves and caches the local identity's pubkey hex.
  ///
  /// Both [fetchMemberLocations] and [_runEvolutionPoll] need this
  /// value to drop self-echoes before persisting. Caching avoids
  /// hitting the identity FFI on every fetch cycle.
  Future<String?> _resolveOwnPubkey() async {
    if (_ownPubkeyHex != null) return _ownPubkeyHex;
    if (_identityService == null) return null;
    try {
      final pk = await _identityService.getPubkeyHex();
      _ownPubkeyHex = pk.toLowerCase();
    } on Object catch (e) {
      debugPrint(
        '[LocationService] own pubkey lookup failed: ${e.runtimeType}',
      );
    }
    return _ownPubkeyHex;
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

    // Capture the pause generation at entry. If [onAppPaused] fires
    // across any of our `await`s below, we must abort cleanly instead
    // of refilling the caches pause just cleared. Checked after every
    // suspension point that precedes a write to persistent state
    // ([_locationCache], [_seenEventIds], [_lastFetchTime]).
    final startGen = _pauseGeneration;

    final circleKey = _circleKey(circle.nostrGroupId);
    await _hydrateFromStoreIfNeeded(circle, circleKey);
    if (_pauseGeneration != startGen) {
      return const LocationFetchResult(locations: []);
    }
    final cache = _locationCache.putIfAbsent(circleKey, () => {});

    // If a prior cycle deferred an eviction because `getMembers` failed,
    // retry it now against the currently-hydrated cache. Runs before the
    // main fetch so the UI doesn't briefly re-surface a departed member
    // after rehydration.
    await _retryDeferredEvictionIfNeeded(circle, circleKey);
    if (_pauseGeneration != startGen) {
      return const LocationFetchResult(locations: []);
    }

    // Resolve own pubkey once per process so we can skip persisting echoed
    // self-broadcasts. Cached on the service instance to avoid hitting the
    // identity FFI on every fetch cycle.
    final ownPubkeyHex = await _resolveOwnPubkey();

    // Use tracked last-fetch time if no explicit since is provided
    final effectiveSince = since ?? _lastFetchTime[circleKey];
    final fetchTime = DateTime.now();

    // Apply clock skew buffer to since timestamp
    final adjustedSince = effectiveSince?.subtract(
      const Duration(seconds: _clockSkewBufferSeconds),
    );

    // Step 1: Fetch encrypted events from relays. This is the longest
    // `await` in the method — a pause is most likely to interleave
    // here, so we re-check the generation fence immediately on return.
    final eventJsons = await _relayService.fetchGroupMessages(
      nostrGroupId: circle.nostrGroupId,
      relays: circle.relays,
      since: adjustedSince,
    );
    if (_pauseGeneration != startGen) {
      debugPrint('[LocationService] fetch aborted — paused mid-await');
      return const LocationFetchResult(locations: []);
    }

    debugPrint(
      '[LocationService] Fetched ${eventJsons.length} event(s) from '
      '${circle.relays.length} relay(s) '
      '(since=$adjustedSince, cached=${cache.length})',
    );

    // Step 2: Decrypt only new events, merge into cache.
    //
    // Sort ascending by `created_at` first so MLS commits advance the
    // local epoch before any application message that depends on the
    // advanced key. Nostr relays commonly stream newest-first, so
    // without this sort a just-after-join batch may attempt an
    // ApplicationMessage decrypt before its epoch-advancing commit —
    // the application message then fails with `PreviouslyFailed` /
    // `Unprocessable` and, under the mark-after-success dedup rule
    // below, stays eligible for retry on the next fetch. Sorting
    // resolves that in a single fetch.
    //
    // Events without a parseable `created_at` sort to the start (key
    // defaults to 0); MDK rejects malformed payloads regardless of
    // ordering. Tiebreak on original index preserves relay-provided
    // order for events that genuinely share a timestamp.
    final timestamps = <int>[
      for (final e in eventJsons) _extractCreatedAt(e) ?? 0,
    ];
    final orderedIndices = List<int>.generate(eventJsons.length, (i) => i)
      ..sort((a, b) {
        final cmp = timestamps[a].compareTo(timestamps[b]);
        return cmp != 0 ? cmp : a.compareTo(b);
      });

    var newEvents = 0;
    var skippedSeen = 0;
    var decryptNull = 0;
    var decryptFailed = 0;
    var groupUpdated = false;
    var contactsUpdated = false;
    for (final idx in orderedIndices) {
      final eventJson = eventJsons[idx];
      // Fence against pause landing mid-loop between per-event awaits.
      // Without this, a long batch could keep refilling the caches
      // pause just cleared, partially defeating the memory-bound
      // guarantee.
      if (_pauseGeneration != startGen) {
        debugPrint('[LocationService] fetch aborted — paused mid-loop');
        return const LocationFetchResult(locations: []);
      }

      // Skip already-processed events (MLS would return PreviouslyFailed).
      //
      // `_seenEventIds` is a *post-success* dedup marker — we only
      // record an event ID once decrypt has returned a non-null
      // result (see below). A pre-check with `contains` here prevents
      // the redundant MDK round-trip for events we've already
      // successfully processed, while leaving previously-failed
      // decrypts eligible for retry on the next fetch. Marking
      // pre-decrypt would blacklist out-of-order application
      // messages whose epoch-advancing commit hadn't yet been
      // processed — the classic "member joins, admin can't see their
      // location" regression.
      final eventId = _extractEventId(eventJson);
      final evtTag = _evtTag(eventId);
      if (eventId != null && _seenEventIds.contains(eventId)) {
        skippedSeen++;
        debugPrint('[LocationService] evt=$evtTag → seen (skipped)');
        continue;
      }

      try {
        final result = await _circleService.decryptLocation(
          eventJson: eventJson,
        );
        if (result == null) {
          decryptNull++;
          // Per-event reason emitted by [FFI decrypt] log (Unprocessable
          // vs PreviouslyFailed); this Dart-side line gives the high-level
          // category. Do NOT mark seen. Unprocessable / PreviouslyFailed
          // may succeed on a later fetch once the group state catches up
          // (e.g., the commit that advances the epoch arrives in a
          // subsequent batch).
          debugPrint('[LocationService] evt=$evtTag → null');
          continue;
        }

        // Track MLS group state changes (commits, proposals).
        if (result.groupUpdated) {
          groupUpdated = true;
          final autoCommit = result.evolutionEventJson != null;
          debugPrint(
            '[LocationService] evt=$evtTag → group_update '
            '(auto_commit=$autoCommit)',
          );
        }

        // Receiver-side auto-commit publish: when MDK's
        // `auto_commit_proposal` stages a pending commit in response to
        // an incoming proposal (most commonly a departing member's
        // `SelfRemove`), the decrypt FFI returns the outbound
        // `kind:445` evolution event. The remaining members owe the
        // group two things: publishing the event so everyone converges
        // on the same epoch, and locally merging via
        // `finalize_pending_commit` so this member's own MDK advances.
        // If the publish fails, roll back via `clear_pending_commit`
        // to avoid a dangling local commit that would brick future
        // message decryption. Errors are swallowed to `debugPrint`
        // because this path already races on relay connectivity — a
        // later fetch will drive retry when we see the proposal again.
        final evolutionEventJson = result.evolutionEventJson;
        final evolutionMlsGroupId = result.evolutionMlsGroupId;
        // When the decrypted event triggers an outbound evolution
        // commit but the publish fails, we clear the pending commit
        // and keep the event ID *un-seen* so the next fetch can drive
        // a retry. Mirrors whitenoise-rs's behaviour of not advancing
        // `last_synced_at` on Unprocessable / PreviouslyFailed results.
        var evolutionPublishFailed = false;
        if (evolutionEventJson != null && evolutionMlsGroupId != null) {
          var publishSucceeded = false;
          try {
            publishSucceeded = await _circleService.publishEvolutionEvent(
              eventJson: evolutionEventJson,
              relays: circle.relays,
              label: '[LocationService] receiver-side commit',
            );
          } on Object catch (e) {
            // Pre-redacted by Rust FFI; safe for developer logs. The
            // detail matters: this is the upstream path that, when it
            // fails silently and clearPendingCommit also fails below,
            // leaves a stale pending commit that later blocks operations
            // like `propose_leave` (manager.rs pre-clear is the downstream
            // safety net).
            debugPrint(
              '[LocationService] receiver-side commit publish failed: '
              '${e.runtimeType}',
            );
          }
          if (publishSucceeded) {
            try {
              await _circleService.finalizePendingCommit(evolutionMlsGroupId);
              debugPrint(
                '[LocationService] receiver-side commit finalized locally',
              );
              await _evictDepartedMembers(
                evolutionMlsGroupId: evolutionMlsGroupId,
                circle: circle,
                circleKey: circleKey,
                cache: cache,
              );
            } on Object catch (e) {
              debugPrint(
                '[LocationService] finalizePendingCommit failed: '
                '${e.runtimeType}',
              );
            }
          } else {
            evolutionPublishFailed = true;
            try {
              await _circleService.clearPendingCommit(evolutionMlsGroupId);
              debugPrint(
                '[LocationService] receiver-side commit cleared after '
                'publish failure',
              );
            } on Object catch (e) {
              // If this also fails, a stale pending commit will persist
              // across sessions and surface later as "pending commit
              // exists" on the next `propose_leave` / `remove_members` /
              // `self_update`.
              debugPrint(
                '[LocationService] clearPendingCommit failed: '
                '${e.runtimeType}',
              );
            }
          }
        }

        // Decrypt + any required evolution publish/merge succeeded —
        // mark seen so the next fetch skips this event. If publish
        // failed above we intentionally leave the ID un-seen so the
        // retry can happen on the next cycle.
        if (eventId != null && !evolutionPublishFailed) {
          _seenEventIds.add(eventId);
          _enforceSeenEventIdsCap();
        }

        final decrypted = result.location;
        if (decrypted == null) {
          // Group update with no location payload — already tracked above.
          // Still attempt avatar ingest in case this is an avatar-only chunk
          // (no location, but an MLS application message carrying avatar data).
          if (!evolutionPublishFailed) {
            final avatarComplete = await _ingestAvatar(
              eventJson: eventJson,
              circleKey: circleKey,
              mlsGroupId: circle.mlsGroupId,
            );
            if (avatarComplete) groupUpdated = true;
          }
          continue;
        }

        // Skip echoed self-broadcasts: never persist our own location to
        // the local last-known store, and never surface it on the map as
        // a peer marker. The live user pin is rendered from the fresh
        // device GPS stream elsewhere in the UI. Lowercase compare is
        // defensive — the FFI already normalises, but we do not want a
        // stray uppercase hex anywhere in the pipeline to break this.
        final senderPrefix = _evtTag(decrypted.senderPubkey);
        if (ownPubkeyHex != null &&
            decrypted.senderPubkey.toLowerCase() == ownPubkeyHex) {
          debugPrint(
            '[LocationService] evt=$evtTag → location (self-echo, dropped)',
          );
          continue;
        }
        debugPrint(
          '[LocationService] evt=$evtTag → location (sender=$senderPrefix)',
        );
        newEvents++;

        final persisted = await _persistDecryptedLocation(
          circle: circle,
          circleKey: circleKey,
          decrypted: decrypted,
          ownPubkeyHex: ownPubkeyHex,
        );
        if (persisted.contactWritten) {
          contactsUpdated = true;
        }

        // M2 avatar receive: route the same event through the avatar
        // reassembler AFTER persisting the location (so the cache entry
        // for this sender exists when _ingestAvatar updates avatarContentHash).
        // Non-avatar events are silent no-ops (accepted=false).
        if (!evolutionPublishFailed) {
          final avatarComplete = await _ingestAvatar(
            eventJson: eventJson,
            circleKey: circleKey,
            mlsGroupId: circle.mlsGroupId,
          );
          if (avatarComplete) groupUpdated = true;
        }
      } on Object catch (e) {
        decryptFailed++;
        debugPrint('[LocationService] Decrypt failed: ${e.runtimeType}');
        // Do NOT mark seen — a transient FFI error or an upstream
        // cache-write failure is worth retrying on the next poll,
        // matching the White Noise reference behaviour.
      }
    }

    debugPrint(
      '[LocationService] Results: $newEvents new, $skippedSeen seen, '
      '$decryptNull null, $decryptFailed failed'
      '${groupUpdated ? ', group updated' : ''}',
    );

    // Track fetch time for next incremental query
    _lastFetchTime[circleKey] = fetchTime;

    // Evict entries whose `expiresAt` is more than [cacheEvictionGrace]
    // in the past. Entries that are merely `isExpired` are retained so
    // the UI can surface them as "last known" markers (rendered
    // identically to live ones, with an age pill computed from
    // [MemberLocation.timestamp]). The persistent store's `purge_after`
    // column remains the long-term authority on sender-controlled
    // retention.
    final evicted = _evictStaleLocations(cache);
    if (evicted > 0) {
      debugPrint('[LocationService] Evicted $evicted stale cache entry(ies)');
    }

    // Step 3: Return all cached locations for this circle
    return LocationFetchResult(
      locations: cache.values.toList(),
      groupUpdated: groupUpdated,
      contactsUpdated: contactsUpdated,
    );
  }

  /// Per-circle retry queue for deferred eviction.
  ///
  /// When `getMembers` fails transiently after a `finalizePendingCommit`,
  /// the departed-member prune would silently drop on the floor: the
  /// commit has advanced MDK so the former member is gone from the
  /// roster, but we don't know *which* pubkeys to remove from the cache
  /// or persistent store. Stash the `evolutionMlsGroupId` here so the
  /// next fetch/poll cycle retries the prune once `getMembers` is
  /// working again. Without this, a transient FFI error leaves the
  /// departed-member's persistent `last_known_location` row to linger
  /// until `purge_after` fires (up to 1 day) — a privacy regression
  /// on a privacy-first app.
  ///
  /// Cleared on `removeCircle` / `wipeAll` / `onAppPaused` (the paused
  /// path wipes the in-memory cache anyway, so any deferred eviction
  /// becomes moot — the post-resume rehydrate will reconcile against
  /// the then-current roster).
  final Map<String, List<int>> _pendingEvictionRetries = {};

  /// Evicts cache and persistent last-known-location entries for members
  /// who are no longer in the MLS group after a finalized commit.
  ///
  /// Called immediately after [CircleService.finalizePendingCommit] succeeds.
  /// At that point MDK has advanced the local epoch, so
  /// [CircleService.getMembers] reflects the post-commit roster. Any pubkey
  /// present in [cache] but absent
  /// from that roster is a departed member whose stale pin must be removed.
  ///
  /// Both the in-memory [cache] and the persistent last-known-location store
  /// are pruned. Errors from the persistent prune are swallowed to
  /// [debugPrint] — the in-memory eviction still takes effect, bounding
  /// the visible window even if disk removal fails transiently.
  ///
  /// If `getMembers` itself fails (transient FFI error), the eviction is
  /// deferred to the next cycle via [_pendingEvictionRetries] rather than
  /// being silently dropped.
  Future<void> _evictDepartedMembers({
    required List<int> evolutionMlsGroupId,
    required Circle circle,
    required String circleKey,
    required Map<String, MemberLocation> cache,
  }) async {
    // Nothing to evict if the cache is empty.
    if (cache.isEmpty) {
      _pendingEvictionRetries.remove(circleKey);
      return;
    }

    final List<CircleMember> currentMembers;
    try {
      currentMembers = await _circleService.getMembers(evolutionMlsGroupId);
    } on Object catch (e) {
      debugPrint(
        '[LocationService] getMembers after finalize failed: ${e.runtimeType}'
        ' — deferring eviction to next cycle',
      );
      // Queue the eviction for retry on the next fetch. Use the
      // evolution MLS group ID so the retry is authoritative against
      // the circle's roster, not the stale-at-retry-time one.
      _pendingEvictionRetries[circleKey] = List<int>.from(evolutionMlsGroupId);
      return;
    }

    final currentPubkeys = {for (final m in currentMembers) m.pubkey};
    final departed = cache.keys
        .where((pk) => !currentPubkeys.contains(pk))
        .toList();

    // Retry succeeded (or had nothing to do) — clear the deferred flag.
    _pendingEvictionRetries.remove(circleKey);

    if (departed.isEmpty) return;

    for (final pubkey in departed) {
      cache.remove(pubkey);
      try {
        await _circleService.removeLastKnownMember(
          nostrGroupId: circle.nostrGroupId,
          senderPubkey: pubkey,
        );
      } on Object catch (e) {
        debugPrint(
          '[LocationService] removeLastKnownMember for departed member '
          'failed: ${e.runtimeType}',
        );
      }
    }
    debugPrint(
      '[LocationService] Evicted ${departed.length} departed member(s) '
      'from cache and persistent store',
    );
  }

  /// Retries a previously-deferred eviction for the given circle, if one
  /// is queued. Called at the start of each fetch / evolution-poll cycle
  /// per circle so a transient `getMembers` failure on cycle N is
  /// reconciled on cycle N+1.
  Future<void> _retryDeferredEvictionIfNeeded(
    Circle circle,
    String circleKey,
  ) async {
    final deferredMlsGroupId = _pendingEvictionRetries[circleKey];
    if (deferredMlsGroupId == null) return;
    final cache = _locationCache[circleKey];
    if (cache == null || cache.isEmpty) {
      _pendingEvictionRetries.remove(circleKey);
      return;
    }
    await _evictDepartedMembers(
      evolutionMlsGroupId: deferredMlsGroupId,
      circle: circle,
      circleKey: circleKey,
      cache: cache,
    );
  }

  /// Polls for evolution (kind-445 MLS commit/proposal) events across all
  /// accepted circles and routes each through the existing decrypt/process path.
  ///
  /// This method exists to advance the local MLS epoch in response to
  /// leave-commits, handoff-commits, and member-remove commits that arrive
  /// when the app is backgrounded or while the 30-second location poll is
  /// not running. Without a dedicated evolution poll the local MDK epoch can
  /// fall behind, making subsequent location messages from other members
  /// undecryptable.
  ///
  /// ## Concurrency
  ///
  /// Uses a [Future] lock ([_evolutionPollInProgress]) so that at most one
  /// poll runs at a time. A second call while a poll is in flight returns
  /// immediately without scheduling additional work.
  ///
  /// ## De-duplication
  ///
  /// Events already present in [_seenEventIds] are skipped — this shared
  /// set covers events processed by any prior location-fetch cycle, so the
  /// poller never re-pays the MDK decrypt cost for events the location
  /// timer has already handled.
  ///
  /// Returns `true` if anything was processed that warrants a downstream
  /// refresh — either an MLS group state change (commit, proposal) OR a
  /// peer location that was decrypted and persisted to the local cache
  /// via [_persistDecryptedLocation]. Returning `true` is the signal for
  /// the caller (the `evolutionPollerProvider`) to invalidate both
  /// `circlesProvider` and `memberLocationsProvider`. Returns `false`
  /// when the poll was a no-op (no new events, or only already-seen
  /// events).
  ///
  /// ## M3 — Epoch re-share hook
  ///
  /// When [onGroupUpdated] is provided and a circle's MLS group state
  /// changes (e.g. a new member joined), the callback is invoked with that
  /// circle's `mlsGroupId`. The caller (the evolution poller) uses this to
  /// trigger an avatar epoch re-share burst for the affected circle so the
  /// new joiner receives existing members' avatars promptly (§5.6).
  Future<bool> pollEvolutionEvents({
    required List<Circle> circles,
    void Function(List<int> mlsGroupId)? onGroupUpdated,
  }) async {
    if (_evolutionPollInProgress != null) {
      debugPrint('[EvolutionPoller] skipping — poll already in progress');
      return false;
    }

    final completer = Completer<bool>();
    _evolutionPollInProgress = completer.future;
    try {
      final result = await _runEvolutionPoll(
        circles: circles,
        onGroupUpdated: onGroupUpdated,
      );
      completer.complete(result);
      return result;
    } on Object catch (e) {
      debugPrint('[EvolutionPoller] unexpected error: ${e.runtimeType}');
      completer.complete(false);
      return false;
    } finally {
      _evolutionPollInProgress = null;
    }
  }

  /// In-flight evolution poll guard.
  ///
  /// Non-null while [pollEvolutionEvents] is running. A second concurrent
  /// call checks this field and returns immediately rather than starting a
  /// second poll. Reset to `null` once the poll resolves (success or error).
  Future<bool>? _evolutionPollInProgress;

  /// Per-circle last-evolution-fetch timestamp.
  ///
  /// Separate from [_lastFetchTime] (which drives the location-fetch `since`
  /// cursor) so the evolution poll can manage its own incremental window
  /// without disturbing the location cursor.
  final Map<String, DateTime> _lastEvolutionFetchTime = {};

  /// Performs the actual evolution-event fetch-and-process work.
  ///
  /// Separated from [pollEvolutionEvents] so the concurrency guard in that
  /// method can `await` this cleanly.
  ///
  /// When [onGroupUpdated] is non-null it is invoked once per circle whose
  /// MLS group state changed (any commit/proposal processed). The callback
  /// receives the circle's [Circle.mlsGroupId] (NOT the nostr group id).
  Future<bool> _runEvolutionPoll({
    required List<Circle> circles,
    void Function(List<int> mlsGroupId)? onGroupUpdated,
  }) async {
    if (circles.isEmpty) {
      debugPrint('[EvolutionPoller] no circles to poll');
      return false;
    }

    final startGen = _pauseGeneration;
    var anyGroupUpdated = false;
    // Tracks whether any location event was decrypted-and-persisted on
    // this poll cycle. Returned alongside `anyGroupUpdated` so the
    // caller can invalidate `memberLocationsProvider` even when no
    // group-state change happened. Without this, an evolution-poll
    // cycle that wins the race against `fetchMemberLocations` would
    // persist the location to the cache but never trigger the UI to
    // re-read.
    var anyLocationPersisted = false;

    // Resolve own pubkey lazily — needed by the persist helper so it
    // can drop self-echoes. Matches the resolution in
    // `fetchMemberLocations`.
    final ownPubkeyHex = await _resolveOwnPubkey();

    for (final circle in circles) {
      if (circle.membershipStatus != MembershipStatus.accepted) continue;

      // Bail out early if the app was paused mid-loop.
      if (_pauseGeneration != startGen) {
        debugPrint('[EvolutionPoller] aborted — paused mid-loop');
        return false;
      }

      final circleKey = _circleKey(circle.nostrGroupId);

      // Retry any eviction deferred by a prior cycle's `getMembers`
      // failure, symmetric with the `fetchMemberLocations` path.
      await _retryDeferredEvictionIfNeeded(circle, circleKey);
      if (_pauseGeneration != startGen) {
        debugPrint('[EvolutionPoller] aborted — paused after eviction retry');
        return false;
      }

      final lastFetch = _lastEvolutionFetchTime[circleKey];
      final adjustedSince = lastFetch?.subtract(
        const Duration(seconds: _clockSkewBufferSeconds),
      );
      final fetchTime = DateTime.now();

      List<String> eventJsons;
      try {
        eventJsons = await _relayService.fetchGroupMessages(
          nostrGroupId: circle.nostrGroupId,
          relays: circle.relays,
          since: adjustedSince,
        );
      } on Object catch (e) {
        debugPrint(
          '[EvolutionPoller] fetchGroupMessages failed for circle: '
          '${e.runtimeType}',
        );
        continue;
      }

      if (_pauseGeneration != startGen) {
        debugPrint('[EvolutionPoller] aborted — paused after fetch');
        return false;
      }

      debugPrint(
        '[EvolutionPoller] ${eventJsons.length} event(s) fetched for circle '
        '(since=$adjustedSince)',
      );

      // Sort ascending by created_at so commits precede dependent
      // application messages — mirrors the location-fetch ordering.
      final timestamps = <int>[
        for (final e in eventJsons) _extractCreatedAt(e) ?? 0,
      ];
      final orderedIndices = List<int>.generate(eventJsons.length, (i) => i)
        ..sort((a, b) {
          final cmp = timestamps[a].compareTo(timestamps[b]);
          return cmp != 0 ? cmp : a.compareTo(b);
        });

      var processed = 0;
      var skipped = 0;
      // Per-circle group-updated flag for the M3 epoch-reshare callback.
      var circleGroupUpdated = false;
      for (final idx in orderedIndices) {
        if (_pauseGeneration != startGen) {
          debugPrint('[EvolutionPoller] aborted — paused mid-event-loop');
          return false;
        }

        final eventJson = eventJsons[idx];
        final eventId = _extractEventId(eventJson);
        final evtTag = _evtTag(eventId);

        // Skip events already processed by a prior location-fetch cycle
        // or a previous evolution-poll run.
        if (eventId != null && _seenEventIds.contains(eventId)) {
          skipped++;
          debugPrint('[EvolutionPoller] evt=$evtTag → seen (skipped)');
          continue;
        }

        DecryptResult? result;
        try {
          result = await _circleService.decryptLocation(eventJson: eventJson);
        } on Object catch (e) {
          debugPrint(
            '[EvolutionPoller] evt=$evtTag → decrypt error: ${e.runtimeType}',
          );
          continue;
        }

        if (result == null) {
          debugPrint('[EvolutionPoller] evt=$evtTag → null');
          continue;
        }

        if (result.groupUpdated) {
          anyGroupUpdated = true;
          circleGroupUpdated = true;
          final autoCommit = result.evolutionEventJson != null;
          debugPrint(
            '[EvolutionPoller] evt=$evtTag → group_update '
            '(auto_commit=$autoCommit)',
          );
        } else if (result.location != null) {
          // Location decoded inside the evolution poll path — common
          // when the poller's 60-second tick beats the 30-second
          // location-fetch tick for a given event id. Persisting here
          // (rather than just logging) is mandatory: this loop and
          // `fetchMemberLocations` share `_seenEventIds`, so once
          // either marks an id seen the other short-circuits the
          // decrypt-and-persist work. Without the persist call below,
          // any event the poller observed first would be marked seen
          // but never reach `_locationCache`, and
          // `memberLocationsProvider` would never surface the peer's
          // location to the UI.
          final decrypted = result.location!;
          final senderPrefix = _evtTag(decrypted.senderPubkey);
          if (ownPubkeyHex != null &&
              decrypted.senderPubkey.toLowerCase() == ownPubkeyHex) {
            debugPrint(
              '[EvolutionPoller] evt=$evtTag → location '
              '(self-echo, dropped)',
            );
          } else {
            try {
              await _persistDecryptedLocation(
                circle: circle,
                circleKey: circleKey,
                decrypted: decrypted,
                ownPubkeyHex: ownPubkeyHex,
              );
              anyLocationPersisted = true;
              debugPrint(
                '[EvolutionPoller] evt=$evtTag → location persisted '
                '(sender=$senderPrefix)',
              );
            } on Object catch (e) {
              debugPrint(
                '[EvolutionPoller] evt=$evtTag → persist failed: '
                '${e.runtimeType}',
              );
            }
          }
        }

        // Receiver-side auto-commit: publish the outbound evolution event
        // (if any) then finalize locally — identical logic to the
        // fetchMemberLocations path. Reuses the same CircleService methods
        // rather than duplicating the plumbing.
        final evolutionEventJson = result.evolutionEventJson;
        final evolutionMlsGroupId = result.evolutionMlsGroupId;
        var evolutionPublishFailed = false;
        if (evolutionEventJson != null && evolutionMlsGroupId != null) {
          var publishSucceeded = false;
          try {
            publishSucceeded = await _circleService.publishEvolutionEvent(
              eventJson: evolutionEventJson,
              relays: circle.relays,
              label: '[EvolutionPoller] receiver-side commit',
            );
          } on Object catch (e) {
            debugPrint(
              '[EvolutionPoller] receiver-side commit publish failed: '
              '${e.runtimeType}',
            );
          }
          if (publishSucceeded) {
            try {
              await _circleService.finalizePendingCommit(evolutionMlsGroupId);
              debugPrint(
                '[EvolutionPoller] receiver-side commit finalized locally',
              );
              // After the local epoch advances, evict any cached pins for
              // members who just departed. Without this, a leave-commit
              // that arrives via the evolution poll (app backgrounded →
              // resume) leaves the ex-member's stale pin on the map
              // until the next location-fetch cycle happens to run.
              final circleCache = _locationCache[circleKey];
              if (circleCache != null) {
                await _evictDepartedMembers(
                  evolutionMlsGroupId: evolutionMlsGroupId,
                  circle: circle,
                  circleKey: circleKey,
                  cache: circleCache,
                );
              }
            } on Object catch (e) {
              debugPrint(
                '[EvolutionPoller] finalizePendingCommit failed: '
                '${e.runtimeType}',
              );
            }
          } else {
            evolutionPublishFailed = true;
            try {
              await _circleService.clearPendingCommit(evolutionMlsGroupId);
              debugPrint(
                '[EvolutionPoller] receiver-side commit cleared after '
                'publish failure',
              );
            } on Object catch (e) {
              debugPrint(
                '[EvolutionPoller] clearPendingCommit failed: '
                '${e.runtimeType}',
              );
            }
          }
        }

        // M2 avatar receive: same ingest path as fetchMemberLocations.
        if (!evolutionPublishFailed) {
          final avatarComplete = await _ingestAvatar(
            eventJson: eventJson,
            circleKey: circleKey,
            mlsGroupId: circle.mlsGroupId,
          );
          if (avatarComplete) anyGroupUpdated = true;
        }

        // Mark seen only after the full flow (decrypt + any evolution
        // publish/merge) has landed. On evolution publish failure we
        // leave the ID un-seen so the next poll cycle can drive retry.
        if (eventId != null && !evolutionPublishFailed) {
          _seenEventIds.add(eventId);
          _enforceSeenEventIdsCap();
        }

        processed++;
      }

      debugPrint(
        '[EvolutionPoller] circle done: $processed processed, '
        '$skipped already-seen',
      );

      // Advance the per-circle evolution cursor.
      _lastEvolutionFetchTime[circleKey] = fetchTime;

      // M3 epoch re-share: notify the caller that this circle had a group
      // state change (membership/epoch advance). The caller (evolutionPoller
      // provider) uses this to trigger an avatar burst re-share for this
      // specific circle so new joiners receive existing avatars promptly.
      if (circleGroupUpdated && onGroupUpdated != null) {
        onGroupUpdated(circle.mlsGroupId);
      }
    }

    // Returning true on either condition means the provider invalidates
    // BOTH `circlesProvider` (overly broad when only a location was
    // persisted) AND `memberLocationsProvider`. The over-invalidation
    // of `circlesProvider` triggers one extra `getVisibleCircles` FFI
    // call per poll cycle that persisted a location — cheap, and
    // simpler than threading a richer return type through every
    // existing test that exercises this method.
    return anyGroupUpdated || anyLocationPersisted;
  }

  /// Routes a kind-445 event through the avatar reassembler (M2 receive path).
  ///
  /// Called alongside every `decryptLocation` attempt. Non-avatar events
  /// return `accepted = false` (silent no-op). On `complete == true`, the
  /// Rust layer has stored the assembled avatar thumbnail; this method:
  ///
  /// 1. Updates the in-memory [_locationCache] entry for the sender with
  ///    the ingest result's version as the change token (stable, meaningful).
  /// 2. Fires [onAvatarComplete] so the Riverpod layer can immediately
  ///    invalidate `memberAvatarThumbnailProvider` for the affected member —
  ///    this is the primary refresh path; a member tile already on screen
  ///    (e.g. bottom sheet open) will re-fetch without waiting for dispose.
  ///
  /// [mlsGroupId] is the circle's MLS group ID bytes, needed by the callback.
  ///
  /// Returns `true` when an avatar was completed (triggers a UI refresh).
  /// Never throws — errors are swallowed to [debugPrint] so the location-
  /// fetch loop is not disrupted by avatar failures.
  Future<bool> _ingestAvatar({
    required String eventJson,
    required String circleKey,
    required List<int> mlsGroupId,
  }) async {
    try {
      final result = await _circleService.ingestIncomingAvatarMessage(
        eventJson: eventJson,
      );
      if (!result.complete) return false;
      final sender = result.senderPubkeyHex;
      if (sender == null) return false;

      // Update the in-memory cache entry. Use the ingest result version as
      // the change token — it is stable and meaningful (monotonic per sender),
      // unlike a timestamp which can repeat across restarts.
      // The explicit [onAvatarComplete] invalidation below is the primary
      // refresh path; this cache update is belt-and-suspenders for any code
      // that watches [MemberLocation.avatarContentHash] directly.
      final cache = _locationCache[circleKey];
      if (cache != null && cache.containsKey(sender)) {
        final existing = cache[sender]!;
        // Derive a stable change token from the ingest result. The full
        // content hash is not surfaced here; a short sentinel is enough to
        // signal "bytes changed — re-fetch".
        final token = result.senderPubkeyHex ?? sender;
        cache[sender] = existing.copyWith(avatarContentHash: token);
      }

      // PRIMARY refresh path: notify the Riverpod layer so it can invalidate
      // the [memberAvatarThumbnailProvider] for this (circle, member) pair
      // immediately. Without this, a member tile that is already mounted (e.g.
      // the bottom sheet is open) keeps showing stale/absent bytes until it
      // is disposed and re-built.
      try {
        onAvatarComplete?.call(mlsGroupId, sender);
      } on Object catch (e) {
        // The callback must never propagate — log and continue.
        debugPrint('[AvatarIngest] onAvatarComplete callback error: ${e.runtimeType}');
      }

      debugPrint('[AvatarIngest] avatar complete for sender prefix');
      return true;
    } on Object catch (e) {
      debugPrint('[AvatarIngest] failed: ${e.runtimeType}');
      return false;
    }
  }

  /// 8-char prefix of an event id or pubkey for diagnostic logging.
  ///
  /// Returns `'????????'` when the input is null, and pads short inputs
  /// (test fixtures, malformed events) so callers can `evt=$_evtTag(...)`
  /// unconditionally without a runtime `substring` range error. Real
  /// 64-char hex ids/pubkeys are truncated to their first 8 chars; the
  /// prefix is public on relays and carries no privacy cost.
  static String _evtTag(String? hex) {
    if (hex == null) return '????????';
    if (hex.length >= 8) return hex.substring(0, 8);
    return hex.padRight(8, '?');
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

  /// Extracts the Unix-seconds `created_at` from a Nostr event JSON.
  ///
  /// Uses a cheap linear scan rather than full JSON parsing — this
  /// runs per-event on the fetch hot path. Nostr's canonical
  /// serialization (NIP-01) has no whitespace between the colon and
  /// the integer value, so a digit-only forward scan is sufficient.
  /// Returns `null` if the field is missing or the value is not a
  /// positive integer; callers treat `null` as a sort key of 0.
  int? _extractCreatedAt(String eventJson) {
    const prefix = '"created_at":';
    final start = eventJson.indexOf(prefix);
    if (start == -1) return null;
    final valueStart = start + prefix.length;
    var end = valueStart;
    while (end < eventJson.length) {
      final c = eventJson.codeUnitAt(end);
      // 0x30..0x39 == '0'..'9'
      if (c < 0x30 || c > 0x39) break;
      end++;
    }
    if (end == valueStart) return null;
    return int.tryParse(eventJson.substring(valueStart, end));
  }

  /// Converts a `nostrGroupId` to a hex string for use as a map key.
  static String _circleKey(List<int> nostrGroupId) {
    return nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
