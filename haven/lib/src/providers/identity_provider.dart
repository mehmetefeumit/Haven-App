/// Identity state providers.
///
/// Provides reactive access to the user's Nostr identity across the app.
/// The identity is loaded once and shared between all widgets that need it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_prefetch_provider.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Read-only provider for the current identity.
///
/// Returns the identity if it exists, null otherwise.
/// Automatically updates when [identityNotifierProvider] changes.
///
/// Usage:
/// ```dart
/// final identityAsync = ref.watch(identityProvider);
/// return identityAsync.when(
///   data: (identity) => identity != null
///       ? Text('Logged in as ${identity.npub}')
///       : const Text('No identity'),
///   loading: () => const CircularProgressIndicator(),
///   error: (_, __) => Text('Something went wrong'),
/// );
/// ```
final identityProvider = FutureProvider<Identity?>((ref) async {
  final service = ref.watch(identityServiceProvider);
  return service.getIdentity();
});

/// Provider for the user's display name.
///
/// Returns the stored display name, or null if not set.
/// Invalidate after calling [IdentityService.setDisplayName].
final displayNameProvider = FutureProvider<String?>((ref) async {
  final service = ref.watch(identityServiceProvider);
  return service.getDisplayName();
});

/// Notifier for identity mutations (create, delete, import).
///
/// Use this for actions that modify the identity state.
///
/// Usage:
/// ```dart
/// // Create new identity
/// await ref.read(identityNotifierProvider.notifier).createIdentity();
///
/// // Import from nsec
/// await ref.read(identityNotifierProvider.notifier).importFromNsec(nsec);
///
/// // Delete identity
/// await ref.read(identityNotifierProvider.notifier).deleteIdentity();
/// ```
final identityNotifierProvider =
    AsyncNotifierProvider<IdentityNotifier, Identity?>(IdentityNotifier.new);

/// AsyncNotifier for identity state management.
///
/// Handles identity creation, import, and deletion with proper
/// loading and error states.
class IdentityNotifier extends AsyncNotifier<Identity?> {
  @override
  Future<Identity?> build() async {
    final service = ref.read(identityServiceProvider);
    return service.getIdentity();
  }

  /// Creates a new random identity.
  ///
  /// The identity is automatically persisted to secure storage.
  /// Throws [IdentityServiceException] if an identity already exists.
  Future<void> createIdentity() async {
    // M10.1: complete any wipe left pending by a prior failed/interrupted logout
    // BEFORE this new identity writes any circle state — otherwise a stuck
    // pending-wipe marker could, on a later launch, wipe THIS identity's data.
    // FAIL CLOSED: if the pending wipe could not be completed, do NOT provision
    // a new identity over possibly-decryptable old MLS state (the shared-path
    // circles.db + its fixed keyring key would otherwise bleed into it).
    if (!await _reconcilePendingMlsWipe()) {
      state = AsyncError(
        const IdentityServiceException(
          'Could not prepare secure storage for a new identity. '
          'Please try again.',
        ),
        StackTrace.current,
      );
      ref.invalidate(identityProvider);
      return;
    }
    // Retire the circle service now that the slate is confirmed clean. The
    // logout deliberately left it as the wiped, `_wiped`-latched instance (so
    // every logged-out read failed closed and could not re-create circles.db);
    // this new identity must provision onto a FRESH instance.
    ref.invalidate(circleServiceProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(identityServiceProvider);
      return service.createIdentity();
    });
    // Invalidate the read-only provider so all watchers see the new identity
    ref.invalidate(identityProvider);
  }

  /// Imports an identity from an nsec string.
  ///
  /// The nsec must be a valid NIP-19 bech32-encoded secret key.
  /// Throws [IdentityServiceException] if invalid or identity exists.
  ///
  /// NOTE: The UI entry point for this (the onboarding import screen) is
  /// TEMPORARILY REMOVED. This method is intentionally retained so the
  /// import-existing-key flow can be restored once signer-app support and the
  /// Nostr-identity vs. Haven-username design land. Do not delete.
  Future<void> importFromNsec(String nsec) async {
    // M10.1: reconcile any pending MLS wipe before the imported identity writes
    // circle state (see [createIdentity] for the rationale). Fail closed if the
    // wipe could not be completed.
    if (!await _reconcilePendingMlsWipe()) {
      state = AsyncError(
        const IdentityServiceException(
          'Could not prepare secure storage for a new identity. '
          'Please try again.',
        ),
        StackTrace.current,
      );
      ref.invalidate(identityProvider);
      return;
    }
    // Retire the circle service now that the slate is confirmed clean (see
    // createIdentity) so the imported identity provisions onto a FRESH instance
    // rather than the wiped, `_wiped`-latched one the logout left in place.
    ref.invalidate(circleServiceProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(identityServiceProvider);
      return service.importFromNsec(nsec);
    });
    // Invalidate the read-only provider so all watchers see the new identity
    ref.invalidate(identityProvider);
  }

  /// Completes a wipe left pending by a prior failed/interrupted logout, if any,
  /// BEFORE a new identity is provisioned (M10.1). Returns whether the slate is
  /// CONFIRMED clean (safe to provision a new identity over).
  ///
  /// The pending-wipe marker is a boolean with no identity binding, so a marker
  /// that survived a failed logout (e.g. the wipe threw, or [clearPending]
  /// failed) would otherwise be honoured on the NEXT launch — after a new
  /// identity has already written to `circles.db` — and wipe the new identity's
  /// live MLS state. Running the retry here, before [CircleManagerFfi] opens a
  /// fresh DB for the new identity, resolves the pending wipe deterministically:
  /// the orphaned old state is deleted and the marker cleared.
  ///
  /// Returns:
  /// - `true`  — no wipe was pending, OR the pending wipe completed and the
  ///   marker is now cleared → the slate is clean.
  /// - `false` — a wipe was pending but could NOT be completed (the marker is
  ///   still set), so the old (possibly-decryptable) `circles.db` + its fixed
  ///   keyring key may survive. The caller MUST fail closed and refuse to
  ///   provision a new identity over it.
  ///
  /// If the marker cannot even be read (e.g. `SharedPreferences` is
  /// unavailable), returns `true`: that almost always means "no wipe pending"
  /// (the common onboarding case), and refusing all identity creation on a
  /// storage hiccup would be a strictly worse failure. The residual
  /// "marker set but unreadable" edge is covered by the launch-time retry.
  Future<bool> _reconcilePendingMlsWipe() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final marker = PendingMlsWipeService(
        prefs: prefs,
        circleService: ref.read(circleServiceProvider),
      );
      await marker.retryWipeIfPending();
      // A still-set marker means the wipe threw and the orphaned state was NOT
      // removed — report the slate as unclean so the caller fails closed.
      return !marker.isPending;
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][IdentityNotifier] M10.1 pre-create wipe reconcile could '
        'not verify marker state: ${e.runtimeType}',
      );
      return true;
    }
  }

  /// Deletes the identity from secure storage.
  ///
  /// This permanently removes the secret key.
  Future<void> deleteIdentity() async {
    final service = ref.read(identityServiceProvider);
    // M10.1 (M7-E hardening — set FIRST, before ANY teardown): mark the wipe
    // pending as the very first action so the marker is observable for the
    // ENTIRE logout. The M7 background-catch-up WorkManager wake runs in a
    // SEPARATE process — it cannot see the Dart `_wiped` latch and declines
    // only on this durable marker. Setting it up-front collapses the window in
    // which a concurrent wake could open the live circles.db (a receive-only
    // REQ) or leave a fresh-empty-DB residue, AND is strictly more crash-safe:
    // a crash anywhere in the teardown below now leaves the marker set, so the
    // next launch retries the wipe. Best-effort — a marker-write failure must
    // never block the primary objective of removing the secret key. (The
    // marker's `circleService` is unused by set/clearPending; only
    // retryWipeIfPending needs it.)
    PendingMlsWipeService? wipeMarker;
    try {
      final prefs = await SharedPreferences.getInstance();
      wipeMarker = PendingMlsWipeService(
        prefs: prefs,
        circleService: ref.read(circleServiceProvider),
      );
      await wipeMarker.setPending();
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][IdentityNotifier] M10.1 pending-wipe marker set FAILED: '
        '${e.runtimeType}',
      );
    }
    // Cancel any in-flight tile prefetch burst first so no further
    // member-area tile writes occur after the identity is wiped.
    ref.read(tilePrefetchServiceProvider).cancel();
    // Stop the live-sync engine before wiping state, so its standing
    // subscriptions tear down before the identity is removed. Best-effort +
    // idempotent (MapShell dispose also stops it).
    if (liveSyncEnabled) {
      try {
        await ref.read(subscriptionServiceProvider).stop();
      } on Object catch (e) {
        debugPrint(
          '[IdentityNotifier] subscription stop failed: ${e.runtimeType}',
        );
      }
    }
    // Wipe all persisted last-known locations BEFORE deleting the
    // identity, so any failure leaves no orphaned location rows behind.
    // Best-effort: swallow errors so a storage hiccup cannot block the
    // primary objective of removing the secret key. These failures are
    // privacy-relevant (stale location rows could survive an account
    // delete), so log them loudly with a leading SECURITY marker that is
    // trivial to grep for in a bug report.
    try {
      await ref.read(locationSharingServiceProvider).wipeAll();
    } on Object catch (e, stack) {
      debugPrint(
        '[SECURITY][IdentityNotifier] CRITICAL: wipeAll failed during '
        'identity deletion — persisted last-known rows may survive the '
        'delete: ${e.runtimeType}\n$stack',
      );
    }
    // M7 teardown: reset all sync cursors so a returning (or different)
    // identity never inherits a stale cursor floor. (The pre-migration
    // staged-commit marker wipe was removed with the Dark Matter migration —
    // the engine owns pending-commit state internally, so there is no
    // Haven-owned marker left to clear.) Best-effort — swallow errors so a
    // storage hiccup cannot block the primary objective of removing the
    // secret key.
    try {
      final circleService = ref.read(circleServiceProvider);
      await circleService.resetAllSyncCursors();
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][IdentityNotifier] M7 teardown (sync cursors) '
        'failed during identity deletion: ${e.runtimeType}',
      );
    }
    // M8+M10 (H1 ordering): cancel the scheduled maintenance timers BEFORE the
    // MLS wipe. Invalidating fires the notifier's `onDispose` (cancel-all), so
    // no *new* maintenance tick can fire during/after the wipe and re-open
    // circles.db (which would SQLite-create a fresh decryptable DB + keyring
    // key, defeating the wipe). An already-in-flight tick is additionally
    // refused a re-open by the circle service's `_wiped` latch (set in
    // `closeAndInvalidate` below). The engine's own subscription was already
    // stopped above.
    ref.invalidate(maintenanceSchedulerProvider);
    // M10: Wipe ALL MLS state (circles.db + haven_mdk.db files + keyring
    // keys). The close MUST precede the wipe so GC drops the SQLite fd
    // before the file is deleted (POSIX-safe unlink) — and it latches the
    // service so no in-flight caller can re-open the DB mid-wipe. Best-effort —
    // a storage failure must never block the primary objective of deleting the
    // identity key.
    final circleServiceForWipe = ref.read(circleServiceProvider);
    try {
      await circleServiceForWipe.closeAndInvalidate();
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][IdentityNotifier] M10 MLS close failed: ${e.runtimeType}',
      );
    }
    // (The M10.1 pending-wipe marker was already set as the FIRST action of
    // this method — see the top of deleteIdentity — so it covers the whole
    // logout, not just the wipe call.)
    var wipeSucceeded = false;
    try {
      await circleServiceForWipe.wipeAllMlsState();
      wipeSucceeded = true;
    } on Object catch (e, stack) {
      // A wipe failure leaves a DECRYPTABLE circles.db/haven_mdk.db at rest
      // (both the file AND its key survive). Log LOUDLY with the CRITICAL
      // marker so it is trivial to grep in a bug report. We log only the error
      // TYPE + the Dart stack (frame/method/file names) — never `e` itself or
      // `e.toString()`, which could carry an FFI detail string — so no secret
      // or MLS group ID leaks here even though debugPrint still emits in
      // release builds. The M10.1 pending-wipe marker is now set, so the next
      // launch will retry.
      debugPrint(
        '[SECURITY][IdentityNotifier] CRITICAL: M10 MLS wipe FAILED — a '
        'decryptable circles.db/haven_mdk.db may survive the delete; '
        'M10.1 retry marker is set and will be retried on next launch: '
        '${e.runtimeType}\n$stack',
      );
    }
    // M10.1: CLEAR the marker ONLY after a successful wipe so a crash during
    // the wipe leaves it set and the next launch retries.  Best-effort.
    if (wipeSucceeded && wipeMarker != null) {
      try {
        await wipeMarker.clearPending();
      } on Object catch (e) {
        debugPrint(
          '[SECURITY][IdentityNotifier] M10.1 pending-wipe marker clear FAILED '
          '(wipe succeeded — next launch will retry idempotently): '
          '${e.runtimeType}',
        );
      }
    }
    // circleServiceProvider is deliberately NOT invalidated anywhere in the
    // logout. `invalidate` would hand the NEXT read a FRESH, un-wiped instance,
    // and anything still running while logged out would use it to re-create
    // circles.db + a keyring key the wipe just removed: the B0 resubscriber's
    // engine restart, `circlesProvider`, and — crucially — MapShell's hourly
    // prune timer, which stays live because the router gates on onboarding, not
    // identity, so MapShell is not disposed on logout. Keeping the wiped,
    // `_wiped`-latched instance as the provider value makes every logged-out
    // read fail closed on the latch. It is retired on the LOGIN path
    // (createIdentity / importFromNsec, after the pending-wipe reconcile) so the
    // new identity provisions onto a fresh instance.
    // M7-A: cancel all background scheduling so no OS-queued wake can run
    // after the identity is removed. This fires BEFORE the identity is deleted
    // so the teardown can still read SharedPreferences. Note: this does NOT
    // clear kBackgroundSharingKey (only kBackgroundIdleKey /
    // kForegroundActiveAtMsKey), so the post-delete backstop is NOT the C3
    // background-sharing chokepoint — it is the CatchupService null-pubkey
    // guard: with no identity, ownPubkeyHex is null and runCatchup() returns
    // CatchupResult.empty() before any relay REQ (and get_visible_circles()
    // fails closed in Rust). This teardown is defense-in-depth on top of that.
    try {
      await BackgroundLocationManager.disableBackgroundScheduling();
    } on Object catch (e) {
      debugPrint(
        '[IdentityNotifier] background scheduling teardown failed during '
        'identity deletion: ${e.runtimeType}',
      );
    }
    // (Maintenance scheduler was already invalidated above, before the MLS
    // wipe — see the H1-ordering comment there. Cancelling it there rather than
    // here stops any *new* secret-bearing KeyPackage/relay-list republish tick
    // from arming during the wipe; a tick already mid-FFI completes with its
    // own already-scrubbed secret buffer and fails closed via the null-secret
    // guard in `MaintenanceService` once the identity is gone.)
    await service.deleteIdentity();
    state = const AsyncData(null);
    // Invalidate ONLY the read-only identity provider so watchers see the
    // logout. circleServiceProvider is intentionally left as the wiped,
    // `_wiped`-latched instance (see the comment above the background teardown)
    // so every logged-out read fails closed; it is retired on the next login.
    ref.invalidate(identityProvider);
  }

  /// Exports the identity as nsec for backup.
  ///
  /// Returns the nsec string or throws if no identity exists.
  Future<String> exportNsec() async {
    final service = ref.read(identityServiceProvider);
    return service.exportNsec();
  }

  /// Gets the secret bytes for FFI operations.
  ///
  /// Returns 32 bytes of the secret key.
  Future<List<int>> getSecretBytes() async {
    final service = ref.read(identityServiceProvider);
    return service.getSecretBytes();
  }
}
