/// Batch refresh trigger for circle-member public profiles (M8 F2).
///
/// Anchors a single fire-and-forget batched fetch
/// (`ProfileService.refreshMemberProfiles`) that resolves every currently
/// stale/unknown pubkey passed in, then invalidates the whole
/// [memberProfileProvider] family so every mounted member tile/marker
/// re-reads the refreshed cache. Per plan §1.7/§6.2, callers MUST pass the
/// **union** of member pubkeys across every circle — never a clean
/// per-circle partition, which would hand the relay exact co-membership
/// clusters.
///
/// Non-autoDispose (the `runLeaverBackstop`-style precedent): the
/// fire-and-forget `Future` started by
/// [MemberProfileRefreshNotifier.refreshRoster] later calls
/// `ref.invalidate`, so the notifier holding that `ref` must not be
/// disposable mid-flight.
///
/// Refresh triggers (wired in a later wave): circle-select sites, app
/// resume when stale, explicit refresh affordances. No periodic timer here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

/// Notifier that owns the batched member-profile refresh trigger.
///
/// Stateless (`void`) — mirrors `MaintenanceSchedulerNotifier`. Anchor this
/// once (e.g.
/// `ref.read(memberProfileRefreshProvider.notifier)`) so its lifetime
/// matches the widget tree that needs refreshes.
class MemberProfileRefreshNotifier extends Notifier<void> {
  @override
  void build() {}

  /// Batch-refreshes [pubkeyHexes] in a single relay fetch, then invalidates
  /// the [memberProfileProvider] family.
  ///
  /// Fire-and-forget: returns immediately: the caller (e.g. a circle-select
  /// handler) must not block the UI on a relay round trip. Best-effort —
  /// failures are logged and swallowed, never rethrown, and never leave the
  /// family un-invalidated on a partial success (an empty result map from
  /// the service is still a successful call).
  void refreshRoster(List<String> pubkeyHexes, {bool force = false}) {
    if (pubkeyHexes.isEmpty) return;

    // Fire and forget — never await.
    Future(() async {
      try {
        final service = ref.read(profileServiceProvider);
        await service.refreshMemberProfiles(pubkeyHexes, force: force);
        ref.invalidate(memberProfileProvider);
        debugPrint(
          '[Profile] refreshRoster: refreshed ${pubkeyHexes.length} pubkey(s)',
        );
      } on Object catch (e) {
        debugPrint('[Profile] refreshRoster failed: ${e.runtimeType}');
      }
    });
  }
}

/// Provider owning the batched member-profile refresh trigger.
final memberProfileRefreshProvider =
    NotifierProvider<MemberProfileRefreshNotifier, void>(
      MemberProfileRefreshNotifier.new,
    );
