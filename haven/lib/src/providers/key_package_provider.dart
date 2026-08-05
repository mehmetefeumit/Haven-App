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
/// Exposes the tick's [KeyPackageMaintenanceOutcome] rather than a bool.
///
/// It used to return `bool`, computed as "action != alreadyHealthy ||
/// canonicalOnRelays > 0", with a comment explaining that the value carried no
/// weight because a failure was indistinguishable from health anyway. Both
/// halves of that were wrong in the same direction: a publish that no relay
/// acknowledged reached this provider labelled `republishedFreshD`, so the
/// bool it produced was `true` — a *failed* tick reporting success. Keeping the
/// sealed outcome means the distinction survives to the provider layer, where a
/// UI can watch it, and no caller can flatten it back by accident.
///
/// [KeyPackageMaintenanceFailed] with
/// [KeyPackageFailureKind.identityUnavailable] is also what "no identity yet"
/// resolves to, so the not-signed-in case is not a fourth silent shape.
///
/// Re-runs whenever the relay-preferences provider invalidates
/// [keyPackagePublisherInvalidatorProvider].
final keyPackagePublisherProvider =
    FutureProvider<KeyPackageMaintenanceOutcome>((ref) async {
      // Coupling to the relay-preferences invalidator: when the user adds /
      // removes a KP relay or toggles the publish setting, we re-run.
      ref.watch(keyPackagePublisherInvalidatorProvider);

      final identity = await ref.read(identityProvider.future);
      if (identity == null) {
        return const KeyPackageMaintenanceFailed(
          KeyPackageFailureKind.identityUnavailable,
        );
      }

      final maintenanceService = ref.read(maintenanceServiceProvider);

      final kpOutcome = await maintenanceService.maintainKeyPackage();
      debugPrint('[KeyPackage] maintain tick: $kpOutcome');

      // Relay lists (kind 10050 inbox + the kind-10002 NIP-65 slot) are
      // best-effort and never block the KeyPackage outcome.
      final relayListResult = await maintenanceService.maintainRelayList();
      debugPrint(
        '[KeyPackage] relay-list tick: '
        'inbox=${relayListResult.inbox.action.name}, '
        'nip65=${relayListResult.keyPackage.action.name}',
      );

      return kpOutcome;
    });
