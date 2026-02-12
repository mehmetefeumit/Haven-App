/// Providers for location sharing state.
///
/// Provides reactive access to member locations for the selected circle
/// and periodic publishing/polling of location data.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
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
  if (circle == null || circle.membershipStatus != MembershipStatus.accepted) {
    return [];
  }

  final service = ref.read(locationSharingServiceProvider);
  try {
    return await service.fetchMemberLocations(circle: circle);
  } on Object catch (e) {
    debugPrint('Failed to fetch member locations');
    return [];
  }
});

/// Publishes the user's current location to all accepted circles.
///
/// Designed to be called periodically (e.g., every 5 minutes) or on
/// manual refresh. Returns the number of circles published to.
final locationPublisherProvider = FutureProvider<int>((ref) async {
  final identity = await ref.read(identityProvider.future);
  if (identity == null) return 0;

  final position = ref.read(locationStreamProvider).valueOrNull;
  if (position == null) return 0;

  final service = ref.read(locationSharingServiceProvider);
  final circleService = ref.read(circleServiceProvider);

  try {
    final circles = await circleService.getVisibleCircles();
    final accepted = circles
        .where((c) => c.membershipStatus == MembershipStatus.accepted)
        .toList();

    var count = 0;
    for (final circle in accepted) {
      try {
        await service.publishLocation(
          mlsGroupId: circle.mlsGroupId,
          senderPubkeyHex: identity.pubkeyHex,
          latitude: position.latitude,
          longitude: position.longitude,
        );
        count++;
      } on Object catch (e) {
        debugPrint('Failed to publish to circle');
      }
    }

    return count;
  } on Object catch (e) {
    debugPrint('Location publishing failed');
    return 0;
  }
});
