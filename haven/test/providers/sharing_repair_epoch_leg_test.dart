/// The epoch-rotation leg of the sharing-health repair: what it is handed, what
/// it refuses to run against, and what it never lets escape.
///
/// The leg authors an MLS commit, so its gates are not cosmetic. It must run
/// against the SELECTED circle (never a stale or arbitrary one), it must have a
/// real identity to attribute the commit to, and a failure inside it must never
/// reach the user as raw engine text (Security Rule 8) nor mask the other
/// repair legs' work.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show SkipReasonFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';

import '../mocks/mock_circle_service.dart';

Circle _circle(String displayName) => Circle(
  mlsGroupId: const [1, 2, 3],
  nostrGroupId: const [4, 5, 6],
  displayName: displayName,
  circleType: CircleType.locationSharing,
  relays: const ['wss://relay.test'],
  membershipStatus: MembershipStatus.accepted,
  members: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

final _identity = Identity(
  pubkeyHex:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  npub: 'npub1test',
  createdAt: DateTime.utc(2026),
);

ProviderContainer _container({
  required MockCircleService service,
  Circle? selected,
  bool withIdentity = true,
}) => ProviderContainer(
  overrides: [
    circleServiceProvider.overrideWithValue(service),
    selectedCircleProvider.overrideWithValue(selected),
    identityProvider.overrideWith(
      (ref) async => withIdentity ? _identity : null,
    ),
  ],
);

void main() {
  group('the epoch-repair leg', () {
    test('runs against the SELECTED circle, with this device identity',
        () async {
      final service = MockCircleService()
        ..repairCircleEpochResult = const EpochRepairApplied();
      final container =
          _container(service: service, selected: _circle('picked'));
      addTearDown(container.dispose);
      // The identity provider is a FutureProvider; the leg reads its cached
      // value, so it has to have resolved first — exactly as it has by the time
      // a user can press the button.
      await container.read(identityProvider.future);

      final result =
          await repairSelectedCircleEpoch(container.read(Provider((r) => r)));

      expect(result, isA<EpochRepairApplied>());
      expect(service.repairCircleEpochCalls, hasLength(1));
      final call = service.repairCircleEpochCalls.single;
      expect(call.circle.displayName, 'picked');
      expect(call.selfPubkeyHex, _identity.pubkeyHex);
    });

    test('does nothing when no circle is selected', () async {
      final service = MockCircleService();
      final container = _container(service: service);
      addTearDown(container.dispose);
      await container.read(identityProvider.future);

      final result =
          await repairSelectedCircleEpoch(container.read(Provider((r) => r)));

      expect(result, isNull);
      expect(
        service.repairCircleEpochCalls,
        isEmpty,
        reason: 'a commit must never be authored against an unknown circle',
      );
    });

    test('does nothing when the identity is unknown', () async {
      final service = MockCircleService();
      final container = _container(
        service: service,
        selected: _circle('picked'),
        withIdentity: false,
      );
      addTearDown(container.dispose);
      await container.read(identityProvider.future);

      final result =
          await repairSelectedCircleEpoch(container.read(Provider((r) => r)));

      expect(result, isNull);
      expect(service.repairCircleEpochCalls, isEmpty);
    });

    test('surfaces a skip reason unchanged', () async {
      final service = MockCircleService()
        ..repairCircleEpochResult =
            const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin);
      final container = _container(service: service, selected: _circle('c'));
      addTearDown(container.dispose);
      await container.read(identityProvider.future);

      final result =
          await repairSelectedCircleEpoch(container.read(Provider((r) => r)));

      // The banner branches on this: collapsing it would cost the user the
      // one piece of information that tells them what to do instead.
      expect(
        result,
        isA<EpochRepairSkipped>().having(
          (r) => r.reason,
          'reason',
          SkipReasonFfi.notSoleAdmin,
        ),
      );
    });

    test('swallows a failure instead of letting engine text escape', () async {
      final service = MockCircleService()
        ..repairCircleEpochError =
            const CircleServiceException('Failed to repair the circle');
      final container = _container(service: service, selected: _circle('c'));
      addTearDown(container.dispose);
      await container.read(identityProvider.future);

      // Rule 8: nothing thrown, nothing rendered. The other repair legs have
      // already run by this point and their work must not be undone by this
      // one failing.
      final result =
          await repairSelectedCircleEpoch(container.read(Provider((r) => r)));

      expect(result, isNull);
    });
  });
}
