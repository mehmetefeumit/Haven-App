/// DM-4c Dark Matter cutover — post-connect legacy KeyPackage retraction
/// (plan §6 step 5 / security F10a/F10b).
///
/// Fires `MaintenanceService.retractLegacyKeyMaterial` once relays are
/// connected (read from `MapShell`, alongside `keyPackagePublisherProvider`).
/// The underlying Rust call self-gates on a persisted sentinel
/// (`legacy_kp_retraction_done`), so invoking it is safe on every app
/// session — after the first successful run it becomes a fast, traffic-free
/// no-op (`alreadyDone`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

/// UI-facing outcome of a [legacyRetractionProvider] tick (presence-only,
/// leak-free — mirrors the leak-free shape of the underlying
/// `LegacyRetractionResult`).
enum LegacyRetractionUiStatus {
  /// No identity yet — the tick did not run.
  notApplicable,

  /// The retraction has completed — either just now, or already done in a
  /// prior session (`alreadyDone`).
  done,

  /// The retraction has not completed yet — most likely because no relay
  /// was reachable this tick (plan §6 F10b's "temporarily un-invitable"
  /// offline window). Safe to retry; the next app session (or relay
  /// reconnect) tries again.
  pending,
}

/// Runs the once-only legacy-KeyPackage retraction tick and exposes its
/// result so a subtle "pending — will retry once online" indicator can be
/// shown elsewhere (e.g. Relay Settings) when the network genuinely
/// prevented it from completing.
///
/// The underlying service call is itself best-effort and never throws, so
/// this provider never enters `AsyncError` for a relay-side failure — only
/// a truly unexpected local error (e.g. no identity service registered)
/// would surface as one.
final legacyRetractionProvider = FutureProvider<LegacyRetractionUiStatus>((
  ref,
) async {
  final identity = await ref.read(identityProvider.future);
  if (identity == null) return LegacyRetractionUiStatus.notApplicable;

  final maintenanceService = ref.read(maintenanceServiceProvider);
  final result = await maintenanceService.retractLegacyKeyMaterial();
  debugPrint(
    '[Cutover] legacy retraction tick: alreadyDone=${result.alreadyDone}, '
    'legacy443Scrubbed=${result.legacy443Scrubbed}, '
    'relayListRetracted=${result.relayListRetracted}, '
    'relayErrors=${result.relayErrors}',
  );

  if (result.alreadyDone) return LegacyRetractionUiStatus.done;
  // No progress this tick (nothing scrubbed, list not retracted) and the
  // sentinel is still unset — the Rust call defers when there is no relay
  // to probe/publish to yet (plan §6 F10b's offline window).
  if (result.legacy443Scrubbed == 0 && !result.relayListRetracted) {
    return LegacyRetractionUiStatus.pending;
  }
  return LegacyRetractionUiStatus.done;
});
