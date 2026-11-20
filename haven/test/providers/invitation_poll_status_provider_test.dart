/// Tests for [invitationPollStatusProvider] / [InvitationPollStatusNotifier].
///
/// Verifies the accuracy-critical pieces of the Invitations refresh status:
/// - [InvitationPollStatusNotifier.categorizeOutcome] maps every tally to the
///   right outcome, and reads "up to date" only when every relay served the
///   read in full and nothing failed (pure, exhaustive).
/// - `refresh()` counts only a served read as read — a refused, unfinished or
///   unreachable one is not, whatever it handed back — de-duplicates gift
///   wraps across relays, and short-circuits with no inbox.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart'
    show
        fallbackInboxGiftWrapLookback,
        invitationClockProvider,
        pendingInvitationsProvider;
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

RelayGiftWrapFetch _fetch(
  String url,
  InboxRead read, {
  List<String> events = const [],
}) => RelayGiftWrapFetch(relayUrl: url, read: read, events: events);

/// A relay that served the read in full, optionally carrying gift wraps.
RelayGiftWrapFetch _ok(String url, {List<String> events = const []}) =>
    _fetch(url, InboxRead.served, events: events);

/// A relay that could not be reached.
RelayGiftWrapFetch _down(String url) => _fetch(url, InboxRead.unreached);

/// Spins the microtask/timer queue until [condition] holds (or a tick cap is
/// reached), so a test can observe an intermediate in-flight state without
/// racing the notifier's internal awaits.
Future<void> _pumpUntil(bool Function() condition, {int maxTicks = 100}) async {
  for (var i = 0; i < maxTicks && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (!condition()) {
    fail('_pumpUntil: condition not satisfied after $maxTicks ticks');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('categorizeOutcome', () {
    InvitationPollOutcome categorize({
      required int total,
      int served = 0,
      int refused = 0,
      int unreached = 0,
      int notSaved = 0,
      int newCount = 0,
    }) => InvitationPollStatusNotifier.categorizeOutcome(
      total: total,
      served: served,
      refused: refused,
      unreached: unreached,
      notSaved: notSaved,
      newCount: newCount,
    );

    test('no relays -> noInbox', () {
      expect(categorize(total: 0), InvitationPollOutcome.noInbox);
    });

    test('nobody reached -> offline', () {
      expect(categorize(total: 3, unreached: 3), InvitationPollOutcome.offline);
    });

    test('every relay reached, none finished -> incomplete, not offline', () {
      // "Couldn't reach" would be false: the relays were reached.
      expect(categorize(total: 2), InvitationPollOutcome.incomplete);
    });

    test('new invitations -> newInvites when every relay served', () {
      expect(
        categorize(total: 3, served: 3, newCount: 2),
        InvitationPollOutcome.newInvites,
      );
    });

    test('a relay not read in full outranks new invitations', () {
      // The new invitation is in the list either way; the notice still has
      // to say that not every relay was read.
      expect(
        categorize(total: 3, served: 1, unreached: 2, newCount: 1),
        InvitationPollOutcome.incomplete,
      );
    });

    test('some served, the rest unreached, nothing new -> incomplete', () {
      expect(
        categorize(total: 3, served: 2, unreached: 1),
        InvitationPollOutcome.incomplete,
      );
    });

    test('a refused relay outranks everything but a missing inbox', () {
      expect(
        categorize(total: 3, served: 2, refused: 1, notSaved: 1, newCount: 1),
        InvitationPollOutcome.refused,
      );
      expect(categorize(total: 1, refused: 1), InvitationPollOutcome.refused);
    });

    test('an invitation not saved outranks an unreachable relay', () {
      expect(
        categorize(total: 2, served: 1, unreached: 1, notSaved: 1),
        InvitationPollOutcome.notSaved,
      );
    });

    test('all served, nothing new -> upToDate', () {
      expect(categorize(total: 3, served: 3), InvitationPollOutcome.upToDate);
      expect(categorize(total: 1, served: 1), InvitationPollOutcome.upToDate);
    });

    test('upToDate if and only if every relay served, nothing failed to save '
        'and nothing is new', () {
      for (var total = 1; total <= 3; total++) {
        for (var served = 0; served <= total; served++) {
          for (var refused = 0; served + refused <= total; refused++) {
            for (
              var unreached = 0;
              served + refused + unreached <= total;
              unreached++
            ) {
              for (final notSaved in const [0, 1]) {
                for (final newCount in const [0, 1]) {
                  final outcome = categorize(
                    total: total,
                    served: served,
                    refused: refused,
                    unreached: unreached,
                    notSaved: notSaved,
                    newCount: newCount,
                  );
                  final tally =
                      'total $total served $served refused $refused '
                      'unreached $unreached notSaved $notSaved new $newCount';
                  expect(
                    outcome == InvitationPollOutcome.upToDate,
                    served == total && notSaved == 0 && newCount == 0,
                    reason: tally,
                  );
                  if (refused > 0) {
                    expect(
                      outcome,
                      InvitationPollOutcome.refused,
                      reason: tally,
                    );
                  }
                }
              }
            }
          }
        }
      }
    });
  });

  group('InvitationPollStatus', () {
    test('idle defaults', () {
      const idle = InvitationPollStatus.idle;
      expect(idle.phase, InvitationPollPhase.idle);
      expect(idle.total, 0);
      expect(idle.served, 0);
      expect(idle.refused, 0);
      expect(idle.unreached, 0);
      expect(idle.notSaved, 0);
      expect(idle.newCount, 0);
      expect(idle.outcome, isNull);
    });
  });

  group('refresh()', () {
    ProviderContainer makeContainer({
      required List<String> inboxRelays,
      required bool identityExists,
      MockRelayService? relayService,
      MockCircleService? circleService,
      _MockIdentityService? identityService,
      DateTime Function()? now,
    }) {
      final container = ProviderContainer(
        overrides: [
          if (now != null) invitationClockProvider.overrideWithValue(now),
          identityServiceProvider.overrideWithValue(
            identityService ??
                _MockIdentityService(identityExists: identityExists),
          ),
          circleServiceProvider.overrideWithValue(
            circleService ?? MockCircleService(),
          ),
          relayServiceProvider.overrideWithValue(
            relayService ?? MockRelayService(),
          ),
          inboxRelaysProvider.overrideWith(() => _StubInboxRelays(inboxRelays)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('no inbox relays -> settled/noInbox, never pings', () async {
      final relay = MockRelayService();
      final container = makeContainer(
        inboxRelays: const [],
        identityExists: true,
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.phase, InvitationPollPhase.settled);
      expect(state.outcome, InvitationPollOutcome.noInbox);
      expect(state.total, 0);
      // Privacy: an empty inbox must NOT trigger any relay ping.
      expect(relay.methodCalls, isNot(contains('fetchGiftWrapsPerRelay')));
    });

    test('asks each inbox relay for gift wraps, and no other relay', () async {
      final asked = <String>[];
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          asked.addAll(relays);
          return [for (final r in relays) _ok(r)];
        };
      final container = makeContainer(
        inboxRelays: const ['wss://inbox-a', 'wss://inbox-b'],
        identityExists: true,
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();

      expect(asked..sort(), ['wss://inbox-a', 'wss://inbox-b']);
    });

    test("looks back the engine's inbox lookback, as the poller", () async {
      final relay = MockRelayService();
      final now = DateTime.utc(2026, 10, 16, 12);
      final container = makeContainer(
        inboxRelays: const ['wss://a'],
        identityExists: true,
        relayService: relay,
        now: () => now,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();

      expect(
        relay.lastGiftWrapSince,
        now.subtract(fallbackInboxGiftWrapLookback),
        reason: 'a manual refresh asks for a window other than the poller',
      );
    });

    test('no identity -> stays idle', () async {
      final container = makeContainer(
        inboxRelays: const ['wss://a'],
        identityExists: false,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.phase, InvitationPollPhase.idle);
    });

    test(
      'all relays serve the read, nothing new -> upToDate with exact counts',
      () async {
        final relay = MockRelayService()
          ..fetchGiftWrapsPerRelayHandler = (relays) async => [
            for (final r in relays) _ok(r),
          ];
        final container = makeContainer(
          inboxRelays: const ['wss://a', 'wss://b'],
          identityExists: true,
          relayService: relay,
        );

        await container.read(invitationPollStatusProvider.notifier).refresh();
        final state = container.read(invitationPollStatusProvider);

        expect(state.outcome, InvitationPollOutcome.upToDate);
        expect(state.total, 2);
        expect(state.served, 2);
        expect(state.newCount, 0);
      },
    );

    test(
      'some relays unreachable -> incomplete with exact counts',
      () async {
        // Per-relay fan-out: each call receives a single-relay list, so key the
        // outcome off the relay URL rather than a positional index.
        final relay = MockRelayService()
          ..fetchGiftWrapsPerRelayHandler = (relays) async {
            final url = relays.single;
            return [if (url == 'wss://c') _down(url) else _ok(url)];
          };
        final container = makeContainer(
          inboxRelays: const ['wss://a', 'wss://b', 'wss://c'],
          identityExists: true,
          relayService: relay,
        );

        await container.read(invitationPollStatusProvider.notifier).refresh();
        final state = container.read(invitationPollStatusProvider);

        expect(state.outcome, InvitationPollOutcome.incomplete);
        expect(state.total, 3);
        expect(state.served, 2);
        expect(state.unreached, 1);
      },
    );

    test('no relay answers -> offline', () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          for (final r in relays) _down(r),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://a', 'wss://b'],
        identityExists: true,
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.outcome, InvitationPollOutcome.offline);
      expect(state.served, 0);
      expect(state.unreached, 2);
    });

    test('new invitation -> newInvites, list refreshed', () async {
      final circle = MockCircleService();
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _ok(relays[0], events: const ['{"id":"event-1"}']),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://a'],
        identityExists: true,
        relayService: relay,
        circleService: circle,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.outcome, InvitationPollOutcome.newInvites);
      expect(state.newCount, 1);
      expect(circle.methodCalls, contains('processGiftWrappedInvitation'));
    });

    test(
      'a superseded rapid refresh does not overwrite the newer result',
      () async {
        // With the per-relay fan-out, refresh #1 issues one query PER relay.
        // Park BOTH of them (one completer each) so the whole of #1 is in
        // flight, past its per-relay guards, when #2 supersedes and settles.
        // When #1 finally resolves, every closure must drop its stale write at
        // the generation guard — gating only the first relay would miss a
        // second-relay write racing the newer result.
        final entered = [Completer<void>(), Completer<void>()];
        final gate = [Completer<void>(), Completer<void>()];
        var firstRefreshCalls = 0;
        var supersededStarted = false;
        final relay = MockRelayService()
          ..fetchGiftWrapsPerRelayHandler = (relays) async {
            final url = relays.single;
            if (!supersededStarted) {
              final i = firstRefreshCalls++;
              entered[i].complete();
              await gate[i].future;
              // Would categorise as offline — must be discarded.
              return [_down(url)];
            }
            return [_ok(url)];
          };
        final container = makeContainer(
          inboxRelays: const ['wss://a', 'wss://b'],
          identityExists: true,
          relayService: relay,
        );
        final notifier = container.read(invitationPollStatusProvider.notifier);

        final first = notifier.refresh();
        // Wait until BOTH relay queries of #1 are parked mid-fetch.
        await Future.wait([entered[0].future, entered[1].future]);
        supersededStarted = true;
        final second = notifier.refresh();
        await second;

        // Newer refresh wins.
        expect(
          container.read(invitationPollStatusProvider).outcome,
          InvitationPollOutcome.upToDate,
        );

        gate[0].complete();
        gate[1].complete();
        await first;

        // The superseded refresh must not clobber the newer settled state.
        expect(
          container.read(invitationPollStatusProvider).outcome,
          InvitationPollOutcome.upToDate,
        );
      },
    );

    test('identical gift wrap on two relays is processed once', () async {
      final circle = MockCircleService();
      // The identical event arrives from both relays (each call now receives a
      // single-relay list, so return one outcome per call carrying that event).
      const sameEvent = '{"id":"dup-1"}';
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _ok(relays.single, events: const [sameEvent]),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://a', 'wss://b'],
        identityExists: true,
        relayService: relay,
        circleService: circle,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.newCount, 1);
      expect(
        circle.methodCalls.where((c) => c == 'processGiftWrappedInvitation'),
        hasLength(1),
      );
    });
  });

  group('refresh() — what counts as read', () {
    ProviderContainer makeContainer({
      required List<String> inboxRelays,
      required MockRelayService relayService,
      MockCircleService? circleService,
    }) {
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(identityExists: true),
          ),
          circleServiceProvider.overrideWithValue(
            circleService ?? MockCircleService(),
          ),
          relayServiceProvider.overrideWithValue(relayService),
          inboxRelaysProvider.overrideWith(() => _StubInboxRelays(inboxRelays)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a refused relay with zero events is never upToDate', () async {
      // The root cause: a relay that will not hand over gift wraps answered
      // the handshake, and that used to paint it green, "up to date".
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _fetch(relays.single, InboxRead.refused),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://gated'],
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.outcome, InvitationPollOutcome.refused);
      expect(state.slots, const [RelayRingSlotState.error]);
      expect(state.refused, 1);
      expect(state.served, 0);
    });

    test('a refused relay beside a served one is still refused, and the '
        "served one's invitation is taken in and the list reloaded", () async {
      final circle = MockCircleService();
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          final url = relays.single;
          return [
            if (url == 'wss://gated')
              _fetch(url, InboxRead.refused)
            else
              _ok(url, events: const ['{"id":"wrap-1"}']),
          ];
        };
      final container = makeContainer(
        inboxRelays: const ['wss://gated', 'wss://open'],
        relayService: relay,
        circleService: circle,
      );
      await container.read(pendingInvitationsProvider.future);
      final listLoads = circle.methodCalls
          .where((c) => c == 'getPendingInvitations')
          .length;

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);
      await container.read(pendingInvitationsProvider.future);

      expect(state.outcome, InvitationPollOutcome.refused);
      expect(state.slots, const [
        RelayRingSlotState.error,
        RelayRingSlotState.ok,
      ]);
      expect(state.newCount, 1);
      expect(
        circle.methodCalls.where((c) => c == 'getPendingInvitations'),
        hasLength(listLoads + 1),
        reason: 'a new invitation reloads the list whatever the notice says',
      );
    });

    test('a wrap that arrived on a refused or unfinished read is processed '
        'too', () async {
      final processed = <String>[];
      final circle = MockCircleService()
        ..processGiftWrappedInvitationHandler = (json) async {
          processed.add(json);
          return null;
        };
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          final url = relays.single;
          return [
            if (url == 'wss://gated')
              _fetch(url, InboxRead.refused, events: const ['{"id":"r"}'])
            else
              _fetch(url, InboxRead.incomplete, events: const ['{"id":"i"}']),
          ];
        };
      final container = makeContainer(
        inboxRelays: const ['wss://gated', 'wss://slow'],
        relayService: relay,
        circleService: circle,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();

      expect(processed..sort(), ['{"id":"i"}', '{"id":"r"}']);
    });

    test('an unfinished read: incomplete, not offline or upToDate', () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _fetch(relays.single, InboxRead.incomplete),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://a', 'wss://b'],
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.outcome, InvitationPollOutcome.incomplete);
      expect(state.slots, const [
        RelayRingSlotState.error,
        RelayRingSlotState.error,
      ]);
    });

    test('a wrap that is no invitation this device can open leaves the '
        'refresh upToDate', () async {
      // Anyone who knows the npub can send a wrap that decrypts and carries
      // nothing usable; the service answers it as null, like a duplicate, so
      // it can never raise a notice.
      final circle = MockCircleService()
        ..processGiftWrappedInvitationHandler = (_) async => null;
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _ok(relays.single, events: const ['{"id":"junk-1"}']),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://a'],
        relayService: relay,
        circleService: circle,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(circle.methodCalls, contains('processGiftWrappedInvitation'));
      expect(state.outcome, InvitationPollOutcome.upToDate);
      expect(state.notSaved, 0);
    });

    test('an invitation that could not be saved is counted and shown; any '
        'other processing failure stays silent', () async {
      final circle = MockCircleService()
        ..processGiftWrappedInvitationHandler = (json) async =>
            throw json.contains('store')
            ? const InvitationNotSavedException()
            : const CircleServiceException('other');
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _ok(
            relays.single,
            events: const [
              '{"id":"store-1"}',
              '{"id":"store-2"}',
              '{"id":"other-1"}',
            ],
          ),
        ];
      final container = makeContainer(
        inboxRelays: const ['wss://a'],
        relayService: relay,
        circleService: circle,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();
      final state = container.read(invitationPollStatusProvider);

      expect(state.outcome, InvitationPollOutcome.notSaved);
      expect(state.notSaved, 2);
      expect(state.newCount, 0);

      circle.processGiftWrappedInvitationHandler = (_) async =>
          throw const CircleServiceException('other');
      await container.read(invitationPollStatusProvider.notifier).refresh();
      expect(
        container.read(invitationPollStatusProvider).outcome,
        InvitationPollOutcome.upToDate,
      );
    });
  });

  group('refresh() ring slots', () {
    ProviderContainer makeContainer({
      required List<String> inboxRelays,
      MockRelayService? relayService,
      _MockIdentityService? identityService,
    }) {
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            identityService ?? _MockIdentityService(identityExists: true),
          ),
          circleServiceProvider.overrideWithValue(MockCircleService()),
          relayServiceProvider.overrideWithValue(
            relayService ?? MockRelayService(),
          ),
          inboxRelaysProvider.overrideWith(() => _StubInboxRelays(inboxRelays)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'slots are all checking in flight, then all ok once settled',
      () async {
        final gate = Completer<void>();
        final relay = MockRelayService()
          ..fetchGiftWrapsPerRelayHandler = (relays) async {
            await gate.future;
            return [_ok(relays.single)];
          };
        final container = makeContainer(
          inboxRelays: const ['wss://a', 'wss://b'],
          relayService: relay,
        );
        final notifier = container.read(invitationPollStatusProvider.notifier);

        final future = notifier.refresh();
        // Let the checking-state write land (after the identity + inbox reads).
        await _pumpUntil(
          () =>
              container.read(invitationPollStatusProvider).phase ==
              InvitationPollPhase.checking,
        );

        expect(container.read(invitationPollStatusProvider).slots, const [
          RelayRingSlotState.checking,
          RelayRingSlotState.checking,
        ]);

        gate.complete();
        await future;

        final settled = container.read(invitationPollStatusProvider);
        expect(settled.phase, InvitationPollPhase.settled);
        expect(settled.slots, const [
          RelayRingSlotState.ok,
          RelayRingSlotState.ok,
        ]);
      },
    );

    test('a reachable relay maps to ok, an unreachable one to error', () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          final url = relays.single;
          return [if (url == 'wss://b') _down(url) else _ok(url)];
        };
      final container = makeContainer(
        inboxRelays: const ['wss://a', 'wss://b'],
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();

      final state = container.read(invitationPollStatusProvider);
      expect(state.slots, const [
        RelayRingSlotState.ok,
        RelayRingSlotState.error,
      ]);
      expect(state.outcome, InvitationPollOutcome.incomplete);
    });

    test('a refused or unfinished read is an error slot, not ok', () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          final url = relays.single;
          return [
            _fetch(
              url,
              url == 'wss://a' ? InboxRead.refused : InboxRead.incomplete,
            ),
          ];
        };
      final container = makeContainer(
        inboxRelays: const ['wss://a', 'wss://b'],
        relayService: relay,
      );

      await container.read(invitationPollStatusProvider.notifier).refresh();

      expect(container.read(invitationPollStatusProvider).slots, const [
        RelayRingSlotState.error,
        RelayRingSlotState.error,
      ]);
    });

    test(
      'an empty per-relay result is treated as an error slot (defensive)',
      () async {
        // A single-URL query must return exactly one outcome; an empty list
        // is a contract violation that must fail safe (error slot, not crash).
        final relay = MockRelayService()
          ..fetchGiftWrapsPerRelayHandler = (relays) async => const [];
        final container = makeContainer(
          inboxRelays: const ['wss://a'],
          relayService: relay,
        );

        await container.read(invitationPollStatusProvider.notifier).refresh();

        final state = container.read(invitationPollStatusProvider);
        expect(state.slots, const [RelayRingSlotState.error]);
        expect(state.served, 0);
        expect(state.outcome, InvitationPollOutcome.offline);
      },
    );

    test('a superseded refresh never fetches secret bytes (Rule #9)', () async {
      final identity = _MockIdentityService(identityExists: true);
      final gate = Completer<void>();
      var supersededStarted = false;
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          final url = relays.single;
          if (!supersededStarted) {
            await gate.future;
            // #1 finds a new gift wrap — which WOULD trigger a secret fetch
            // were it not superseded by the time it resolves.
            return [
              _ok(url, events: const ['{"id":"stale-1"}']),
            ];
          }
          return [_ok(url)]; // #2: nothing new, so no secret fetch.
        };
      final container = makeContainer(
        inboxRelays: const ['wss://a'],
        relayService: relay,
        identityService: identity,
      );
      final notifier = container.read(invitationPollStatusProvider.notifier);

      final first = notifier.refresh();
      await _pumpUntil(
        () =>
            container.read(invitationPollStatusProvider).phase ==
            InvitationPollPhase.checking,
      );
      supersededStarted = true;
      await notifier.refresh(); // #2 settles upToDate.

      gate.complete();
      await first; // #1 resolves, sees it is superseded, drops everything.

      expect(
        container.read(invitationPollStatusProvider).outcome,
        InvitationPollOutcome.upToDate,
      );
      // The superseded refresh must never have read the identity secret.
      expect(identity.secretBytesCalls, 0);
    });
  });
}

/// Inbox-relay notifier stub returning a fixed list, bypassing seeding so
/// tests get exact control (including an empty inbox).
class _StubInboxRelays extends InboxRelaysNotifier {
  _StubInboxRelays(this._relays);

  final List<String> _relays;

  @override
  Future<List<String>> build() async => _relays;
}

/// Minimal identity service: one test identity (or none) plus secret bytes.
class _MockIdentityService implements IdentityService {
  _MockIdentityService({required this.identityExists});

  final bool identityExists;

  /// Number of times [getSecretBytes] was invoked — lets a test assert that a
  /// superseded refresh never reaches the secret fetch (Security Rule #9).
  int secretBytesCalls = 0;

  static final _identity = Identity(
    pubkeyHex:
        'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
    npub: 'npub1test',
    createdAt: DateTime(2024),
  );

  @override
  Future<Identity?> getIdentity() async => identityExists ? _identity : null;

  @override
  Future<List<int>> getSecretBytes() async {
    secretBytesCalls++;
    return List<int>.generate(32, (i) => i);
  }

  @override
  Future<bool> hasIdentity() async => identityExists;

  @override
  Future<Identity> createIdentity() async => _identity;

  @override
  Future<Identity> importFromNsec(String nsec) async => _identity;

  @override
  Future<String> exportNsec() async => 'nsec1test';

  @override
  Future<String> sign(Uint8List messageHash) async => 'signature';

  @override
  Future<String> getPubkeyHex() async => _identity.pubkeyHex;

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}
