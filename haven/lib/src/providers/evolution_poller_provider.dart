/// Provider for polling MLS evolution (kind-445 commit/proposal) events.
///
/// A dedicated poll cadence that is decoupled from the 30-second location
/// timer so that leave-commits, handoff-commits, and member-remove commits
/// are processed promptly regardless of whether a location fetch happens to
/// be in flight. Without this poller the local MDK epoch can fall behind,
/// making subsequent location messages from other members undecryptable.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

/// Fetches kind-445 evolution events for every accepted circle and routes
/// them through the existing decrypt/publish/finalize pipeline.
///
/// Returns `true` if any MLS group state change (commit, proposal) was
/// processed — callers should refresh [circlesProvider] in that case so
/// the member roster stays current.
///
/// Trigger via:
/// ```dart
/// ref
///   ..invalidate(evolutionPollerProvider)
///   ..read(evolutionPollerProvider);
/// ```
///
/// This pattern mirrors how `invitationPollerProvider` and
/// `selfUpdateProvider` are triggered throughout the app.
final evolutionPollerProvider = FutureProvider<bool>((ref) async {
  final circleService = ref.read(circleServiceProvider);
  final locationSharingService = ref.read(locationSharingServiceProvider);

  List<Circle> circles;
  try {
    circles = await circleService.getVisibleCircles();
  } on Object catch (e) {
    debugPrint('[EvolutionPoller] getVisibleCircles failed: ${e.runtimeType}');
    return false;
  }

  final accepted = circles
      .where((c) => c.membershipStatus == MembershipStatus.accepted)
      .toList();

  if (accepted.isEmpty) {
    debugPrint('[EvolutionPoller] no accepted circles — skipping');
    return false;
  }

  debugPrint('[EvolutionPoller] polling ${accepted.length} accepted circle(s)');

  try {
    final groupUpdated = await locationSharingService.pollEvolutionEvents(
      circles: accepted,
    );

    if (groupUpdated) {
      debugPrint(
        '[EvolutionPoller] group state changed — '
        'invalidating circles + locations',
      );
      // Cross-invalidate memberLocations so a newly-detected member's
      // first location is fetched immediately rather than on the next
      // 30 s location-poll tick.
      ref
        ..invalidate(circlesProvider)
        ..invalidate(memberLocationsProvider);
    }

    return groupUpdated;
  } on Object catch (e) {
    debugPrint(
      '[EvolutionPoller] pollEvolutionEvents failed: ${e.runtimeType}',
    );
    return false;
  }
});
