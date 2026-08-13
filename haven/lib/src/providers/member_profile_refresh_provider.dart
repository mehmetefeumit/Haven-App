/// Batch refresh trigger for circle-member public profiles (M8 F2).
///
/// Anchors a single fire-and-forget batched fetch
/// (`ProfileService.refreshMemberProfiles`) that resolves every currently
/// stale/unknown pubkey passed in, then invalidates the whole
/// [memberProfileProvider] family so every mounted member tile/marker
/// re-reads the refreshed cache. Per plan §1.7/§6.2, callers MUST pass the
/// **union** of member pubkeys across every circle — never a clean
/// per-circle partition, which would hand the relay exact co-membership
/// clusters. [MemberProfileRefreshNotifier.refreshAll] builds that union for
/// you and is the preferred entry point.
///
/// Non-autoDispose (the `runLeaverBackstop`-style precedent): the
/// fire-and-forget `Future` started by
/// [MemberProfileRefreshNotifier.refreshRoster] later calls
/// `ref.invalidate`, so the notifier holding that `ref` must not be
/// disposable mid-flight.
///
/// **Freshness model.** Haven holds no standing kind-0 subscription
/// (migration plan §1.6/D3), so profile updates arrive only when something
/// pulls them. Several layers do: cold start, circle select, app resume,
/// roster change, a foreground anti-entropy timer, and an explicit refresh.
/// Each states its own staleness tolerance via `maxAge`
/// (`constants/profile_refresh_tiers.dart`), so a trigger firing moments
/// after another is a cheap no-op rather than a duplicate relay round trip.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

/// Notifier that owns the batched member-profile refresh trigger.
///
/// Stateless (`void`) — mirrors `MaintenanceSchedulerNotifier`. Anchor this
/// once (e.g.
/// `ref.read(memberProfileRefreshProvider.notifier)`) so its lifetime
/// matches the widget tree that needs refreshes.
class MemberProfileRefreshNotifier extends Notifier<void> {
  /// Whether a batch is currently in flight.
  ///
  /// Triggers overlap by design (a circle select can land on top of an
  /// anti-entropy tick), and without this they would each open their own
  /// sockets to the profile relay pool for the same pubkey set.
  bool _inFlight = false;

  /// Tolerance of a request that arrived while [_inFlight], to be run once
  /// the current batch settles — `null` when nothing is queued.
  ///
  /// Coalesces to the **strictest** (smallest) pending tolerance, so a forced
  /// refresh arriving during a lazy periodic sweep still forces afterward
  /// instead of being swallowed.
  Duration? _queuedMaxAge;

  /// Union of the rosters requested while [_inFlight].
  ///
  /// The queued follow-up MUST NOT reuse the in-flight call's roster: a
  /// roster-change trigger (invite accepted, live-sync `GroupUpdate`) that
  /// lands mid-flight carries pubkeys the running batch has never seen, and
  /// reusing the older list would silently drop the new member until some
  /// unrelated trigger fired up to ~45 min later — defeating the roster-change
  /// trigger entirely. Merged (never replaced) so no coalesced request loses
  /// members.
  final Set<String> _queuedPubkeys = {};

  /// Set once this notifier is torn down (logout invalidates it before the MLS
  /// wipe). Checked before the FFI call and before starting a queued follow-up
  /// so no kind-0 REQ for the deleted identity's social graph can be issued
  /// after the user asked for it to be erased.
  bool _disposed = false;

  @override
  void build() {
    _disposed = false;
    _inFlight = false;
    _queuedMaxAge = null;
    _queuedPubkeys.clear();
    ref.onDispose(() => _disposed = true);
  }

  /// Refreshes the union of every circle's members plus the user's own
  /// pubkey, then invalidates the profile providers.
  ///
  /// This is the entry point every trigger should use: it builds the
  /// all-circles union required by plan §1.7 rather than leaving each call
  /// site to get that right. Pass [circles] when the caller already has them
  /// (avoids a redundant read); otherwise they are resolved from
  /// [circlesProvider].
  ///
  /// Own profile rides the same batch instead of a separate forced
  /// `fetch_my_profile`, so a refresh costs one relay round trip, not two.
  Future<void> refreshAll({
    required Duration maxAge,
    List<Circle>? circles,
  }) async {
    if (!publicProfilesEnabled) return;
    if (_disposed) return;

    final resolved = circles ?? await _readCircles();
    final pubkeys = <String>{
      for (final circle in resolved)
        for (final member in circle.members) member.pubkey,
    };

    // Own profile is fetched in the same batch as the roster. It is also the
    // reason this may be non-empty with no circles yet.
    final ownPubkey = await _readOwnPubkey();
    if (ownPubkey != null) pubkeys.add(ownPubkey);

    refreshRoster(pubkeys.toList(), maxAge: maxAge);
  }

  /// Batch-refreshes [pubkeyHexes] in a single relay fetch, then invalidates
  /// the [memberProfileProvider] family and [ownProfileProvider].
  ///
  /// Fire-and-forget: returns immediately: the caller (e.g. a circle-select
  /// handler) must not block the UI on a relay round trip. Best-effort —
  /// failures are logged and swallowed, never rethrown, and never leave the
  /// family un-invalidated on a partial success (an empty result map from
  /// the service is still a successful call).
  ///
  /// [maxAge] is the staleness tolerance; pick a tier from
  /// `constants/profile_refresh_tiers.dart`. Concurrent calls coalesce (see
  /// [_inFlight]).
  ///
  /// Prefer [refreshAll]: this takes an arbitrary pubkey list, so calling it
  /// with one circle's roster would leak an exact co-membership cluster to the
  /// relay (§1.7). A CI guard
  /// (`scripts/ci/check_profile_privacy_boundaries.sh`) fails the build if this
  /// is called from anywhere under `haven/lib` except this file.
  @visibleForTesting
  void refreshRoster(
    List<String> pubkeyHexes, {
    Duration maxAge = profileInteractiveMaxAge,
  }) {
    if (!publicProfilesEnabled) return;
    if (_disposed) return;
    if (pubkeyHexes.isEmpty) return;

    if (_inFlight) {
      // Keep the strictest pending tolerance so a force is never downgraded
      // to (or swallowed by) a lazier in-flight sweep, and merge the roster so
      // members discovered mid-flight are not dropped.
      final queued = _queuedMaxAge;
      _queuedMaxAge = queued == null || maxAge < queued ? maxAge : queued;
      _queuedPubkeys.addAll(pubkeyHexes);
      return;
    }
    _inFlight = true;

    // Fire and forget — never await.
    Future(() async {
      try {
        // Re-check: teardown can land between scheduling and running.
        if (_disposed) return;
        final service = ref.read(profileServiceProvider);
        await service.refreshMemberProfiles(pubkeyHexes, maxAge: maxAge);
        ref
          ..invalidate(memberProfileProvider)
          ..invalidate(ownProfileProvider);
        debugPrint(
          '[Profile] refreshRoster: refreshed ${pubkeyHexes.length} pubkey(s)',
        );
      } on Object catch (e) {
        debugPrint('[Profile] refreshRoster failed: ${e.runtimeType}');
      } finally {
        _inFlight = false;
        final queued = _queuedMaxAge;
        final queuedRoster = _queuedPubkeys.toList();
        _queuedMaxAge = null;
        _queuedPubkeys.clear();
        if (queued != null) {
          // Run the coalesced follow-up once, over the roster the queued
          // trigger(s) actually asked for — NOT this batch's list, which
          // predates any member discovered mid-flight. A failed batch still
          // drains the queue so a wedged relay cannot build a retry backlog.
          refreshRoster(queuedRoster, maxAge: queued);
        }
      }
    });
  }

  /// Reads the current circle list, tolerating a not-yet-loaded/failed
  /// provider — a refresh is best-effort and must never throw to its trigger.
  Future<List<Circle>> _readCircles() async {
    try {
      return await ref.read(circlesProvider.future);
    } on Object catch (e) {
      debugPrint(
        '[Profile] refreshAll: circles unavailable (${e.runtimeType})',
      );
      return const [];
    }
  }

  /// Reads the own pubkey hex, or `null` when no identity exists yet.
  Future<String?> _readOwnPubkey() async {
    try {
      final identity = await ref.read(identityProvider.future);
      return identity?.pubkeyHex;
    } on Object catch (e) {
      debugPrint(
        '[Profile] refreshAll: identity unavailable (${e.runtimeType})',
      );
      return null;
    }
  }
}

/// Provider owning the batched member-profile refresh trigger.
final memberProfileRefreshProvider =
    NotifierProvider<MemberProfileRefreshNotifier, void>(
      MemberProfileRefreshNotifier.new,
    );
