/// Location sharing service.
///
/// Orchestrates the encrypt-publish-fetch-decrypt pipeline for sharing
/// location data with circle members via MLS-encrypted Nostr events.
library;

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
    required this.precision,
    this.displayName,
    this.retentionSecs = 0,
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

  /// Whether this location's freshness window has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Returns a copy with the given fields overridden.
  MemberLocation copyWith({String? displayName}) {
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
class LocationSharingService {
  /// Creates a [LocationSharingService].
  ///
  /// [maxSeenEventIds] and [cacheEvictionGrace] are exposed for tests
  /// to exercise eviction behaviour at small scales. Production code
  /// should accept the defaults.
  LocationSharingService({
    required CircleService circleService,
    required RelayService relayService,
    IdentityService? identityService,
    this.maxSeenEventIds = _defaultMaxSeenEventIds,
    this.cacheEvictionGrace = _defaultCacheEvictionGrace,
  }) : assert(maxSeenEventIds > 0, 'maxSeenEventIds must be positive'),
       assert(
         cacheEvictionGrace >= Duration.zero,
         'cacheEvictionGrace must be non-negative',
       ),
       _circleService = circleService,
       _relayService = relayService,
       _identityService = identityService;

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
          precision: row.precision,
          displayName: member?.displayName ?? row.displayName,
          retentionSecs: row.retentionSecs,
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
  /// untouched — it is the source of truth for sender-controlled
  /// retention. The next `fetchMemberLocations` call per circle will
  /// transparently rehydrate the in-memory cache from disk.
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
    final cutoff = DateTime.now().subtract(cacheEvictionGrace);
    final before = cache.length;
    // Boundary is strict (`isBefore`, not `isAtOrBefore`): an entry
    // whose `expiresAt` is exactly `now - grace` is retained. This
    // keeps the semantics identical to a "within the grace window"
    // check and avoids flapping at the cutoff.
    cache.removeWhere((_, loc) => loc.expiresAt.isBefore(cutoff));
    return before - cache.length;
  }

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
    _hydratedCircles.remove(circleKey);
    try {
      await _circleService.removeLastKnownCircle(nostrGroupId: nostrGroupId);
    } on Object catch (e) {
      debugPrint('[LocationService] removeCircle failed: ${e.runtimeType}');
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

    // Resolve own pubkey once per process so we can skip persisting echoed
    // self-broadcasts. Cached on the service instance to avoid hitting the
    // identity FFI on every fetch cycle.
    if (_ownPubkeyHex == null && _identityService != null) {
      try {
        final pk = await _identityService.getPubkeyHex();
        _ownPubkeyHex = pk.toLowerCase();
      } on Object catch (e) {
        debugPrint(
          '[LocationService] own pubkey lookup failed: ${e.runtimeType}',
        );
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
      if (eventId != null && _seenEventIds.contains(eventId)) {
        skippedSeen++;
        continue;
      }

      try {
        final result = await _circleService.decryptLocation(
          eventJson: eventJson,
        );
        if (result == null) {
          decryptNull++;
          // Do NOT mark seen. Unprocessable / PreviouslyFailed may
          // succeed on a later fetch once the group state catches up
          // (e.g., the commit that advances the epoch arrives in a
          // subsequent batch).
          continue;
        }

        // Decrypt succeeded (Commit, Proposal, or ApplicationMessage).
        // Mark seen *now*, before any of the cache-write awaits below —
        // those have their own try/catch, but we still want to avoid
        // re-paying the MDK decrypt cost if a later write throws.
        if (eventId != null) {
          _seenEventIds.add(eventId);
          _enforceSeenEventIdsCap();
        }

        // Track MLS group state changes (commits, proposals).
        if (result.groupUpdated) {
          groupUpdated = true;
          debugPrint('[LocationService] MLS group update processed for circle');
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
            debugPrint(
              '[LocationService] removeLastKnownMember failed: ${e.runtimeType}',
            );
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
            debugPrint(
              '[LocationService] upsertLastKnownLocation failed: ${e.runtimeType}',
            );
          }
        }

        // Update cache if this is newer than the existing entry.
        final existing = cache[location.pubkey];
        if (existing == null ||
            location.timestamp.isAfter(existing.timestamp)) {
          cache[location.pubkey] = location;
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
