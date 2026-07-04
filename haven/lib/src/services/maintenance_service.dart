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
/// Each task **re-fetches** the identity secret per call, copies it into a
/// [Uint8List] buffer this service owns, passes it to the FFI (which consumes
/// and zeroizes it Rust-side), and scrubs the Dart-side buffer in a `finally`.
/// The secret is never held across ticks.
library;

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/relay_service.dart';

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
  /// Returns [KeyPackageMaintenanceResult.empty] on any failure (no identity,
  /// uninitialized manager, FFI error) — a scheduled tick must never throw.
  Future<KeyPackageMaintenanceResult> maintainKeyPackage() async {
    return _withSecret(
      (circle, secret) => _relayService.maintainKeyPackage(
        circle: circle,
        identitySecretBytes: secret,
      ),
      onFailure: const KeyPackageMaintenanceResult.empty(),
      label: 'KeyPackage',
    );
  }

  /// Runs a relay-list maintenance tick (kind 10050 inbox + 10051
  /// `KeyPackage`).
  ///
  /// Returns [RelayListMaintenanceResult.empty] on any failure — never throws.
  Future<RelayListMaintenanceResult> maintainRelayList() async {
    return _withSecret(
      (circle, secret) => _relayService.maintainRelayList(
        circle: circle,
        identitySecretBytes: secret,
      ),
      onFailure: const RelayListMaintenanceResult.empty(),
      label: 'relay-list',
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
  /// [op], and returns [onFailure] if any step throws (fail-soft).
  Future<T> _withSecret<T>(
    Future<T> Function(CircleManagerFfi circle, Uint8List secret) op, {
    required T onFailure,
    required String label,
  }) async {
    // Hold the secret-bytes copy in a typed buffer so we can `fillRange` it on
    // exit, minimising the window the secret sits in Dart's managed heap after
    // the FFI has consumed it. Mirrors `key_package_provider.dart`.
    Uint8List? secretBuffer;
    try {
      final circle = await _circleManagerFactory();
      secretBuffer = Uint8List.fromList(await _identitySecretBytes());
      return await op(circle, secretBuffer);
    } on Object catch (e) {
      debugPrint('[Maintenance] $label orchestration failed: ${e.runtimeType}');
      return onFailure;
    } finally {
      secretBuffer?.fillRange(0, secretBuffer.length, 0);
    }
  }
}
