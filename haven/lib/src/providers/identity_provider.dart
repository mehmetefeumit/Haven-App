/// Identity state providers.
///
/// Provides reactive access to the user's Nostr identity across the app.
/// The identity is loaded once and shared between all widgets that need it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_scope.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/tile_prefetch_provider.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart'
    show kLiveSyncRestartBudget;
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:haven/src/utils/log_alias.dart';
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
      // log-scan-ok: fixed literal message; StackTrace.current has no data.
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
    // Whatever the last identity left on the publish pool, this one's first
    // publish or fetch opens a pool of its own.
    await _shutDownPublishPool();
    // Retire the circle service now that the slate is confirmed clean. The
    // logout deliberately left it as the wiped, `_wiped`-latched instance (so
    // every logged-out read failed closed and could not re-create circles.db);
    // this new identity must provision onto a FRESH instance — and so must
    // everything that was built from the last one.
    ref.invalidate(circleServiceProvider);
    invalidateIdentityScope(ref);
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
      // log-scan-ok: fixed literal message; StackTrace.current has no data.
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
    // A pool of its own, and a FRESH circle service rather than the wiped,
    // `_wiped`-latched one the logout left in place (see createIdentity).
    await _shutDownPublishPool();
    ref.invalidate(circleServiceProvider);
    invalidateIdentityScope(ref);
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
        meshRadio: ref.read(meshRadioProvider),
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
    // The Bluetooth mesh's radio goes next, ahead of everything that takes
    // time: the service keeps a copy of the deadline to come back by itself
    // after a restart, and a logout that died later would leave it relaying
    // with no Dart running until the next launch. The radio bounds its own
    // answer. Nothing where the build or the platform has no radio.
    try {
      await ref.read(meshRadioProvider)?.stop();
    } on Object {
      // A service left running finds no engine at its next entry and stops
      // itself; the pending-wipe marker's retry stops it again.
    }
    // Cancel any in-flight tile prefetch burst first so no further
    // member-area tile writes occur after the identity is wiped.
    ref.read(tilePrefetchServiceProvider).cancel();
    // One deadline for both stops: a second stop issued while the first is
    // still out joins it (`stop()` coalesces), so a budget of its own would
    // only keep the key longer. A first stop that returns late leaves the
    // second only what is left of the deadline, possibly nothing; it is still
    // issued.
    final stopsGivenUp = Completer<void>();
    final stopBudget = liveSyncEnabled
        ? Timer(kLiveSyncRestartBudget, stopsGivenUp.complete)
        : null;
    // Stop the live-sync engine before wiping state, so its standing
    // subscriptions tear down before the identity is removed. Not the last
    // word: see the second stop, behind the latch.
    await _stopLiveSync(stopsGivenUp.future);
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
      // A Dart StackTrace is compiled-in source frame/method/file locations
      // only — never a runtime value — so it cannot carry a secret, group id
      // or any other identifier.
      // log-scan-ok: StackTrace carries no runtime values (Rule 15)
      debugPrint(
        '[SECURITY][IdentityNotifier] CRITICAL: wipeAll failed during '
        'identity deletion — persisted last-known rows may survive the '
        'delete: ${e.runtimeType}\n$stack',
      );
    }
    // Clear the location service's in-memory stream-position cache so the
    // pre-logout coordinate can never be served to a subsequently created
    // identity (the service is a process-lifetime singleton that survives
    // logout). Synchronous, cannot throw.
    final locationServiceForWipe = ref.read(locationServiceProvider);
    if (locationServiceForWipe is GeolocatorLocationService) {
      locationServiceForWipe.clearCachedPosition();
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
    // `closeAndInvalidate` below). The engine's own subscription was stopped
    // above, and is stopped again behind that latch.
    ref
      ..invalidate(maintenanceSchedulerProvider)
      // Same H1 ordering for the per-circle location-publish scheduler: cancel
      // its per-circle timers BEFORE the wipe so no publish tick can re-open
      // circles.db mid/post-wipe (its `onDispose` fires on invalidate).
      ..invalidate(locationPublishSchedulerProvider)
      // Same ordering for the public-profile refresh notifier: it is
      // non-autoDispose and holds a coalescing queue plus a captured roster in
      // a live closure, so without this a queued follow-up could issue a
      // kind-0 REQ for the deleted identity's social graph *after* the user
      // asked for it to be erased. The `_wiped` latch already prevents
      // circles.db resurrection; this closes the residual metadata exposure.
      ..invalidate(memberProfileRefreshProvider);
    // M10: Wipe ALL MLS state (circles.db + haven_mdk.db files + keyring
    // keys). The close MUST precede the wipe: it disposes the RustOpaque handle
    // — closing the SQLite fds before the file is deleted (POSIX-safe unlink)
    // and releasing the MLS DB's Rule-14 single-session slot, so a re-login in
    // THIS process can open a session instead of failing closed on "an MLS
    // session is already open on this database" — and it latches the service so
    // no in-flight caller can re-open the DB mid-wipe. (The release is explicit,
    // not GC-timed; see `NostrCircleService.closeAndInvalidate`. It is why the
    // engine is stopped on both sides of it — the engine holds its own
    // `Arc<CircleManager>` clone.) Best-effort — a storage failure must never
    // block the primary objective of deleting the identity key.
    final circleServiceForWipe = ref.read(circleServiceProvider);
    try {
      await circleServiceForWipe.closeAndInvalidate();
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][IdentityNotifier] M10 MLS close failed: ${e.runtimeType}',
      );
    }
    // The stop that is final. MapShell stays mounted across a logout, the
    // app is in front, and until the latch above the identity was present and
    // the manager open — so a leg queued behind the start the first stop
    // ended (the resume's heal, a debounced delta, a heal tick) was free to
    // build a NEW engine during the awaited wipes in between. Left up, it
    // holds standing REQs — the inbox `#p` REQ on the deleted npub among
    // them — and MLS state on unlinked files until the process dies. Now
    // that the latch holds, no factory can obtain a manager, so nothing can
    // start behind this one.
    //
    // Its outcome is deliberately not read: a session Rust would not let go
    // must not keep the key on the device.
    await _stopLiveSync(stopsGivenUp.future);
    stopBudget?.cancel();
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
      // or MLS group ID leaks here even in a DEBUG build or an E2E capture,
      // where (unlike release, which `main.dart`'s `kReleaseMode` silencer
      // makes a no-op) `debugPrint` genuinely does emit. The M10.1
      // pending-wipe marker is now set, so the next launch will retry.
      // log-scan-ok: StackTrace carries no runtime values (Rule 15)
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
    // Clear every durable "leave in progress" marker (public nostr_group_ids
    // of circles this identity was leaving). Must run AFTER wipeAllMlsState:
    // once every local MLS group is destroyed and the signing secret is gone,
    // there is nothing left to resume — a marker that survived would be a
    // plaintext residue of the deleted identity's past circle memberships.
    // Best-effort.
    try {
      final prefs = await SharedPreferences.getInstance();
      await PendingLeaveService(prefs: prefs).clearAll();
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][IdentityNotifier] pending-leave marker clear failed '
        'during identity deletion: ${e.runtimeType}',
      );
    }
    // The next identity reads the Bluetooth mesh's disclosure for itself.
    // Best-effort.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kMeshIntroSeenKey);
    } on Object catch (e) {
      debugPrint(
        '[IdentityNotifier] mesh disclosure flag clear failed during '
        'identity deletion: ${e.runtimeType}',
      );
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
    // Clear the background-publish HISTORY timestamps (last publish time,
    // last session-reclaim attempt) — a record of what the DELETED identity
    // did, distinct from the coordination keys disableBackgroundScheduling
    // already cleared above. Best-effort.
    try {
      await BackgroundLocationManager.clearPublishHistoryOnIdentityDelete();
    } on Object catch (e) {
      debugPrint(
        '[IdentityNotifier] background publish-history clear failed during '
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
    // The publish pool is process-lifetime, and its sockets live 60-70 s past
    // their last send: left open, the next identity's first publishes would
    // ride them, linking the two identities at those relays. Every stop has
    // returned or been given up on, and the latch refuses every MLS operation,
    // so nothing of this identity can start on the pool now; what is still out
    // is cut. The next use opens a pool of its own.
    await _shutDownPublishPool();
    // Rule 15: no per-process log handle minted this session may still
    // resolve after logout. Re-mints the salt (so a fresh call for the same
    // value hashes differently) and drops the memo (so a stale pre-rotation
    // handle cannot keep answering for it). Best-effort/non-throwing; see
    // `rotateLogAliasSaltNow`'s own doc comment for why nothing depends on it
    // succeeding.
    rotateLogAliasSaltNow();
    clearLogAliasMemo();
    // Evidence gathered under this identity is not the next one's: the
    // locations still in a handler, its peers' clock samples, and the waits
    // its circles' leaves and drives named.
    ref.read(liveEventRouterProvider).forgetIdentity();
    ref.read(clockSkewDetectorProvider).reset();
    ref.read(maintenanceServiceProvider).forget();
    state = const AsyncData(null);
    // Invalidate ONLY the read-only identity provider so watchers see the
    // logout. circleServiceProvider is intentionally left as the wiped,
    // `_wiped`-latched instance (see the comment above the background teardown)
    // so every logged-out read fails closed; it is retired on the next login.
    // Everything else that was built from this identity goes now: its relay
    // lists, its circles, its cached pubkey. Rebuilt while logged out, each
    // reads the latched circle service and fails closed.
    invalidateIdentityScope(ref);
    ref.invalidate(identityProvider);
  }

  /// Shuts the process-lifetime publish pool: the next publish or fetch opens
  /// one of its own.
  Future<void> _shutDownPublishPool() async {
    final relay = ref.read(relayServiceProvider);
    if (relay is NostrRelayService) await relay.shutdown();
  }

  /// Stops the live-sync engine, or ends its start in flight. Never throws,
  /// and never waits past [givenUp], the logout's one [kLiveSyncRestartBudget]
  /// for both its stops: nothing here may block the removal of the secret
  /// key, or hold it up.
  ///
  /// The engine bounds its own teardown, but first takes its lifecycle lock,
  /// and that wait has no bound — a pause draining a publish holds it for as
  /// long as the relays take. A user who kills the app during such a wait
  /// would keep the key. One stop can also be two engine stops (one retry),
  /// so the deadline can cut short a teardown that had no lock to wait for.
  /// A stop still out at the deadline is treated as one that left the engine
  /// holding: the wipe proceeds.
  Future<void> _stopLiveSync(Future<void> givenUp) async {
    if (!liveSyncEnabled) return;
    try {
      // The service tears its Dart side down when [givenUp] completes; the
      // race keeps the key's wait from depending on that.
      await Future.any([
        ref.read(subscriptionServiceProvider).stop(givenUp: givenUp),
        givenUp,
      ]);
    } on Object catch (e) {
      debugPrint(
        '[IdentityNotifier] subscription stop failed: ${e.runtimeType}',
      );
    }
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
