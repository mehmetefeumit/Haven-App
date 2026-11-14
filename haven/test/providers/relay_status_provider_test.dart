/// Tests for the relay settings check.
///
/// Verifies that:
/// - each row expects exactly the kinds its lists publish there, before and
///   after the check, and the check's own rows are what is shown;
/// - "Missing", "Old version" and "Can't reach" stay three different answers;
/// - a relay is green only when EVERY expected kind is current — never
///   because one of them is;
/// - every expected kind reads checking while the one answer is awaited;
/// - a failed check reads as "Can't reach", never as missing;
/// - Republish runs the publisher, then checks again, and reports in three
///   fixed outcomes.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/own_reachability_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart'
    show OwnEventPresenceFfi, OwnRelayPresenceFfi;
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_relay_preferences_service.dart';
import '../mocks/mock_relay_service.dart';

const _inbox = 'wss://inbox.example.com';
const _kp = 'wss://kp.example.com';

final _testIdentity = Identity(
  pubkeyHex: 'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
  npub: 'npub1test',
  createdAt: DateTime(2024),
);

OwnRelayPresenceFfi _row(
  String url, {
  bool own = true,
  bool lookup = false,
  OwnEventPresenceFfi keyPackage = OwnEventPresenceFfi.notExpected,
  OwnEventPresenceFfi relayList = OwnEventPresenceFfi.notExpected,
  OwnEventPresenceFfi inboxRelayList = OwnEventPresenceFfi.notExpected,
}) => OwnRelayPresenceFfi(
  relayUrl: url,
  own: own,
  lookup: lookup,
  reachable: true,
  keyPackage: keyPackage,
  relayList: relayList,
  inboxRelayList: inboxRelayList,
);

ProviderContainer _container(
  MockRelayService relay, {
  Identity? identity,
  bool noIdentity = false,
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      ...extra,
      identityProvider.overrideWith(
        (_) async => noIdentity ? null : (identity ?? _testIdentity),
      ),
      relayServiceProvider.overrideWithValue(relay),
      relayPreferencesServiceProvider.overrideWith(
        (ref) async => MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: [_inbox],
            RelayCategory.keyPackage: [_kp],
          },
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RelayStatusNotifier', () {
    test('before a check, each row expects exactly the kinds its lists '
        'publish there', () async {
      final container = _container(MockRelayService());

      final state = await container.read(relayStatusProvider.future);
      final byUrl = {for (final r in state.relays) r.relayUrl: r};

      expect(byUrl[_inbox]!.own, isTrue);
      expect(byUrl[_inbox]!.keyPackage, isNull);
      expect(byUrl[_inbox]!.relayList, isNull);
      expect(byUrl[_inbox]!.inboxRelayList, KindPresence.notChecked);

      expect(byUrl[_kp]!.keyPackage, KindPresence.notChecked);
      expect(byUrl[_kp]!.relayList, KindPresence.notChecked);
      expect(byUrl[_kp]!.inboxRelayList, isNull);

      // Lookup relays hold the relay lists only — never a KeyPackage.
      for (final url in fallbackDiscoveryRelays) {
        final row = byUrl[url]!;
        expect(row.own, isFalse);
        expect(row.lookup, isTrue);
        expect(row.keyPackage, isNull, reason: url);
        expect(row.relayList, KindPresence.notChecked);
        expect(row.inboxRelayList, KindPresence.notChecked);
      }
      expect(state.relays.map((r) => r.relayUrl).take(2), [
        _inbox,
        _kp,
      ], reason: 'the own lists first, as the check orders them');
      expect(state.isRefreshing, isFalse);
      expect(state.lastChecked, isNull);
    });

    test('own rows are exactly the configured relays; the public defaults '
        'appear only as lookup relays', () async {
      // A privacy-conscious user whose ONLY relays are private. A seed relay
      // that is also a lookup relay may be listed — as a lookup relay, never
      // as one of theirs.
      final container = _container(MockRelayService());

      final state = await container.read(relayStatusProvider.future);

      expect(state.relays.where((r) => r.own).map((r) => r.relayUrl), [
        _inbox,
        _kp,
      ]);
      for (final r in state.relays.where((r) => !r.own)) {
        expect(fallbackDiscoveryRelays, contains(r.relayUrl));
        expect(r.lookup, isTrue);
      }
    });

    test(
      "the check's own rows are what is shown, each kind as judged",
      () async {
        final relay = MockRelayService()
          ..ownPresence = [
            _row(_inbox, inboxRelayList: OwnEventPresenceFfi.current),
            _row(
              _kp,
              keyPackage: OwnEventPresenceFfi.outdated,
              relayList: OwnEventPresenceFfi.missing,
            ),
            _row(
              'wss://lookup.example.com',
              own: false,
              lookup: true,
              relayList: OwnEventPresenceFfi.noAnswer,
              inboxRelayList: OwnEventPresenceFfi.noAnswer,
            ),
          ];
        final container = _container(relay);
        await container.read(relayStatusProvider.future);

        await container.read(relayStatusProvider.notifier).checkAllRelays();

        final state = container.read(relayStatusProvider).value!;
        expect(relay.ownPresenceAsks, [_testIdentity.pubkeyHex]);
        expect(state.relays, hasLength(3));
        final kp = state.relays[1];
        expect(kp.keyPackage, KindPresence.outdated);
        expect(kp.relayList, KindPresence.missing);
        expect(kp.inboxRelayList, isNull, reason: 'not expected, never asked');
        expect(state.relays[2].relayList, KindPresence.noAnswer);
        expect(
          {KindPresence.outdated, KindPresence.missing, KindPresence.noAnswer},
          hasLength(3),
          reason:
              'Missing is not "Can\'t reach", and neither is an old version',
        );
        expect(state.isRefreshing, isFalse);
        expect(state.lastChecked, isNotNull);
      },
    );

    test(
      'every expected kind reads checking while the answer is awaited',
      () async {
        final gate = Completer<void>();
        final relay = MockRelayService()..ownPresenceGate = gate;
        final container = _container(relay);
        await container.read(relayStatusProvider.future);

        final check = container
            .read(relayStatusProvider.notifier)
            .checkAllRelays();
        await pumpEventQueue();

        final mid = container.read(relayStatusProvider).value!;
        expect(mid.isRefreshing, isTrue);
        for (final r in mid.relays) {
          expect(r.expected, everyElement(KindPresence.checking));
          expect(r.expected, isNotEmpty);
        }
        expect(mid.ringSlots, everyElement(RelayRingSlotState.checking));

        gate.complete();
        await check;
        expect(
          container.read(relayStatusProvider).value!.isRefreshing,
          isFalse,
        );
      },
    );

    test('a check that cannot run reads as "Can\'t reach", never as missing, '
        'and logs no identifier', () async {
      final logs = LogCapture.install();
      addTearDown(logs.restore);
      final relay = MockRelayService()..shouldThrowOnOwnPresence = true;
      final container = _container(relay);
      await container.read(relayStatusProvider.future);

      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = container.read(relayStatusProvider).value!;
      for (final r in state.relays) {
        expect(r.expected, everyElement(KindPresence.noAnswer));
      }
      logs
        ..assertContains('[RelayStatus] check failed')
        ..assertNoNeedles([_inbox, _kp, _testIdentity.pubkeyHex]);
    });

    test('checkAllRelays is a no-op with no identity', () async {
      final relay = MockRelayService();
      final container = _container(relay, noIdentity: true);
      await container.read(relayStatusProvider.future);

      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = container.read(relayStatusProvider).value!;
      for (final r in state.relays) {
        expect(r.expected, everyElement(KindPresence.notChecked));
      }
      expect(relay.methodCalls, isEmpty);
    });

    test('checkAllRelays checks rows that are still being built', () async {
      // The Relays page calls it on its first frame, long before the rows
      // have been read from storage.
      final relay = MockRelayService()
        ..ownPresence = [
          _row(_inbox, inboxRelayList: OwnEventPresenceFfi.current),
          _row(_kp, keyPackage: OwnEventPresenceFfi.current),
        ];
      final container = _container(relay);

      await container.read(relayStatusProvider.notifier).checkAllRelays();

      final state = await container.read(relayStatusProvider.future);
      expect(relay.ownPresenceAsks, [_testIdentity.pubkeyHex]);
      expect(state.relays.map((r) => r.relayUrl), [_inbox, _kp]);
      expect(state.lastChecked, isNotNull);
    });

    test('checkAllRelays on rows that failed to build checks nothing and '
        'does not throw', () async {
      final relay = MockRelayService();
      final prefs = MockRelayPreferencesService()
        ..listThrowsFor.add(RelayCategory.keyPackage);
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => _testIdentity),
          relayServiceProvider.overrideWithValue(relay),
          relayPreferencesServiceProvider.overrideWith((ref) async => prefs),
        ],
      );
      addTearDown(container.dispose);

      await container.read(relayStatusProvider.notifier).checkAllRelays();

      expect(container.read(relayStatusProvider).hasError, isTrue);
      expect(relay.ownPresenceAsks, isEmpty);
    });
  });

  group('summarizePresence (the ring and every row dot)', () {
    test('ok only when every expected kind is current', () {
      // The defect this replaced: one kind found made the whole relay green,
      // so a relay serving the relay list but not the KeyPackage read as fine.
      expect(
        summarizePresence([KindPresence.current, KindPresence.missing]),
        RelayRingSlotState.error,
      );
      expect(
        summarizePresence([KindPresence.current, KindPresence.outdated]),
        RelayRingSlotState.error,
      );
      expect(
        summarizePresence([KindPresence.current, KindPresence.noAnswer]),
        RelayRingSlotState.error,
      );
      expect(
        summarizePresence([KindPresence.current, KindPresence.current]),
        RelayRingSlotState.ok,
      );
    });

    test('checking wins; nothing checked yet is pending', () {
      expect(
        summarizePresence([KindPresence.missing, KindPresence.checking]),
        RelayRingSlotState.checking,
      );
      expect(
        summarizePresence([KindPresence.notChecked]),
        RelayRingSlotState.pending,
      );
      expect(summarizePresence(const []), RelayRingSlotState.pending);
    });

    test('ringSlots is one summary per row, over its expected kinds', () {
      const state = RelayStatusState(
        relays: [
          RelayPresence(
            relayUrl: 'wss://a',
            own: true,
            lookup: false,
            keyPackage: KindPresence.missing,
            relayList: KindPresence.current,
          ),
          RelayPresence(
            relayUrl: 'wss://b',
            own: true,
            lookup: false,
            inboxRelayList: KindPresence.current,
          ),
        ],
      );
      expect(state.ringSlots, [
        RelayRingSlotState.error,
        RelayRingSlotState.ok,
      ]);
      expect(state.needsRepublish, isTrue);
    });

    test('an unreachable relay alone is nothing a Republish can fix', () {
      const state = RelayStatusState(
        relays: [
          RelayPresence(
            relayUrl: 'wss://a',
            own: true,
            lookup: false,
            keyPackage: KindPresence.noAnswer,
            relayList: KindPresence.current,
          ),
        ],
      );
      expect(state.needsRepublish, isFalse);
    });
  });

  group('RelayStatusNotifier.republish', () {
    test(
      'runs the publisher, then checks again, and reports all current',
      () async {
        var publishes = 0;
        final relay = MockRelayService()
          ..ownPresence = [
            _row(_inbox, inboxRelayList: OwnEventPresenceFfi.missing),
          ];
        final container = _container(
          relay,
          extra: [
            keyPackagePublisherProvider.overrideWith((ref) async {
              // Past its synchronous build, as the real publisher's writes are.
              await Future<void>.value();
              publishes++;
              relay.ownPresence = [
                _row(_inbox, inboxRelayList: OwnEventPresenceFfi.current),
                _row(
                  'wss://down.example.com',
                  own: false,
                  lookup: true,
                  relayList: OwnEventPresenceFfi.noAnswer,
                  inboxRelayList: OwnEventPresenceFfi.noAnswer,
                ),
              ];
              const kp = KeyPackageMaintenancePublished(
                relaysAcked: 1,
                isFreshSlotMinted: false,
              );
              ref.read(ownReachabilityProvider.notifier)
                ..recordRelayLists(relayListsCurrent)
                ..recordKeyPackage(kp);
              return kp;
            }),
          ],
        );
        await container.read(relayStatusProvider.future);
        await container.read(relayStatusProvider.notifier).checkAllRelays();
        expect(
          container.read(relayStatusProvider).value!.needsRepublish,
          isTrue,
        );

        final outcome = await container
            .read(relayStatusProvider.notifier)
            .republish();

        expect(publishes, 1);
        expect(relay.ownPresenceAsks, hasLength(2), reason: 'checked again');
        expect(
          outcome,
          RepublishOutcome.allCurrent,
          reason:
              'a lookup relay that did not answer is not counted '
              'against it',
        );
        expect(
          container.read(relayStatusProvider).value!.isRepublishing,
          isFalse,
        );
      },
    );

    /// Republishes against a check that answers [after].
    Future<RepublishOutcome> republishAgainst(
      List<OwnRelayPresenceFfi> after,
    ) async {
      final relay = MockRelayService()..ownPresence = after;
      final container = _container(
        relay,
        extra: [
          keyPackagePublisherProvider.overrideWith((ref) async {
            await Future<void>.value();
            const kp = KeyPackageMaintenancePublished(
              relaysAcked: 1,
              isFreshSlotMinted: false,
            );
            ref.read(ownReachabilityProvider.notifier)
              ..recordRelayLists(relayListsCurrent)
              ..recordKeyPackage(kp);
            return kp;
          }),
        ],
      );
      await container.read(relayStatusProvider.future);
      return container.read(relayStatusProvider.notifier).republish();
    }

    OwnRelayPresenceFfi ownKp(OwnEventPresenceFfi p) =>
        _row(_kp, keyPackage: p, relayList: p);
    OwnRelayPresenceFfi ownInbox(OwnEventPresenceFfi p) =>
        _row(_inbox, inboxRelayList: p);
    OwnRelayPresenceFfi lookup(OwnEventPresenceFfi p) => _row(
      fallbackDiscoveryRelays.first,
      own: false,
      lookup: true,
      relayList: p,
      inboxRelayList: p,
    );

    test('no relay answering is never reported as done', () async {
      expect(
        await republishAgainst([
          ownInbox(OwnEventPresenceFfi.noAnswer),
          ownKp(OwnEventPresenceFfi.noAnswer),
          lookup(OwnEventPresenceFfi.noAnswer),
        ]),
        RepublishOutcome.incomplete,
      );
    });

    test('a lookup relay answering does not stand in for an own relay that '
        'did not', () async {
      // The KeyPackage lives only on own relays: without one heard, nobody
      // is shown to be able to invite the user.
      expect(
        await republishAgainst([
          ownInbox(OwnEventPresenceFfi.current),
          ownKp(OwnEventPresenceFfi.noAnswer),
          lookup(OwnEventPresenceFfi.current),
        ]),
        RepublishOutcome.incomplete,
      );
    });

    test(
      'a lookup relay that answered without the lists is not done',
      () async {
        expect(
          await republishAgainst([
            ownInbox(OwnEventPresenceFfi.current),
            ownKp(OwnEventPresenceFfi.current),
            lookup(OwnEventPresenceFfi.missing),
          ]),
          RepublishOutcome.incomplete,
        );
      },
    );

    test('every own relay current is done', () async {
      expect(
        await republishAgainst([
          ownInbox(OwnEventPresenceFfi.current),
          ownKp(OwnEventPresenceFfi.current),
          lookup(OwnEventPresenceFfi.current),
        ]),
        RepublishOutcome.allCurrent,
      );
    });

    test('a relay still missing a kind after it is reported', () async {
      final relay = MockRelayService()
        ..ownPresence = [_row(_kp, keyPackage: OwnEventPresenceFfi.missing)];
      final container = _container(
        relay,
        extra: [
          keyPackagePublisherProvider.overrideWith(
            (ref) async => const KeyPackageMaintenanceFailed(
              KeyPackageFailureKind.publishNotAcked,
            ),
          ),
        ],
      );
      await container.read(relayStatusProvider.future);

      final outcome = await container
          .read(relayStatusProvider.notifier)
          .republish();

      expect(outcome, RepublishOutcome.incomplete);
    });

    test('while the storage-reset notice is unanswered it says so', () async {
      final relay = MockRelayService();
      final container = _container(
        relay,
        extra: [
          keyPackagePublisherProvider.overrideWith((ref) async {
            await Future<void>.value();
            const kp = KeyPackageMaintenanceFailed(
              KeyPackageFailureKind.awaitingResetAcknowledgement,
            );
            const held = RelayListCategoryResult(
              action: RelayListMaintenanceAction.awaitingResetAcknowledgement,
              ownConfirmed: false,
            );
            ref.read(ownReachabilityProvider.notifier)
              ..recordRelayLists(
                const RelayListMaintenanceResult(inbox: held, keyPackage: held),
              )
              ..recordKeyPackage(kp);
            return kp;
          }),
        ],
      );
      await container.read(relayStatusProvider.future);

      final outcome = await container
          .read(relayStatusProvider.notifier)
          .republish();

      expect(outcome, RepublishOutcome.heldForReset);
    });
  });
}
