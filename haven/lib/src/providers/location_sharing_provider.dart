/// Providers for location sharing state.
///
/// Provides reactive access to member locations for the selected circle
/// and periodic publishing/polling of location data.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

/// Provider for member locations in the currently selected circle.
///
/// Re-evaluates when the selected circle changes or when invalidated.
/// Returns an empty list if no circle is selected or the user hasn't
/// accepted membership.
final memberLocationsProvider = FutureProvider<List<MemberLocation>>((
  ref,
) async {
  final circle = ref.watch(selectedCircleProvider);
  if (circle == null) {
    debugPrint('[LocationFetch] No circle selected');
    return [];
  }
  if (circle.membershipStatus != MembershipStatus.accepted) {
    debugPrint(
      '[LocationFetch] Circle "${circle.displayName}" '
      'status=${circle.membershipStatus} (not accepted)',
    );
    return [];
  }

  debugPrint(
    '[LocationFetch] Fetching locations for "${circle.displayName}" '
    '(${circle.relays.length} relays: ${circle.relays.join(", ")})',
  );

  final service = ref.read(locationSharingServiceProvider);
  try {
    final locations = await service.fetchMemberLocations(circle: circle);
    debugPrint('[LocationFetch] Got ${locations.length} member location(s)');
    return locations;
  } on Object catch (e) {
    debugPrint('[LocationFetch] FAILED: $e');
    return [];
  }
});

/// Publishes the user's current location to all accepted circles.
///
/// Designed to be called periodically (e.g., every 5 minutes) or on
/// manual refresh. Returns the number of circles published to.
final locationPublisherProvider = FutureProvider<int>((ref) async {
  debugPrint('[LocationPublish] Provider executing...');

  final identity = await ref.read(identityProvider.future);
  if (identity == null) {
    debugPrint('[LocationPublish] No identity — skipping');
    return 0;
  }
  debugPrint(
    '[LocationPublish] Identity: ${identity.npub.substring(0, 20)}...',
  );

  final service = ref.read(locationSharingServiceProvider);
  final circleService = ref.read(circleServiceProvider);
  final locationService = ref.read(locationServiceProvider);

  try {
    final position = await locationService.getCurrentLocation();
    debugPrint(
      '[LocationPublish] GPS: (${position.latitude}, ${position.longitude})',
    );

    final circles = await circleService.getVisibleCircles();
    final accepted = circles
        .where((c) => c.membershipStatus == MembershipStatus.accepted)
        .toList();

    debugPrint(
      '[LocationPublish] ${circles.length} visible circle(s), '
      '${accepted.length} accepted',
    );

    if (accepted.isEmpty) {
      debugPrint('[LocationPublish] No accepted circles to publish to');
      return 0;
    }

    var count = 0;
    for (final circle in accepted) {
      debugPrint(
        '[LocationPublish] Encrypting for "${circle.displayName}" '
        '(${circle.relays.length} relays: ${circle.relays.join(", ")})',
      );
      try {
        final result = await service.publishLocation(
          mlsGroupId: circle.mlsGroupId,
          senderPubkeyHex: identity.pubkeyHex,
          latitude: position.latitude,
          longitude: position.longitude,
        );
        debugPrint(
          '[LocationPublish] Published to "${circle.displayName}" — '
          'accepted=${result.acceptedBy.length}, '
          'rejected=${result.rejectedBy.length}, '
          'failed=${result.failed.length}',
        );
        if (result.rejectedBy.isNotEmpty) {
          for (final r in result.rejectedBy) {
            debugPrint('[LocationPublish] REJECTED by ${r.relay}: ${r.reason}');
          }
        }
        if (result.failed.isNotEmpty) {
          debugPrint(
            '[LocationPublish] FAILED relays: ${result.failed.join(", ")}',
          );
        }
        count++;
      } on Object catch (e) {
        debugPrint('[LocationPublish] FAILED for "${circle.displayName}": $e');
      }
    }

    return count;
  } on Object catch (e) {
    debugPrint('[LocationPublish] FAILED: $e');
    return 0;
  }
});
