/// Provider for publishing the user's `KeyPackage` (kind 30443) and relay
/// lists (kind 10050 inbox + kind 10002 NIP-65, Dark Matter W2) to relays.
///
/// Dark Matter (DM-4): `maintain_key_package` is now the ONE publish path for
/// `KeyPackage` material — decide → reuse-or-mint → publish → record all
/// live in Rust (`RelayManagerFfi.maintainKeyPackage`, wrapped by
/// `MaintenanceService.maintainKeyPackage`). This provider re-points
/// onboarding/login/circle-lifecycle triggers at that SAME idempotent path
/// the scheduled maintenance timer uses (see
/// `maintenance_scheduler_provider.dart`), so there is no longer a separate
/// sign/publish/record/delete dance here — and no race between an eager
/// login publish and the first maintenance tick minting competing `d` slots,
/// since both now call the identical decide logic.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_service.dart';

/// Publishes the user's `KeyPackage` (kind 30443, reuse-or-mint into a
/// stable slot) and relay lists (kind 10050 inbox + kind 10002 NIP-65).
///
/// Returns `true` unless the `KeyPackage` tick could not confirm any
/// canonical reachable on relays (a hard failure — both `MaintenanceService`
/// branches are otherwise best-effort and never throw).
///
/// Re-runs whenever the relay-preferences provider invalidates
/// [keyPackagePublisherInvalidatorProvider].
final keyPackagePublisherProvider = FutureProvider<bool>((ref) async {
  // Coupling to the relay-preferences invalidator: when the user adds /
  // removes a KP relay or toggles the publish setting, we re-run.
  ref.watch(keyPackagePublisherInvalidatorProvider);

  final identity = await ref.read(identityProvider.future);
  if (identity == null) return false;

  final maintenanceService = ref.read(maintenanceServiceProvider);

  final kpResult = await maintenanceService.maintainKeyPackage();
  debugPrint(
    '[KeyPackage] maintain tick: ${kpResult.action.name} '
    '(canonical=${kpResult.canonicalOnRelays}, '
    'errors=${kpResult.relayErrors})',
  );

  // Relay lists (kind 10050 inbox + the kind-10002 NIP-65 slot) are
  // best-effort and never block the KeyPackage result.
  final relayListResult = await maintenanceService.maintainRelayList();
  debugPrint(
    '[KeyPackage] relay-list tick: inbox=${relayListResult.inbox.action.name}, '
    'nip65=${relayListResult.keyPackage.action.name}',
  );

  // `alreadyHealthy` / `seededD` / `republishedStableD` / `republishedFreshD`
  // are all non-failure outcomes (the FFI itself only distinguishes success
  // shapes — a hard failure is swallowed to `KeyPackageMaintenanceResult
  // .empty()` by `MaintenanceService`, which is indistinguishable from
  // `alreadyHealthy` by design (presence-only, leak-free result). Callers of
  // this provider only ever fire-and-forget it (`invalidate` + `read`), so
  // the exact boolean carries no control-flow weight — it is kept for API
  // continuity with the pre-migration signature.
  return kpResult.action != KeyPackageMaintenanceAction.alreadyHealthy ||
      kpResult.canonicalOnRelays > 0;
});
