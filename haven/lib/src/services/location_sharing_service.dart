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
    this.pendingDepartureReason,
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

  /// Reason string from MDK when this circle has a proposal MDK
  /// ignored (e.g. admin-SelfRemove dropped by MDK's admin-gate).
  ///
  /// When non-null, the circle has a member who attempted to leave but
  /// whose proposal MDK silently refused to apply. The UI should
  /// surface a "Leaving…" banner and offer an admin "Remove member"
  /// affordance to evict the departing admin via a RemoveMember commit
  /// that bypasses MDK's SelfRemove gate. See
  /// `docs/ADMIN_LEAVE_GHOST_BUG.md` for the full bug trip path.
  ///
  /// Because MDK's `IgnoredProposal` result does not carry a sender
  /// pubkey, this is a circle-level signal rather than per-member.
  final String? pendingDepartureReason;

  /// Whether this circle currently has an MDK-ignored proposal pending.
  bool get hasPendingDeparture => pendingDepartureReason != null;
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
  /// [precisionLabel] is the Rust `LocationPrecision` label string.
  /// When `null`, the Rust core defaults to `Enhanced` (~1.1 m).
  ///
  /// Returns the publish result.
  Future<PublishResult> publishLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
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
    _lastEvolutionFetchTime.remove(circleKey);
    _pendingEvictionRetries.remove(circleKey);
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
    // Latest MDK "IgnoredProposal" reason observed during this fetch.
    // Non-null means MDK refused to apply a proposal (most commonly an
    // admin's SelfRemove dropped by MDK's admin-gate). The circle-level
    // signal drives the UI "Leaving…" banner and the admin "Remove
    // member" affordance — see `docs/ADMIN_LEAVE_GHOST_BUG.md`.
    String? pendingDepartureReason;
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

        // MDK refused to apply this proposal (e.g. admin-SelfRemove
        // dropped by MDK's admin-gate, or an epoch-stale proposal).
        // Surface the reason so the UI can render a "Leaving…" banner
        // and offer an admin Remove-member affordance, and crucially
        // do NOT add the event id to `_seenEventIds`: the ignored
        // proposal needs to be re-examined on every fetch until an
        // admin publishes a RemoveMember commit that evicts the
        // leaver. See `docs/ADMIN_LEAVE_GHOST_BUG.md`.
        if (result.isIgnored) {
          pendingDepartureReason = result.ignoredReason;
          debugPrint(
            '[LocationService] MDK ignored proposal for circle: '
            '${result.ignoredReason}',
          );
          continue;
        }

        // Track MLS group state changes (commits, proposals).
        if (result.groupUpdated) {
          groupUpdated = true;
          debugPrint('[LocationService] MLS group update processed for circle');
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
              '[LocationService] receiver-side commit publish failed: $e',
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
                '[LocationService] finalizePendingCommit failed: $e',
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
                '[LocationService] clearPendingCommit failed: $e',
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

        final location = MemberLocation(
          pubkey: decrypted.senderPubkey,
          latitude: decrypted.latitude,
          longitude: decrypted.longitude,
          geohash: decrypted.geohash,
          timestamp: decrypted.timestamp,
          expiresAt: decrypted.expiresAt,
          precision: decrypted.precision,
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
            precision: decrypted.precision,
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
      pendingDepartureReason: pendingDepartureReason,
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
  /// Returns `true` if any MLS group state change was processed (so callers
  /// can optionally refresh the circle list), `false` otherwise.
  Future<bool> pollEvolutionEvents({required List<Circle> circles}) async {
    if (_evolutionPollInProgress != null) {
      debugPrint('[EvolutionPoller] skipping — poll already in progress');
      return false;
    }

    final completer = Completer<bool>();
    _evolutionPollInProgress = completer.future;
    try {
      final result = await _runEvolutionPoll(circles: circles);
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
  Future<bool> _runEvolutionPoll({required List<Circle> circles}) async {
    if (circles.isEmpty) {
      debugPrint('[EvolutionPoller] no circles to poll');
      return false;
    }

    final startGen = _pauseGeneration;
    var anyGroupUpdated = false;

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
      for (final idx in orderedIndices) {
        if (_pauseGeneration != startGen) {
          debugPrint('[EvolutionPoller] aborted — paused mid-event-loop');
          return false;
        }

        final eventJson = eventJsons[idx];
        final eventId = _extractEventId(eventJson);

        // Skip events already processed by a prior location-fetch cycle
        // or a previous evolution-poll run.
        if (eventId != null && _seenEventIds.contains(eventId)) {
          skipped++;
          continue;
        }

        DecryptResult? result;
        try {
          result = await _circleService.decryptLocation(eventJson: eventJson);
        } on Object catch (e) {
          debugPrint(
            '[EvolutionPoller] decryptLocation failed: ${e.runtimeType}',
          );
          continue;
        }

        if (result == null) continue;

        // MDK ignored the proposal (Mode A ghost-admin or Mode B WrongEpoch
        // race). Skip the seen-set add so the next poll cycle can re-route
        // the event through decrypt once the circle advances to a new epoch.
        // See docs/ADMIN_LEAVE_GHOST_BUG.md.
        if (result.isIgnored) {
          debugPrint(
            '[EvolutionPoller] MDK ignored proposal — not marking seen',
          );
          continue;
        }

        if (result.groupUpdated) {
          anyGroupUpdated = true;
          debugPrint('[EvolutionPoller] MLS group update processed');
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
    }

    return anyGroupUpdated;
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
