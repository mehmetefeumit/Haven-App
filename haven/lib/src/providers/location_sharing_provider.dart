/// Providers for location sharing state.
///
/// Provides reactive access to member locations for the selected circle
/// and periodic publishing/polling of location data.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_precision_provider.dart';
import 'package:haven/src/providers/sender_retention_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/widgets/security/privacy_chip.dart';

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
      '[LocationFetch] Circle not accepted (status=${circle.membershipStatus})',
    );
    return [];
  }

  final identity = await ref.read(identityProvider.future);

  debugPrint(
    '[LocationFetch] Fetching locations (${circle.relays.length} relays)',
  );

  final service = ref.read(locationSharingServiceProvider);
  try {
    final result = await service.fetchMemberLocations(circle: circle);

    // When an MLS commit/proposal was processed (e.g., new member joined)
    // or new contact display names were learned from location messages,
    // refresh the circle list so selectedCircleProvider picks up the
    // updated member roster and names on the next evaluation.
    if (result.groupUpdated || result.contactsUpdated) {
      debugPrint(
        '[LocationFetch] Refreshing circles '
        '(groupUpdated=${result.groupUpdated}, '
        'contactsUpdated=${result.contactsUpdated})',
      );
      ref.invalidate(circlesProvider);
    }

    // Exclude the current user's own location — it is already shown
    // from on-device GPS via UserLocationMarker.
    final locations = result.locations;
    final otherMembers = identity == null
        ? locations
        : locations.where((loc) => loc.pubkey != identity.pubkeyHex).toList();
    debugPrint(
      '[LocationFetch] Got ${locations.length} member location(s), '
      'showing ${otherMembers.length} (excluding self)',
    );
    return otherMembers;
  } on Object catch (e) {
    debugPrint('[LocationFetch] FAILED: ${e.runtimeType}');
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

  final displayName = await ref.read(displayNameProvider.future);

  final service = ref.read(locationSharingServiceProvider);
  final circleService = ref.read(circleServiceProvider);
  final locationService = ref.read(locationServiceProvider);

  // Sender-controlled retention preference (seconds). Embedded in
  // every encrypted LocationMessage so receivers know how long to keep
  // our last-known-location row after we go offline. `0` is the
  // "do not store" sentinel.
  final retentionSecs = ref.read(senderRetentionProvider);

  // Location precision preference. Maps to the Rust `LocationPrecision`
  // enum via the FFI label string. A `null` label means the user chose
  // "hidden" (stealth mode) — skip GPS acquisition entirely.
  final precision = ref.read(locationPrecisionProvider);
  final precisionLabel = precision.ffiLabel;
  if (precisionLabel == null) {
    debugPrint('[LocationPublish] Precision is hidden — skipping');
    return 0;
  }

  try {
    final position = await locationService.getCurrentLocation();
    debugPrint('[LocationPublish] GPS fix acquired');

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

    // Publish to all accepted circles in parallel — each circle uses
    // a different MLS group, so encrypt+publish operations are independent.
    final results = await Future.wait(
      accepted.map((circle) async {
        debugPrint(
          '[LocationPublish] Encrypting (${circle.relays.length} relays)',
        );
        try {
          final result = await service.publishLocation(
            mlsGroupId: circle.mlsGroupId,
            senderPubkeyHex: identity.pubkeyHex,
            latitude: position.latitude,
            longitude: position.longitude,
            retentionSecs: retentionSecs,
            displayName: displayName,
            precisionLabel: precisionLabel,
          );
          debugPrint(
            '[LocationPublish] Published — '
            'accepted=${result.acceptedBy.length}, '
            'rejected=${result.rejectedBy.length}, '
            'failed=${result.failed.length}',
          );
          if (result.rejectedBy.isNotEmpty) {
            for (final r in result.rejectedBy) {
              debugPrint(
                '[LocationPublish] REJECTED by relay: ${r.reason}',
              );
            }
          }
          if (result.failed.isNotEmpty) {
            debugPrint(
              '[LocationPublish] FAILED relays: ${result.failed.length}',
            );
          }
          return 1;
        } on Object catch (_) {
          debugPrint('[LocationPublish] Publish failed for circle');
          return 0;
        }
      }),
    );

    return results.fold<int>(0, (sum, v) => sum + v);
  } on Object catch (e) {
    debugPrint('[LocationPublish] FAILED: ${e.runtimeType}');
    return 0;
  }
});
