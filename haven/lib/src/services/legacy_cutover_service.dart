/// Once-only Dark Matter cutover guard (DM-4c, plan §6 step 2).
///
/// ## Problem
///
/// Migrating Haven to the Dark Matter MLS engine is a hard flag-day (no wire
/// bridge, no DB migration — see `docs/MDK_DARKMATTER_MIGRATION_PLAN.md`).
/// An install that previously ran the OLD engine has a legacy `haven_mdk.db`
/// (+ its keyring key `mdk.db.key.default`) on disk that the new
/// `session.sqlite`-backed `CircleManagerFfi` never reads. Left in place,
/// that abandoned SQLCipher database is dead weight and — per Security Rule
/// 7/`SECURITY.md` F6 — a stale key at rest is a residual-ciphertext risk
/// worth actively closing, not just ignoring.
///
/// ## Solution
///
/// This service stores a **boolean-only** durable marker in
/// [SharedPreferences] under [kLegacyCutoverDoneKey] and, the first time an
/// identity is present with the marker unset, calls the injected
/// `destroyLegacyMls` function to delete the old database and destroy its
/// keyring key — BEFORE anything constructs a `CircleManagerFfi` (mirrors
/// the M10.1 `PendingMlsWipeService` launch-retry pattern: `main.dart` runs
/// this before `runApp`, so it always precedes the first
/// `circleServiceProvider` read).
///
/// `destroyLegacyMls` has NO default and MUST be supplied by the caller: the
/// raw FFI `destroyLegacyMlsState` does not install a keyring backend
/// itself, and `storage.rs`'s `destroy_legacy_mls_key_material` treats "no
/// store installed" as an idempotent success (nothing left at rest) — a
/// property that is only true if a backend genuinely was attempted first.
/// Calling the raw FFI directly here would therefore ALWAYS report success
/// while NEVER removing the legacy SQLCipher key, permanently stranding it
/// while this marker latches "done". Production (`main.dart`) wires this to
/// `CircleService.destroyLegacyMlsState()`, which installs the keyring
/// backend before the FFI call.
///
/// ### Marker semantics
///
/// - Marker UNSET + no identity → no-op (nothing to migrate yet; a brand
///   new install has no legacy state, and a user still mid-onboarding has
///   not created an identity in THIS process yet — see `runIfNeeded`).
/// - Marker UNSET + identity present → calls `destroyLegacyMls`; on success,
///   sets the marker (never runs the destructive call again) and reports
///   that the first-launch cutover explainer should be shown. On failure,
///   leaves the marker unset so the next launch retries — mirrors
///   `PendingMlsWipeService`'s "only a genuine fault surfaces `Err`" the
///   contract.
/// - Marker SET → no-op, always.
///
/// The marker means "the destroy call completed without throwing", not "the
/// key is confirmably gone" — matching `destroyLegacyMls`'s own idempotent
/// contract (deleting an already-absent legacy DB/key is a defined success,
/// not just an unchecked one), so a retried call after a transient failure
/// is safe.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key for the durable "legacy cutover already ran"
/// boolean flag.
///
/// The value is a plain `bool`; it is NEVER set to a pubkey, MLS group ID,
/// relay URL, or any other identifying or secret material.
const String kLegacyCutoverDoneKey = 'haven.security.legacy_cutover_done_v1';

/// Function type matching `destroyLegacyMlsState`, injectable so tests can
/// exercise [LegacyCutoverService.runIfNeeded]'s success/failure branches
/// without the Rust FFI bridge. There is deliberately no default — see
/// [LegacyCutoverService]'s constructor doc for why an implementation MUST
/// install the keyring backend before calling the raw FFI.
typedef DestroyLegacyMlsState = Future<void> Function({
  required String dataDir,
});

/// Adapts a [CircleService] to the [DestroyLegacyMlsState] shape.
///
/// The SANCTIONED way to obtain [LegacyCutoverService]'s `destroyLegacyMls`
/// argument: [CircleService.destroyLegacyMlsState] (implemented by
/// `NostrCircleService`) installs the keyring backend BEFORE calling the raw
/// FFI, exactly like [CircleService.wipeAllMlsState]. `main.dart` wires
/// production through this adapter rather than the raw FFI directly, so the
/// bug this guards against — reporting success while never actually removing
/// the legacy SQLCipher key — cannot recur through this call site.
DestroyLegacyMlsState destroyLegacyMlsViaCircleService(
  CircleService circleService,
) => ({required String dataDir}) => circleService.destroyLegacyMlsState();

/// Runs the once-only Dark Matter cutover guard.
///
/// Inject [SharedPreferences] for testability; production callers obtain an
/// instance via [SharedPreferences.getInstance] (`main.dart` already loads
/// one for the M10.1 launch-retry and reuses it here). `destroyLegacyMls` is
/// also injectable — REQUIRED, not defaulted — so tests can simulate a
/// success or a genuine failure without the Rust bridge, and so production
/// cannot silently fall back to the keyring-unsafe raw FFI call (see the
/// library doc comment above).
class LegacyCutoverService {
  /// Creates the service over an injected [SharedPreferences] instance.
  ///
  /// [destroyLegacyMls] has no default: see the library doc comment for why
  /// the raw FFI call is unsafe to use directly here.
  LegacyCutoverService({
    required SharedPreferences prefs,
    required DestroyLegacyMlsState destroyLegacyMls,
  }) : _prefs = prefs,
       _destroyLegacyMls = destroyLegacyMls;

  final SharedPreferences _prefs;
  final DestroyLegacyMlsState _destroyLegacyMls;

  /// Returns `true` if the once-only cutover has already completed
  /// successfully.
  bool get isDone => _prefs.getBool(kLegacyCutoverDoneKey) ?? false;

  /// Marks the cutover as done. Best-effort: a [SharedPreferences] failure
  /// is logged generically and does not rethrow (the caller has already
  /// destroyed the legacy state; a failure to persist the marker only means
  /// the next launch harmlessly re-runs an idempotent no-op destroy).
  Future<void> _markDone() async {
    try {
      await _prefs.setBool(kLegacyCutoverDoneKey, true);
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][LegacyCutoverService] WARNING: failed to persist the '
        'cutover-done marker — the destroy call will safely (idempotently) '
        'retry next launch: ${e.runtimeType}',
      );
    }
  }

  /// Runs the guard if needed and reports whether the one-time explainer
  /// should be shown this launch.
  ///
  /// [hasIdentity] must be resolved BEFORE calling this (a direct
  /// secure-storage probe in `main.dart`, mirroring the existing onboarding
  /// migration check) — this service takes no dependency on the identity
  /// service so it can run at the same point in `main()` as the M10.1
  /// launch-retry, before any Riverpod container exists.
  ///
  /// Returns `true` only when this call newly destroyed legacy state this
  /// launch (a first-launch-since-upgrade cutover) — the caller should then
  /// surface a one-time explainer. Returns `false` when the marker was
  /// already set, no identity is present yet, or the destroy call failed
  /// (logged; retried on the next launch).
  Future<bool> runIfNeeded({
    required String dataDir,
    required bool hasIdentity,
  }) async {
    if (isDone) return false;
    if (!hasIdentity) {
      // Nothing to migrate yet: either a brand-new install (no legacy state
      // ever existed) or a user still completing onboarding in THIS process
      // (their identity, once created, is picked up on the NEXT launch).
      return false;
    }

    debugPrint(
      '[SECURITY][LegacyCutoverService] identity present, cutover marker '
      'unset — destroying legacy pre-Dark-Matter MLS state',
    );

    try {
      await _destroyLegacyMls(dataDir: dataDir);
      await _markDone();
      debugPrint(
        '[SECURITY][LegacyCutoverService] legacy MLS state destroyed — '
        'cutover marker set',
      );
      return true;
    } on Object catch (e) {
      // A GENUINE failure (locked file / unavailable keyring) — leave the
      // marker unset so the next launch retries. Never log `e` itself (see
      // `destroyLegacyMlsState`'s doc comment: the error is deliberately
      // generic, but defence-in-depth still avoids logging raw errors,
      // Security Rule 8).
      debugPrint(
        '[SECURITY][LegacyCutoverService] CRITICAL: legacy MLS state '
        'destroy FAILED — will retry next launch: ${e.runtimeType}',
      );
      return false;
    }
  }
}
