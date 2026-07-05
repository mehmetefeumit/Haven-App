/// Durable "pending MLS wipe" marker and launch-retry service (M10.1).
///
/// ## Problem
///
/// On logout, [IdentityNotifier.deleteIdentity] wipes all MLS state by calling
/// `CircleService.wipeAllMlsState()`.  If the wipe fails (storage error, FFI
/// crash) **or** the app is killed mid-wipe, a DECRYPTABLE `circles.db` /
/// `haven_mdk.db` — together with its keyring encryption key — can survive at
/// rest.  There is no retry mechanism today.
///
/// ## Solution
///
/// This service stores a **boolean-only** durable marker in [SharedPreferences]
/// under [kPendingMlsWipeKey].  The marker records only the fact "a wipe is
/// pending"; it MUST NOT contain any pubkey, MLS group ID, or other identifying
/// or secret data (Haven privacy rule — no personal data in plaintext storage).
///
/// ### Set/clear ordering (crash-safe)
///
/// 1. SET the marker to `true` BEFORE calling `wipeAllMlsState()`.
/// 2. CLEAR the marker (set to `false`) ONLY AFTER `wipeAllMlsState()` returns
///    successfully.
/// 3. A crash or a thrown exception therefore leaves the marker SET.
///
/// Both the marker write and any failure to write the marker are best-effort:
/// a failure to write the marker must never block identity deletion (the primary
/// objective of the logout path).  Failures are logged generically.
///
/// ### Launch retry
///
/// On the next app launch [retryWipeIfPending] is called **before any DB is
/// opened** — AFTER `RustLib.init()` (the FFI must be ready to call the wipe)
/// but before `runApp` / any `circles.db` access, in `main.dart`.  If the
/// marker is set, it calls `wipeAllMlsState()` again:
///
/// - On success: clears the marker.  `wipe_all_mls_state` is idempotent — it
///   returns `Ok` both when it deletes state AND when there was nothing to
///   delete (an already-clean slate) — so a benign no-op retry reaches this
///   success path and clears the marker; there is no infinite loop.
/// - On failure (a GENUINE deletion error surfaced as a thrown
///   `CircleServiceException`): **leaves the marker set** so the next launch
///   retries.  There is no expected-vs-unexpected classification — any thrown
///   exception keeps the marker set, which is correct because
///   `wipe_all_mls_state` only returns `Err` for a real fault (a locked file /
///   an unavailable keyring), never for an already-clean state.
///
/// ### Identity-absent safety
///
/// After a real failed logout the identity key itself was already deleted, so
/// on the next launch there is typically NO identity.  [retryWipeIfPending]
/// deliberately does not require an identity — it calls `wipeAllMlsState()`
/// directly on the supplied [CircleService] (which is safe and idempotent
/// with no active identity and possibly non-existent DB files).
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key for the durable pending-MLS-wipe boolean flag.
///
/// The value is a plain `bool`; it is NEVER set to a pubkey, MLS group ID,
/// relay URL, or any other identifying or secret material.
const String kPendingMlsWipeKey = 'haven.security.pending_mls_wipe';

/// Sets, clears, and checks the durable pending-MLS-wipe marker, and runs the
/// launch-time retry when the marker is present.
///
/// Inject [SharedPreferences] and [CircleService] for testability; production
/// callers obtain a [SharedPreferences] via [SharedPreferences.getInstance]
/// and a [CircleService] from the Riverpod provider, then construct directly.
class PendingMlsWipeService {
  /// Creates the service with injected dependencies.
  ///
  /// Both parameters are required for testability. Production callers obtain
  /// a [SharedPreferences] instance via [SharedPreferences.getInstance] and a
  /// [CircleService] instance from the Riverpod provider.
  const PendingMlsWipeService({
    required SharedPreferences prefs,
    required CircleService circleService,
  }) : _prefs = prefs,
       _circleService = circleService;

  final SharedPreferences _prefs;
  final CircleService _circleService;

  // ---------------------------------------------------------------------------
  // Marker access
  // ---------------------------------------------------------------------------

  /// Returns `true` if a pending MLS wipe has been durably recorded.
  bool get isPending => _prefs.getBool(kPendingMlsWipeKey) ?? false;

  /// Marks a wipe as pending.
  ///
  /// Must be called BEFORE attempting [CircleService.wipeAllMlsState] so that
  /// a crash or a mid-wipe kill leaves the marker set.
  ///
  /// Best-effort: a [SharedPreferences] failure is logged generically and does
  /// not rethrow.
  Future<void> setPending() async {
    try {
      await _prefs.setBool(kPendingMlsWipeKey, true);
    } on Object catch (e) {
      // A failure to set the marker is logged but must not block identity
      // deletion.  Use runtimeType only — never log `e` itself (could carry
      // internal FFI detail strings).
      debugPrint(
        '[SECURITY][PendingMlsWipeService] WARNING: failed to set pending-wipe '
        'marker — if the wipe fails the marker will not survive a restart: '
        '${e.runtimeType}',
      );
    }
  }

  /// Clears the pending-wipe marker.
  ///
  /// Must be called ONLY AFTER [CircleService.wipeAllMlsState] has returned
  /// successfully, confirming the wipe completed.
  ///
  /// Best-effort: a [SharedPreferences] failure is logged generically and does
  /// not rethrow.
  Future<void> clearPending() async {
    try {
      await _prefs.setBool(kPendingMlsWipeKey, false);
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][PendingMlsWipeService] WARNING: failed to clear pending-wipe '
        'marker after a successful wipe — the next launch will retry '
        '(idempotent): ${e.runtimeType}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Launch retry
  // ---------------------------------------------------------------------------

  /// Retries the MLS state wipe on launch if the durable marker is set.
  ///
  /// Call this **before any DB is opened** (see `main.dart` for placement).
  ///
  /// Behaviour:
  /// - Marker absent → returns immediately without calling [CircleService].
  /// - Marker present → calls [CircleService.wipeAllMlsState]:
  ///   - Returns normally → clears the marker.  `wipe_all_mls_state` is
  ///     idempotent: it returns `Ok` when it deletes state AND when there was
  ///     nothing to delete (already clean), so a benign no-op retry reaches
  ///     this path and clears the marker — there is no infinite loop.
  ///   - Throws → **leaves the marker set** so the next launch retries.  On ANY
  ///     exception the marker is kept (no expected-vs-unexpected classification)
  ///     — correct because `wipe_all_mls_state` only surfaces an error for a
  ///     GENUINE fault (a locked DB file, an unavailable keyring), never for an
  ///     already-clean slate, so a persistent failure legitimately keeps
  ///     retrying until the wipe truly succeeds.
  ///
  /// This method intentionally does NOT require an identity to be present.
  /// After a real failed logout the identity key is already deleted; the retry
  /// simply re-wipes the orphaned DB files.
  Future<void> retryWipeIfPending() async {
    if (!isPending) {
      return;
    }

    debugPrint(
      '[SECURITY][PendingMlsWipeService] pending MLS wipe detected on launch — '
      'retrying wipe before any DB is opened',
    );

    try {
      await _circleService.wipeAllMlsState();
      // Wipe succeeded (or was idempotently a no-op) — clear the marker.
      await clearPending();
      debugPrint(
        '[SECURITY][PendingMlsWipeService] launch-retry wipe completed — '
        'pending marker cleared',
      );
    } on Object catch (e) {
      // The wipe failed again.  Leave the marker set so the next launch
      // retries.  Log CRITICALLY with only the error type (never `e` itself).
      debugPrint(
        '[SECURITY][PendingMlsWipeService] CRITICAL: launch-retry wipe FAILED '
        '— a decryptable circles.db/haven_mdk.db may survive; will retry on '
        'next launch: ${e.runtimeType}',
      );
    }
  }
}
