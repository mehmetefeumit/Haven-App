/// Tests for the self-update provider.
///
/// Dark Matter DM-4b note: MIP-02/03 leaf-key rotation moved from a
/// Dart-driven query-and-loop (`CircleService.groupsNeedingSelfUpdate` +
/// `selfUpdate`) to the Dark Matter engine's internal rotation lifecycle —
/// see `self_update_provider.dart`'s library doc comment. Both
/// `CircleService` methods were deleted; there is no surviving subject for
/// the pre-migration query/loop/per-group-failure tests this file used to
/// carry (`returns 0 when no groups need rotation`, `calls selfUpdate for
/// each group needing rotation`, `returns 0 when query fails`, `continues
/// updating remaining groups when selfUpdate throws`, `passes
/// selfUpdateThresholdSecs to the service`, `handles single group`) — they
/// are removed rather than re-expressed. What remains verifies the provider
/// is a documented, side-effect-free no-op and that its constants are
/// unchanged (callers still gate on them).
///
/// Verifies that:
/// - selfUpdateProvider always resolves to 0
/// - selfUpdateProvider never touches the circle service
/// - selfUpdateThresholdSecs / enablePeriodicSelfUpdate stay as documented
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/self_update_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selfUpdateProvider', () {
    test('always resolves to 0 (engine-internal rotation, no-op)', () async {
      final mockService = MockCircleService();

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      final result = await container.read(selfUpdateProvider.future);

      expect(result, 0);
    });

    test('never touches the circle service', () async {
      final mockService = MockCircleService();

      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      await container.read(selfUpdateProvider.future);

      expect(
        mockService.methodCalls,
        isEmpty,
        reason:
            'rotation is entirely engine-internal under Dark Matter — the '
            'provider must not call any CircleService method',
      );
    });

    test('threshold constant is 1 hour', () {
      expect(selfUpdateThresholdSecs, 3600);
    });

    // ---- periodic + post-join self-update disabled ----

    test('periodic self-update is DISABLED', () {
      // Single source of truth gating every call site. Superseded by the
      // Dark Matter engine's internal rotation lifecycle.
      expect(enablePeriodicSelfUpdate, isFalse);
    });

    test('a flag-gated call site never invokes the rotation loop', () async {
      final mockService = MockCircleService();
      final container = ProviderContainer(
        overrides: [circleServiceProvider.overrideWithValue(mockService)],
      );
      addTearDown(container.dispose);

      // Mirror the map_shell call-site gate: the provider is only read when
      // the flag is on. With it off, nothing runs — and even when read
      // (below), it is still a no-op — proven by the service never being
      // called.
      if (enablePeriodicSelfUpdate) {
        await container.read(selfUpdateProvider.future);
      }
      expect(
        mockService.methodCalls,
        isEmpty,
        reason: 'the circle service must not be touched when disabled',
      );
    });
  });
}
