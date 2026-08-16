/// Admin-initiated member removal for the circle member list.
///
/// Owns the one piece of state the member list cannot derive from the roster:
/// whether a removal is currently in flight, and for whom. The list reads it
/// to render the affected row's progress and to disable every other row's
/// remove action — a removal stages an MLS commit, and two staged at once on
/// the same group race each other, where the loser's publish is refused and
/// its pending state rolled back (Security Rule 13). One at a time is the
/// contract; this notifier is where it is enforced rather than assumed.
///
/// Kept out of the widget so the decision layer is testable without pumping
/// a sheet: `remove()` takes plain values and returns a typed outcome.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

/// What one call to [MemberRemovalController.remove] did.
///
/// Presence-only by design: the failure arm carries no message, because the
/// only failures available here are FFI/relay errors whose text can name an
/// MLS group id (Security Rule 8). The caller renders fixed copy.
enum MemberRemovalOutcome {
  /// The commit was staged, published, acked by at least one relay and
  /// finalized locally — the member is out of the group.
  removed,

  /// Nothing changed. The service rolls its pending commit back on any
  /// failure, so this is a genuine no-op rather than an unknown state.
  failed,

  /// Another removal was already in flight, so this one was not attempted.
  /// The UI disables the affordance while that is true, so reaching this is
  /// a lost race, not a normal path.
  busy,
}

/// Tracks the member pubkey whose removal is in flight, or `null` when idle.
final memberRemovalProvider =
    NotifierProvider<MemberRemovalController, String?>(
      MemberRemovalController.new,
    );

/// Serialises admin member removals and reports their outcome.
class MemberRemovalController extends Notifier<String?> {
  @override
  String? build() => null;

  /// Removes [memberPubkeyHex] from [circle].
  ///
  /// Returns [MemberRemovalOutcome.busy] without touching the service when a
  /// removal is already running. Never throws: every failure — including a
  /// non-`Exception` FFI error — collapses to
  /// [MemberRemovalOutcome.failed] with the type (never the message) logged.
  ///
  /// Invalidates [circlesProvider] on success only, and forgets the removed
  /// member's location first (see [_forgetLocationsOf]). A failed removal
  /// changed no state, so re-reading the roster would cost an FFI round trip
  /// to learn nothing.
  Future<MemberRemovalOutcome> remove({
    required Circle circle,
    required String memberPubkeyHex,
  }) async {
    if (state != null) return MemberRemovalOutcome.busy;
    state = memberPubkeyHex;
    try {
      await ref
          .read(circleServiceProvider)
          .removeMember(
            mlsGroupId: circle.mlsGroupId,
            memberPubkeyHex: memberPubkeyHex,
          );
      await _forgetLocationsOf(circle, memberPubkeyHex);
      ref
        ..invalidate(circlesProvider)
        ..invalidate(memberLocationsProvider);
      return MemberRemovalOutcome.removed;
    } on Object catch (e) {
      // Type only — an FFI error message can carry the MLS group id (Rule 8).
      debugPrint('[RemoveMember] failed: ${e.runtimeType}');
      return MemberRemovalOutcome.failed;
    } finally {
      state = null;
    }
  }

  /// Drops the removed member's location from both places it can survive.
  ///
  /// [LocationSharingService.reconcileRoster] prunes the in-memory cache
  /// against the live roster, but returns early for a circle whose cache is
  /// empty — and the PERSISTED last-known row outlives that cache, so on the
  /// next hydrate it would come back as a pin for someone no longer in the
  /// circle. Deleting the row by pubkey covers the case the reconcile skips;
  /// it is idempotent, so doing both is not doing it twice.
  ///
  /// Never rethrows. This runs after the commit is already published,
  /// acked and applied: a failure here leaves a stale pin, which must not
  /// be reported to the admin as a removal that did not happen.
  Future<void> _forgetLocationsOf(Circle circle, String memberPubkeyHex) async {
    try {
      await ref.read(locationSharingServiceProvider).reconcileRoster(circle);
      await ref
          .read(circleServiceProvider)
          .removeLastKnownMember(
            nostrGroupId: circle.nostrGroupId,
            senderPubkey: memberPubkeyHex,
          );
    } on Object catch (e) {
      debugPrint('[RemoveMember] location cleanup failed: ${e.runtimeType}');
    }
  }
}
