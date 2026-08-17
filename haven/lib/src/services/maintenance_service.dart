/// The M8 maintenance service: a thin orchestrator that runs the scheduled,
/// engine-independent resilience tasks (`KeyPackage` republish-if-missing and
/// relay-list republish-if-drifted).
///
/// Used by the [`maintenanceSchedulerProvider`] timers. Best-effort — it never
/// throws into its caller. The heavy lifting (relay probe, live-material gate,
/// stable-`d` seeding, sign + publish) happens in Rust; this only resolves the
/// FFI handle + the identity secret, forwards to [RelayService], and scrubs the
/// secret buffer afterwards.
///
/// ## Secret lifetime (Security Rule 9)
///
/// Each task **re-fetches** the identity secret per call, takes ownership of
/// the fetched buffer (without copying it — a copy would leave a second live
/// secret nothing can reach), passes it to the FFI (which consumes and
/// zeroizes it Rust-side), and scrubs the Dart-side buffer in a `finally`.
/// The secret is never held across ticks.
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:meta/meta.dart' show useResult;

/// Runs the scheduled M8 maintenance tasks.
class MaintenanceService {
  /// Creates a maintenance service over its injected dependencies (so it is
  /// unit-testable without the FFI bridge).
  MaintenanceService({
    required Future<CircleManagerFfi> Function() circleManagerFactory,
    required Future<List<int>> Function() identitySecretBytes,
    required RelayService relayService,
  }) : _circleManagerFactory = circleManagerFactory,
       _identitySecretBytes = identitySecretBytes,
       _relayService = relayService;

  final Future<CircleManagerFfi> Function() _circleManagerFactory;
  final Future<List<int>> Function() _identitySecretBytes;
  final RelayService _relayService;

  /// Runs a `KeyPackage` maintenance tick (kinds 30443 + 443).
  ///
  /// Never throws — a scheduled tick that throws kills its own reschedule.
  /// Failure is returned as a [KeyPackageMaintenanceFailed] instead, carrying
  /// the phase that broke so the caller can tell "logged out" (nothing to
  /// retry) from "the tick blew up" (retry, with a back-off).
  ///
  /// It does NOT reuse the other tasks' `.empty()` fallback: that fallback is
  /// what made a dead publish path read as a healthy one for as long as it did.
  @useResult
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage() async {
    return _withSecret(
      (circle, secret) => _relayService.maintainKeyPackage(
        circle: circle,
        identitySecretBytes: secret,
      ),
      onFailure: (phase) => KeyPackageMaintenanceFailed(
        switch (phase) {
          // No secret to sign a KeyPackage with — logged out, or secure
          // storage is unreadable. Not a relay problem, and not retryable
          // until the user is back.
          _MaintenancePhase.identitySecret =>
            KeyPackageFailureKind.identityUnavailable,
          // The MLS handle or the tick itself failed.
          _MaintenancePhase.circleHandle ||
          _MaintenancePhase.task => KeyPackageFailureKind.tickErrored,
        },
      ),
      label: 'KeyPackage',
    );
  }

  /// Runs a relay-list maintenance tick (kind 10050 inbox + kind 10002
  /// `KeyPackage`).
  ///
  /// Returns [RelayListMaintenanceResult.empty] on any failure — never throws.
  Future<RelayListMaintenanceResult> maintainRelayList() async {
    return _withSecret(
      (circle, secret) => _relayService.maintainRelayList(
        circle: circle,
        identitySecretBytes: secret,
      ),
      onFailure: (_) => const RelayListMaintenanceResult.empty(),
      label: 'relay-list',
    );
  }

  /// Runs the Dark Matter cutover's once-only legacy-KeyPackage retraction
  /// tick (plan §6 step 5 / security F10a/F10b): retracts this account's
  /// stale pre-migration KeyPackage advertisements (legacy kind-443 twins +
  /// the kind-10002 NIP-65 relay list).
  ///
  /// Self-gates on a persisted Rust-side sentinel, so calling this on every
  /// app session (or relay reconnect) is safe — after the first successful
  /// run it becomes a fast, traffic-free no-op.
  ///
  /// Returns [LegacyRetractionResult.empty] on any failure — never throws.
  Future<LegacyRetractionResult> retractLegacyKeyMaterial() async {
    return _withSecret(
      (circle, secret) => _relayService.retractLegacyKeyMaterial(
        circle: circle,
        identitySecretBytes: secret,
      ),
      onFailure: (_) => const LegacyRetractionResult.empty(),
      label: 'legacy-retraction',
    );
  }

  /// Runs a subscription-health maintenance tick (engine-coupled).
  ///
  /// Unlike the other two tasks this needs neither the identity secret nor the
  /// circle handle — it only reads the live-sync engine's session — so it
  /// forwards straight to [RelayService.maintainSubscriptionHealth], which is
  /// itself best-effort and self-gates to a no-op when the engine is off.
  Future<SubscriptionHealthResult> maintainSubscriptionHealth() async {
    try {
      return await _relayService.maintainSubscriptionHealth();
    } on Object catch (e) {
      debugPrint('[Maintenance] health orchestration failed: ${e.runtimeType}');
      return const SubscriptionHealthResult.empty();
    }
  }

  /// Resolves the circle handle + a scrubbed-in-`finally` secret buffer, runs
  /// [op], and returns `onFailure(phase)` if any step throws (fail-soft).
  ///
  /// [onFailure] takes the [_MaintenancePhase] that threw rather than being a
  /// fixed value, because the phases are not equally actionable: a missing
  /// identity secret and a broken FFI call want different responses from the
  /// caller. Tasks that genuinely cannot act on the difference ignore the
  /// argument.
  Future<T> _withSecret<T>(
    Future<T> Function(CircleManagerFfi circle, Uint8List secret) op, {
    required T Function(_MaintenancePhase phase) onFailure,
    required String label,
  }) async {
    // Own the fetched buffer so we can `fillRange` it on exit, minimising the
    // window the secret sits in Dart's managed heap after the FFI has consumed
    // it. Ownership only — deliberately NOT `withFreshSecret`, whose 32-byte
    // precondition this orchestrator has no business imposing: it forwards
    // whatever secure storage yields and leaves the FFI as the authority on
    // what is a valid signing key.
    Uint8List? secretBuffer;
    // Tracks how far we got, so the catch can attribute the throw. Assigned
    // immediately before entering each phase.
    var phase = _MaintenancePhase.circleHandle;
    try {
      final circle = await _circleManagerFactory();
      phase = _MaintenancePhase.identitySecret;
      secretBuffer = takeSecretOwnership(await _identitySecretBytes());
      phase = _MaintenancePhase.task;
      return await op(circle, secretBuffer);
    } on Object catch (e) {
      debugPrint(
        '[Maintenance] $label orchestration failed in ${phase.name}: '
        '${e.runtimeType}',
      );
      return onFailure(phase);
    } finally {
      secretBuffer?.fillRange(0, secretBuffer.length, 0);
    }
  }
}

/// Which step of a secret-bearing maintenance tick was running.
enum _MaintenancePhase {
  /// Resolving the circle-manager FFI handle.
  circleHandle,

  /// Reading the identity secret out of secure storage.
  identitySecret,

  /// Running the task itself (the FFI call).
  task,
}
