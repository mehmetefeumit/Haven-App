/// Tests for the Relays page's view of the own-relay board.
///
/// Verifies that:
/// - each row expects exactly the kinds its lists publish there, and the
///   lookup rows are the relays the board says the pass asks;
/// - every board state reaches its row, joined by normalized URL, and a kind
///   the board has no cell for — or no board at all — reads not checked,
///   never a fabricated answer;
/// - a held kind reads held, with its reason;
/// - the board is read at once and every interval only while the app is in
///   front and something watches, and never after a pause or a dispose;
/// - an unchanged board notifies nobody;
/// - a publishing cell turns current at the next read with no input;
/// - opening the page runs a pass only when the board is stale;
/// - an inbox relay's gift-wrap read reaches its inbox row only, beside its
///   kinds and never one of them.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/own_relay_board.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart' show InboxRead;

import '../helpers/fake_board_source.dart';
import '../mocks/mock_relay_preferences_service.dart';

const _inbox = 'wss://inbox.example.com';
const _kp = 'wss://kp.example.com';
const _interval = Duration(milliseconds: 500);

ProviderContainer _container(
  FakeBoardSource source, {
  MockRelayPreferencesService? prefs,
}) {
  final container = ProviderContainer(
    overrides: [
      maintenanceServiceProvider.overrideWithValue(source),
      relayBoardPollIntervalProvider.overrideWithValue(_interval),
      appForegroundProvider.overrideWith((_) => true),
      relayPreferencesServiceProvider.overrideWith(
        (ref) async =>
            prefs ??
            MockRelayPreferencesService(
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

// `elapse(Duration.zero)` rather than a microtask flush: Riverpod schedules
// a dependent's rebuild on the event queue.

/// Keeps the auto-disposed provider alive, as the page does, and lets the
/// relay lists load.
Future<void> _watch(ProviderContainer c) async {
  c.listen(relayStatusProvider, (_, _) {});
  await c.read(inboxRelaysProvider.future);
  await c.read(keyPackageRelaysProvider.future);
}

Map<String, RelayPresence> _byUrl(RelayStatusState s) => {
  for (final r in s.relays) r.relayUrl: r,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('relayStatusProvider rows', () {
    test('without a board, each row expects exactly the kinds its lists '
        'publish there, and none is checked', () async {
      final c = _container(FakeBoardSource());
      await _watch(c);

      final state = c.read(relayStatusProvider);
      final byUrl = _byUrl(state);
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
      expect(state.relays.map((r) => r.relayUrl).take(2), [_inbox, _kp]);
      expect(state.holds, isEmpty);
      expect(state.running, isFalse);
    });

    test('own rows are exactly the configured relays; the public defaults '
        'appear only as lookup relays', () async {
      final c = _container(FakeBoardSource());
      await _watch(c);

      final state = c.read(relayStatusProvider);
      expect(state.relays.where((r) => r.own).map((r) => r.relayUrl), [
        _inbox,
        _kp,
      ]);
      for (final r in state.relays.where((r) => !r.own)) {
        expect(fallbackDiscoveryRelays, contains(r.relayUrl));
        expect(r.lookup, isTrue);
      }
    });

    test("an inbox relay's gift-wrap read reaches its inbox row only, "
        'whatever spelling the pass used, and is never one of its kinds', () {
      const both = 'wss://both.example.com';
      for (final read in InboxRead.values) {
        final state = relayStatusOf(
          const [_inbox, both],
          const [_kp, both],
          OwnRelayBoard(
            inboxRelayList: const OwnKindBoard(
              cells: [
                OwnRelayCell(relayUrl: _inbox, status: OwnRelayStatus.current),
              ],
            ),
            inboxReads: [
              OwnInboxRead(relayUrl: 'WSS://Inbox.Example.com/', read: read),
              OwnInboxRead(relayUrl: both, read: read),
              // A relay no list names any more: its answer reaches no row.
              OwnInboxRead(relayUrl: _kp, read: read),
            ],
          ),
        );
        final byUrl = _byUrl(state);
        expect(byUrl[_inbox]!.inboxRead, read, reason: read.name);
        expect(byUrl[both]!.inboxRead, read, reason: read.name);
        expect(byUrl[_kp]!.inboxRead, isNull, reason: 'not an inbox relay');
        expect(
          byUrl[_inbox]!.expected,
          [KindPresence.current],
          reason: 'the read is never one of the kinds a pass publishes',
        );
        for (final r in state.relays.where((r) => !r.own)) {
          expect(r.inboxRead, isNull, reason: 'a lookup row is never asked');
        }
      }

      final unasked = relayStatusOf(const [_inbox], const [_kp], null);
      expect(_byUrl(unasked)[_inbox]!.inboxRead, isNull);
    });

    test('a changed gift-wrap read alone is a changed state', () {
      RelayStatusState of(InboxRead read) => relayStatusOf(
        const [_inbox],
        const [_kp],
        OwnRelayBoard(
          inboxReads: [OwnInboxRead(relayUrl: _inbox, read: read)],
        ),
      );
      expect(of(InboxRead.refused), of(InboxRead.refused));
      expect(of(InboxRead.refused), isNot(of(InboxRead.served)));
    });

    test('the lookup rows are the relays the board says the pass asks', () {
      final state = relayStatusOf(
        const [_inbox],
        const [_kp],
        const OwnRelayBoard(
          lookupRelays: ['wss://look-a.example.com', 'wss://look-b.example'],
        ),
      );

      expect(state.relays.where((r) => r.lookup).map((r) => r.relayUrl), [
        'wss://look-a.example.com',
        'wss://look-b.example',
      ]);
    });

    test('every board state reaches its row, whatever spelling the pass '
        'used for the relay', () {
      for (final status in OwnRelayStatus.values) {
        final state = relayStatusOf(
          const [_inbox],
          const [_kp],
          OwnRelayBoard(
            keyPackage: OwnKindBoard(
              cells: [
                // The pass spells the relay as the pool parsed it.
                OwnRelayCell(relayUrl: 'wss://KP.example.com/', status: status),
              ],
            ),
          ),
        );
        final expected = switch (status) {
          OwnRelayStatus.checking => KindPresence.checking,
          OwnRelayStatus.current => KindPresence.current,
          OwnRelayStatus.publishing => KindPresence.publishing,
          OwnRelayStatus.missing => KindPresence.missing,
          OwnRelayStatus.outdated => KindPresence.outdated,
          OwnRelayStatus.refused => KindPresence.refused,
          OwnRelayStatus.unconfirmed => KindPresence.unconfirmed,
          OwnRelayStatus.noAnswer => KindPresence.noAnswer,
        };
        expect(_byUrl(state)[_kp]!.keyPackage, expected, reason: '$status');
        expect(
          _byUrl(state)[_kp]!.relayList,
          KindPresence.notChecked,
          reason: 'another kind of the same relay has no cell yet',
        );
      }
    });

    test('a held kind reads held on every row that expects it, with its '
        'reason; the other kinds keep their cells', () {
      final state = relayStatusOf(
        const [_inbox],
        const [_kp],
        const OwnRelayBoard(
          lookupRelays: ['wss://look.example.com'],
          keyPackage: OwnKindBoard(
            hold: OwnPublishHold.awaitingResetAcknowledgement,
          ),
          relayList: OwnKindBoard(
            hold: OwnPublishHold.awaitingResetAcknowledgement,
          ),
          inboxRelayList: OwnKindBoard(
            cells: [
              OwnRelayCell(relayUrl: _inbox, status: OwnRelayStatus.current),
            ],
          ),
        ),
      );
      final byUrl = _byUrl(state);

      expect(byUrl[_kp]!.keyPackage, KindPresence.held);
      expect(byUrl[_kp]!.relayList, KindPresence.held);
      expect(byUrl['wss://look.example.com']!.relayList, KindPresence.held);
      expect(byUrl[_inbox]!.inboxRelayList, KindPresence.current);
      expect(state.holds, {
        RelayKind.keyPackage: OwnPublishHold.awaitingResetAcknowledgement,
        RelayKind.relayList: OwnPublishHold.awaitingResetAcknowledgement,
      });
    });

    test('a running pass is reported', () {
      expect(
        relayStatusOf(
          const [],
          const [],
          const OwnRelayBoard(running: true),
        ).running,
        isTrue,
      );
    });

    test('a list edit rebuilds the rows at once; the new relay reads not '
        'checked until the board has a cell for it', () async {
      final source = FakeBoardSource()
        ..board = const OwnRelayBoard(
          inboxRelayList: OwnKindBoard(
            cells: [
              OwnRelayCell(relayUrl: _inbox, status: OwnRelayStatus.current),
            ],
          ),
        );
      final c = _container(source);
      await _watch(c);

      await c
          .read(inboxRelaysProvider.notifier)
          .addRelay('wss://added.example.com');

      final byUrl = _byUrl(c.read(relayStatusProvider));
      expect(
        byUrl['wss://added.example.com']!.inboxRelayList,
        KindPresence.notChecked,
      );
      expect(byUrl[_inbox]!.inboxRelayList, KindPresence.current);
    });
  });

  group('relayStatusProvider reads', () {
    test('at once and every interval while in front and watched; nothing '
        'after a pause, again at once on return, nothing after a dispose', () {
      fakeAsync((async) {
        final source = FakeBoardSource();
        final c = ProviderContainer(
          overrides: [
            maintenanceServiceProvider.overrideWithValue(source),
            relayBoardPollIntervalProvider.overrideWithValue(_interval),
            appForegroundProvider.overrideWith((_) => true),
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
        async.elapse(Duration.zero);
        expect(source.reads, 0, reason: 'nothing reads before a watcher');

        final sub = c.listen(relayStatusProvider, (_, _) {});
        async.elapse(Duration.zero);
        expect(source.reads, greaterThan(0), reason: 'read at once');

        var before = source.reads;
        async.elapse(_interval * 4);
        expect(source.reads, before + 4);

        c.read(appForegroundProvider.notifier).state = false;
        async.elapse(Duration.zero);
        before = source.reads;
        async.elapse(_interval * 10);
        expect(source.reads, before, reason: 'no read in the background');

        c.read(appForegroundProvider.notifier).state = true;
        async.elapse(Duration.zero);
        expect(source.reads, before + 1, reason: 'read at once on return');
        async.elapse(_interval);
        expect(source.reads, before + 2);

        sub.close();
        async.elapse(Duration.zero);
        before = source.reads;
        async.elapse(_interval * 10);
        expect(source.reads, before, reason: 'no read once nothing watches');
        c.dispose();
      });
    });

    test('a publishing cell turns current at the next read, with no input', () {
      fakeAsync((async) {
        final source = FakeBoardSource()
          ..board = const OwnRelayBoard(
            keyPackage: OwnKindBoard(
              cells: [
                OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.publishing),
              ],
            ),
          );
        final c = _container(source)..listen(relayStatusProvider, (_, _) {});
        async.elapse(Duration.zero);
        expect(
          _byUrl(c.read(relayStatusProvider))[_kp]!.keyPackage,
          KindPresence.publishing,
        );

        source.board = const OwnRelayBoard(
          keyPackage: OwnKindBoard(
            cells: [
              OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.current),
            ],
          ),
        );
        async.elapse(_interval);

        expect(
          _byUrl(c.read(relayStatusProvider))[_kp]!.keyPackage,
          KindPresence.current,
        );
      });
    });

    test('an unchanged board notifies nobody, however often it is read', () {
      fakeAsync((async) {
        const board = OwnRelayBoard(
          keyPackage: OwnKindBoard(
            checkedSecsAgo: 3,
            cells: [
              OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.current),
            ],
          ),
        );
        final source = FakeBoardSource()..board = board;
        final c = _container(source);
        var notified = 0;
        c.listen(relayStatusProvider, (_, _) => notified++);
        async.elapse(Duration.zero);
        final settled = notified;

        // A fresh but equal snapshot every read, and an age that moves: the
        // rendered rows do not change, so nothing is told.
        for (var i = 0; i < 6; i++) {
          source.board = OwnRelayBoard(
            keyPackage: OwnKindBoard(
              checkedSecsAgo: 4 + i,
              cells: const [
                OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.current),
              ],
            ),
          );
          async.elapse(_interval);
        }
        expect(source.reads, greaterThanOrEqualTo(6));
        expect(notified, settled);

        source.board = const OwnRelayBoard(
          keyPackage: OwnKindBoard(
            cells: [
              OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.missing),
            ],
          ),
        );
        async.elapse(_interval);
        expect(notified, settled + 1, reason: 'a change is told');
      });
    });
  });

  group('ownRelayBoardIsStale (the page-open pass)', () {
    OwnKindBoard checked(int secs) => OwnKindBoard(checkedSecsAgo: secs);
    const tenMinutes = 600;

    test('does not ask while no session is open', () {
      expect(ownRelayBoardIsStale(null), isFalse);
    });

    test('asks when a kind has no finished pass in this session', () {
      expect(
        ownRelayBoardIsStale(
          OwnRelayBoard(keyPackage: checked(1), relayList: checked(1)),
        ),
        isTrue,
      );
    });

    test('asks when a kind was last checked more than ten minutes ago', () {
      expect(
        ownRelayBoardIsStale(
          OwnRelayBoard(
            keyPackage: checked(1),
            relayList: checked(tenMinutes + 1),
            inboxRelayList: checked(1),
          ),
        ),
        isTrue,
      );
    });

    test('does not ask when every kind was checked within ten minutes', () {
      expect(
        ownRelayBoardIsStale(
          OwnRelayBoard(
            keyPackage: checked(tenMinutes),
            relayList: checked(5),
            inboxRelayList: checked(0),
          ),
        ),
        isFalse,
      );
    });

    test('never asks while a pass is running or queued', () {
      expect(ownRelayBoardIsStale(const OwnRelayBoard(running: true)), isFalse);
    });

    test('skips a kind held for the reset notice or an empty list, but asks '
        'for one held by a stored publish setting', () {
      for (final hold in [
        OwnPublishHold.awaitingResetAcknowledgement,
        OwnPublishHold.noRelaysConfigured,
      ]) {
        expect(
          ownRelayBoardIsStale(
            OwnRelayBoard(
              keyPackage: OwnKindBoard(hold: hold),
              relayList: OwnKindBoard(hold: hold),
              inboxRelayList: checked(1),
            ),
          ),
          isFalse,
          reason: '$hold: a pass would hold it again',
        );
      }
      expect(
        ownRelayBoardIsStale(
          OwnRelayBoard(
            keyPackage: checked(1),
            relayList: checked(1),
            inboxRelayList: const OwnKindBoard(
              hold: OwnPublishHold.publishingSuppressed,
            ),
          ),
        ),
        isTrue,
      );
    });
  });
}
