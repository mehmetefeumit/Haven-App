// What the readiness row and onboarding say about inviting this account, and
// what they must never say: an offline phone is not an uninvitable account,
// and a package this device cannot open is not a ready one.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_relay_service.dart' show relayListsCurrent;

const _published = KeyPackageMaintenancePublished(
  relaysAcked: 1,
  isFreshSlotMinted: true,
);

const _healthyCurrent = KeyPackageMaintenanceHealthy(
  canonicalOnRelays: 1,
  respondersProbed: 1,
  publishedCurrent: true,
);

/// A reinstall's first tick: it found its old self's package and adopted the
/// slot. An inviter can fetch that package; this device cannot open it.
const _adoptedOnly = KeyPackageMaintenanceHealthy(
  canonicalOnRelays: 1,
  respondersProbed: 1,
  isStableSlotSeeded: true,
);

KeyPackageMaintenanceFailed _failed(KeyPackageFailureKind kind) =>
    KeyPackageMaintenanceFailed(kind);

RelayListMaintenanceResult _lists(
  RelayListMaintenanceAction action, {
  bool ownConfirmed = false,
  int respondersProbed = 0,
}) {
  final c = RelayListCategoryResult(
    action: action,
    ownConfirmed: ownConfirmed,
    respondersProbed: respondersProbed,
  );
  return RelayListMaintenanceResult(inbox: c, keyPackage: c);
}

/// Every relay was out of reach this tick: nothing answered.
final _offlineLists = _lists(RelayListMaintenanceAction.alreadyCurrent);

void main() {
  group('reachabilityOf', () {
    test('no verdict yet is checking', () {
      expect(reachabilityOf(null, null), OwnReachability.checking);
      expect(reachabilityOf(_published, null), OwnReachability.checking);
      expect(reachabilityOf(null, relayListsCurrent), OwnReachability.checking);
    });

    test(
      'ready only with the current package AND both lists on an own relay',
      () {
        expect(
          reachabilityOf(_published, relayListsCurrent),
          OwnReachability.ready,
        );
        expect(
          reachabilityOf(_healthyCurrent, relayListsCurrent),
          OwnReachability.ready,
        );
        final inboxMissing = RelayListMaintenanceResult(
          inbox: const RelayListCategoryResult(
            action: RelayListMaintenanceAction.alreadyCurrent,
            ownConfirmed: false,
          ),
          keyPackage: relayListsCurrent.keyPackage,
        );
        expect(
          reachabilityOf(_published, inboxMissing),
          isNot(OwnReachability.ready),
          reason: 'without the 10050 no Welcome reaches this account',
        );
      },
    );

    test('an adopted-only slot is never ready, and is proven not ready', () {
      expect(
        reachabilityOf(_adoptedOnly, relayListsCurrent),
        OwnReachability.notReady,
        reason: 'an inviter would pick a package this device cannot open',
      );
    });

    test('nothing reached never reads as "can\'t invite you"', () {
      for (final kp in [
        _failed(KeyPackageFailureKind.noRelayResponded),
        _failed(KeyPackageFailureKind.tickErrored),
        _failed(KeyPackageFailureKind.identityUnavailable),
      ]) {
        for (final lists in [
          _offlineLists,
          const RelayListMaintenanceResult.failed(),
        ]) {
          expect(
            reachabilityOf(kp, lists),
            OwnReachability.cantCheck,
            reason: '$kp with nothing answering proves nothing',
          );
        }
      }
    });

    test(
      'a refused or missing package, with a relay reached, is not ready',
      () {
        for (final kind in [
          KeyPackageFailureKind.publishNotAcked,
          KeyPackageFailureKind.initKeyPurgedUnreplaced,
        ]) {
          expect(
            reachabilityOf(_failed(kind), relayListsCurrent),
            OwnReachability.notReady,
          );
        }
      },
    );

    test('lists a reached relay did not take are not ready', () {
      expect(
        reachabilityOf(
          _published,
          _lists(
            RelayListMaintenanceAction.unacknowledged,
            respondersProbed: 2,
          ),
        ),
        OwnReachability.notReady,
      );
    });

    test('no relay to publish to is its own state', () {
      expect(
        reachabilityOf(
          _failed(KeyPackageFailureKind.noRelaysConfigured),
          relayListsCurrent,
        ),
        OwnReachability.noRelaysConfigured,
      );
      expect(
        reachabilityOf(
          _published,
          _lists(RelayListMaintenanceAction.nothingConfigured),
        ),
        OwnReachability.noRelaysConfigured,
      );
    });

    test(
      'the storage-reset notice wins: nothing else can change until then',
      () {
        expect(
          reachabilityOf(
            _failed(KeyPackageFailureKind.awaitingResetAcknowledgement),
            _lists(RelayListMaintenanceAction.awaitingResetAcknowledgement),
          ),
          OwnReachability.awaitingReset,
        );
        expect(
          reachabilityOf(
            _failed(KeyPackageFailureKind.noRelaysConfigured),
            _lists(RelayListMaintenanceAction.awaitingResetAcknowledgement),
          ),
          OwnReachability.awaitingReset,
        );
      },
    );

    test('a list the stored setting suppresses does not hold back ready', () {
      expect(
        reachabilityOf(
          _published,
          _lists(RelayListMaintenanceAction.suppressed),
        ),
        OwnReachability.ready,
      );
    });
  });

  group('OwnReachabilityNotifier', () {
    ProviderContainer container({List<Override> overrides = const []}) {
      final c = ProviderContainer(overrides: overrides);
      addTearDown(c.dispose);
      return c;
    }

    test('once ready, an offline tick does not take it back; a proven failure '
        'does', () {
      final c = container();
      c.read(ownReachabilityProvider.notifier)
        ..recordRelayLists(relayListsCurrent)
        ..recordKeyPackage(_published);
      expect(c.read(ownReachabilityProvider).status, OwnReachability.ready);

      c.read(ownReachabilityProvider.notifier)
        ..recordRelayLists(_offlineLists)
        ..recordKeyPackage(_failed(KeyPackageFailureKind.noRelayResponded));
      expect(
        c.read(ownReachabilityProvider).status,
        OwnReachability.ready,
        reason: 'a phone that went offline is still invitable',
      );

      c
          .read(ownReachabilityProvider.notifier)
          .recordKeyPackage(_failed(KeyPackageFailureKind.publishNotAcked));
      expect(c.read(ownReachabilityProvider).status, OwnReachability.notReady);

      c
          .read(ownReachabilityProvider.notifier)
          .recordKeyPackage(_failed(KeyPackageFailureKind.noRelayResponded));
      expect(
        c.read(ownReachabilityProvider).status,
        OwnReachability.cantCheck,
        reason: 'ready is not restored by a tick that proves nothing',
      );
    });

    test('a logout drops everything the last identity learnt', () {
      final c = container();
      c.read(ownReachabilityProvider.notifier)
        ..recordRelayLists(relayListsCurrent)
        ..recordKeyPackage(_published);

      c.invalidate(ownReachabilityProvider);

      final state = c.read(ownReachabilityProvider);
      expect(state.status, OwnReachability.checking);
      expect(state.keyPackage, isNull);
      expect(state.relayLists, isNull);
    });

    test('Retry reads checking until the publisher has reported', () async {
      final gate = Completer<void>();
      final c = container(
        overrides: [
          keyPackagePublisherProvider.overrideWith((ref) async {
            await gate.future;
            ref.read(ownReachabilityProvider.notifier)
              ..recordRelayLists(relayListsCurrent)
              ..recordKeyPackage(_published);
            return _published;
          }),
        ],
      );
      c.read(ownReachabilityProvider.notifier)
        ..recordRelayLists(_offlineLists)
        ..recordKeyPackage(_failed(KeyPackageFailureKind.noRelayResponded));
      expect(c.read(ownReachabilityProvider).status, OwnReachability.cantCheck);

      final retry = c.read(ownReachabilityProvider.notifier).republish();
      expect(c.read(ownReachabilityProvider).status, OwnReachability.checking);

      gate.complete();
      await retry;
      expect(c.read(ownReachabilityProvider).status, OwnReachability.ready);
    });

    test('a superseded Retry does not end the newer one\'s checking', () async {
      final gates = [Completer<void>(), Completer<void>()];
      var runs = 0;
      final c = container(
        overrides: [
          keyPackagePublisherProvider.overrideWith((ref) async {
            final gate = gates[runs++];
            await gate.future;
            final kp = _failed(KeyPackageFailureKind.noRelayResponded);
            ref.read(ownReachabilityProvider.notifier)
              ..recordRelayLists(_offlineLists)
              ..recordKeyPackage(kp);
            return kp;
          }),
        ],
      );
      final notifier = c.read(ownReachabilityProvider.notifier);

      final first = notifier.republish();
      final second = notifier.republish();
      gates[0].complete();
      await pumpEventQueue();
      expect(
        c.read(ownReachabilityProvider).status,
        OwnReachability.checking,
        reason: 'the newer Retry is still running',
      );

      gates[1].complete();
      await Future.wait([first, second]);
      expect(runs, 2, reason: 'one publish per Retry');
      expect(c.read(ownReachabilityProvider).status, OwnReachability.cantCheck);
    });
  });
}
