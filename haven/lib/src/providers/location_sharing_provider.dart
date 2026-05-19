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

/// Per-circle pending-departure reason from MDK's `IgnoredProposal`.
///
/// Keyed internally by hex-encoded `nostrGroupId`. A non-null value
/// means MDK silently refused to apply a proposal for that circle
/// (most commonly an admin's SelfRemove dropped by MDK's admin-gate) —
/// the UI should render a "Leaving…" banner and surface an admin
/// Remove-member affordance so the leaver can be evicted via a
/// RemoveMember commit that bypasses MDK's SelfRemove gate. See
/// `docs/ADMIN_LEAVE_GHOST_BUG.md` for the full trip path.
///
/// Stored outside the `FutureProvider<List<MemberLocation>>` because
/// the fetch's primary job is to return locations; the Ignored signal
/// is an orthogonal circle-level fact that widgets (header banner,
/// member tiles) subscribe to independently.
class PendingDepartureNotifier extends StateNotifier<Map<String, String>> {
  /// Creates a [PendingDepartureNotifier] with no pending departures.
  PendingDepartureNotifier() : super(const {});

  /// Converts a raw `nostrGroupId` byte list to the lowercase-hex key
  /// used to index the state map. Exposed for UI consumers that watch
  /// the map directly (e.g. via `ref.watch(pendingDepartureProvider)`)
  /// and need to look up the reason for a specific circle.
  static String hexKey(List<int> nostrGroupId) {
    return nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Records a pending departure for the circle identified by
  /// [nostrGroupId] with MDK's [reason] string.
  void set({required List<int> nostrGroupId, required String reason}) {
    final key = hexKey(nostrGroupId);
    if (state[key] == reason) return;
    state = {...state, key: reason};
  }

  /// Clears any pending departure for [nostrGroupId]. Called after the
  /// admin publishes a RemoveMember commit so the leaver stops being
  /// flagged on future fetches.
  void clear(List<int> nostrGroupId) {
    final key = hexKey(nostrGroupId);
    if (!state.containsKey(key)) return;
    final next = Map<String, String>.of(state)..remove(key);
    state = next;
  }

  /// Clears all pending-departure signals (e.g., on sign-out).
  void reset() {
    if (state.isEmpty) return;
    state = const {};
  }

  /// Convenience lookup for the reason attached to [nostrGroupId], or
  /// `null` if no pending departure is recorded for that circle.
  String? reasonFor(List<int> nostrGroupId) => state[hexKey(nostrGroupId)];
}

/// Provider for per-circle pending-departure state.
final pendingDepartureProvider =
    StateNotifierProvider<PendingDepartureNotifier, Map<String, String>>(
      (ref) => PendingDepartureNotifier(),
    );

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

    // MDK returned an IgnoredProposal during this fetch — record the
    // reason so UI can render the "Leaving…" banner and the admin
    // Remove-member affordance. Only clear the pending signal via the
    // explicit admin removeMember success path (see _confirmRemoveMember
    // in circles_bottom_sheet.dart); any `groupUpdated` here could be an
    // unrelated commit (add-member, handoff, another member's successful
    // self-remove) and would falsely dismiss the ghost-admin banner.
    final pendingNotifier = ref.read(pendingDepartureProvider.notifier);
    final reason = result.pendingDepartureReason;
    if (reason != null) {
      pendingNotifier.set(nostrGroupId: circle.nostrGroupId, reason: reason);
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
  debugPrint('[LocationPublish] Identity loaded');

  final displayName = await ref.read(displayNameProvider.future);

  final service = ref.read(locationSharingServiceProvider);
  final circleService = ref.read(circleServiceProvider);
  final locationService = ref.read(locationServiceProvider);

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
            displayName: displayName,
          );
          debugPrint(
            '[LocationPublish] Published — '
            'accepted=${result.acceptedBy.length}, '
            'rejected=${result.rejectedBy.length}, '
            'failed=${result.failed.length}',
          );
          if (result.rejectedBy.isNotEmpty) {
            for (final r in result.rejectedBy) {
              debugPrint('[LocationPublish] REJECTED by relay: ${r.reason}');
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
