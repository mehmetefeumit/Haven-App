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
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/circle_service.dart'
    show ReinviteDelivery, reinviteDeliveryOf;
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/leaver_backstop.dart';
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
    CircleChangeDriver? changeDriver,
    void Function(List<LocationMessageResultFfi> replayed)? onReplayed,
    DateTime Function() clock = DateTime.now,
    LeaverBackstop? leaverBackstop,
  }) : _circleManagerFactory = circleManagerFactory,
       _identitySecretBytes = identitySecretBytes,
       _relayService = relayService,
       _changeDriver =
           changeDriver ??
           (relayService is CircleChangeDriver
               ? relayService as CircleChangeDriver
               : null),
       _onReplayed = onReplayed,
       _clock = clock,
       _leaverBackstop = leaverBackstop ?? LeaverBackstop(clock: clock);

  final Future<CircleManagerFfi> Function() _circleManagerFactory;
  final Future<List<int>> Function() _identitySecretBytes;
  final RelayService _relayService;
  final CircleChangeDriver? _changeDriver;
  final void Function(List<LocationMessageResultFfi> replayed)? _onReplayed;
  final DateTime Function() _clock;

  final LeaverBackstop _leaverBackstop;

  /// Carries on every leave this device asked for ([LeaverBackstop.carryOn]);
  /// [inFront] is a foreground caller's lifecycle read, `null` for a burst,
  /// and [pastWaits] asks every circle whatever wait it last named. Never
  /// throws.
  Future<LeaveCarryOn> carryOnLeaves({
    bool Function()? inFront,
    bool pastWaits = false,
  }) async {
    final driver = _changeDriver;
    if (driver == null) return LeaveCarryOn.none;
    final CircleManagerFfi circle;
    try {
      circle = await _circleManagerFactory();
    } on Object catch (e) {
      debugPrint('[Maintenance] leave carry-on failed: ${e.runtimeType}');
      return LeaveCarryOn.none;
    }
    return _leaverBackstop.carryOn(
      manager: circle,
      driver: driver,
      inFront: inFront,
      pastWaits: pastWaits,
    );
  }

  /// Forgets every wait this service holds: an identity's circles are not
  /// the next one's.
  void forget() {
    _forgets++;
    _leaverBackstop.forget();
    _resumeNotBefore = null;
  }

  /// Bumped by [forget]: a drive begun before it writes no wait after it.
  int _forgets = 0;

  /// Asks the fanout driver for the re-invites MDK owes whose lookup is due —
  /// only in the foreground, and nothing at all otherwise — each classified
  /// by variant: none is made. Never throws; a failure answers none.
  ///
  /// The lookups keep MDK's own schedule, and the drive that follows them
  /// each record's own: asking at every tick re-asks nothing that is not due,
  /// so the drive's wait does not hold the lookups back. What that drive
  /// handed back is handed to the `onReplayed` callback; its locations are
  /// already stored.
  Future<List<ReinviteDelivery>> reinviteOwed({
    required bool foreground,
  }) async {
    final driver = _changeDriver;
    if (driver == null || !foreground) return const [];
    try {
      final driven = await driver.reinvite(
        circle: await _circleManagerFactory(),
        foreground: foreground,
      );
      _onReplayed?.call(driven.drive.replayed);
      if (driven.drive.errored) {
        debugPrint('[Maintenance] re-invite drive ended on an error');
      }
      return [for (final r in driven.reinvites) reinviteDeliveryOf(r.result)];
    } on Object catch (e) {
      debugPrint('[Maintenance] re-invite failed: ${e.runtimeType}');
      return const [];
    }
  }

  /// Drives every stored record that has something due, in every circle —
  /// for the configuration no live plane drives (the flag-off one). Not
  /// before the wait the last drive named; what it hands back is converted
  /// (the `onReplayed` callback). [foreground] is the caller's claim, handed
  /// on untouched.
  /// Never throws.
  Future<void> resumeDrive({required bool foreground}) async {
    final driver = _changeDriver;
    if (driver == null) return;
    final notBefore = _resumeNotBefore;
    if (notBefore != null && _clock().isBefore(notBefore)) return;
    final forgets = _forgets;
    try {
      final drive = await driver.resume(
        circle: await _circleManagerFactory(),
        foreground: foreground,
      );
      // Forgotten meanwhile (a logout): its wait is the previous identity's.
      if (forgets != _forgets) return;
      final wait = drive.retryAfterMs;
      _resumeNotBefore = wait == null
          ? null
          : _clock().add(Duration(milliseconds: wait.toInt()));
      _onReplayed?.call(drive.replayed);
      if (drive.errored) debugPrint('[Maintenance] drive ended on an error');
    } on Object catch (e) {
      debugPrint('[Maintenance] drive failed: ${e.runtimeType}');
    }
  }

  /// Not before this instant is the stored-record drive asked again.
  DateTime? _resumeNotBefore;

  /// Runs a `KeyPackage` maintenance tick (kinds 30443 + 443).
  ///
  /// Never throws — a scheduled tick that throws kills its own reschedule.
  /// Failure is returned as a [KeyPackageMaintenanceFailed] instead, carrying
  /// the phase that broke so the caller can tell "logged out" (nothing to
  /// retry) from "the tick blew up" (retry, with a back-off).
  ///
  /// A dead publish path must never read as a healthy one, which is what an
  /// `.empty()` fallback once made it do.
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
      opKind: 'KeyPackage',
    );
  }

  /// Runs a relay-list maintenance tick (kind 10002 `KeyPackage`, then kind
  /// 10050 inbox).
  ///
  /// Returns [RelayListMaintenanceResult.failed] on any failure — never
  /// throws, and never a value that reads as a current list.
  Future<RelayListMaintenanceResult> maintainRelayList() async {
    return _withSecret(
      (circle, secret) => _relayService.maintainRelayList(
        circle: circle,
        identitySecretBytes: secret,
      ),
      onFailure: (_) => const RelayListMaintenanceResult.failed(),
      opKind: 'relay-list',
    );
  }

  /// Runs a subscription-health maintenance tick (engine-coupled).
  ///
  /// Unlike the other two tasks this needs neither the identity secret nor the
  /// circle handle — it only reads the live-sync engine's session — so it
  /// forwards straight to [RelayService.maintainSubscriptionHealth], which is
  /// itself best-effort and self-gates to a no-op when the engine is off.
  ///
  /// [foreground] is the caller's claim, handed on untouched: see
  /// [RelayService.maintainSubscriptionHealth].
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async {
    try {
      return await _relayService.maintainSubscriptionHealth(
        foreground: foreground,
      );
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
    required String opKind,
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
        '[Maintenance] $opKind orchestration failed in ${phase.name}: '
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
