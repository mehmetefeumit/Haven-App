/// Tests for [invitationPollStatusProvider] / [InvitationPollStatusNotifier].
///
/// Verifies the accuracy-critical pieces of the Invitations "Settle Pill":
/// - [InvitationPollStatusNotifier.categorizeOutcome] maps every tally to the
///   right outcome (pure, exhaustive).
/// - `refresh()` produces exact answered/total counts from per-relay outcomes,
///   de-duplicates gift wraps across relays, and short-circuits with no inbox.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

/// A relay that answered, optionally carrying gift-wrap events.
RelayGiftWrapFetch _ok(String url, {List<String> events = const []}) =>
    RelayGiftWrapFetch(relayUrl: url, responded: true, events: events);

/// A relay that did not answer.
RelayGiftWrapFetch _down(String url) =>
    RelayGiftWrapFetch(relayUrl: url, responded: false, events: const []);

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
    InvitationPollOutcome categorize(int total, int responded, int newCount) =>
        InvitationPollStatusNotifier.categorizeOutcome(
          total: total,
          responded: responded,
          newCount: newCount,
        );

    test('no relays -> noInbox', () {
      expect(categorize(0, 0, 0), InvitationPollOutcome.noInbox);
    });

    test('nobody answered -> offline', () {
      expect(categorize(3, 0, 0), InvitationPollOutcome.offline);
    });

    test('new invitations -> newInvites (even when fully answered)', () {
      expect(categorize(3, 3, 2), InvitationPollOutcome.newInvites);
    });

    test('new invitations take priority over a partial answer', () {
      // 1 of 3 answered but it carried a new invite: the user got their
      // invitation, which is the headline — not the unreachable relays.
      expect(categorize(3, 1, 1), InvitationPollOutcome.newInvites);
    });

    test('some answered, nothing new -> partial', () {
      expect(categorize(3, 2, 0), InvitationPollOutcome.partial);
    });

    test('all answered, nothing new -> upToDate', () {
      expect(categorize(3, 3, 0), InvitationPollOutcome.upToDate);
    });

    test('single relay answered, nothing new -> upToDate', () {
      expect(categorize(1, 1, 0), InvitationPollOutcome.upToDate);
    });
  });

  group('InvitationPollStatus', () {
    test('idle defaults', () {
      const idle = InvitationPollStatus.idle;
      expect(idle.phase, InvitationPollPhase.idle);
      expect(idle.total, 0);
      expect(idle.responded, 0);
      expect(idle.newCount, 0);
      expect(idle.outcome, isNull);
    });

    test('notReturned = total - responded', () {
      const status = InvitationPollStatus(
        phase: InvitationPollPhase.settled,
        total: 4,
        responded: 1,
      );
      expect(status.notReturned, 3);
    });
  });

  group('refresh()', () {
    ProviderContainer makeContainer({
      required List<String> inboxRelays,
      required bool identityExists,
      MockRelayService? relayService,
      MockCircleService? circleService,
      _MockIdentityService? identityService,
    }) {
      final container = ProviderContainer(
        overrides: [
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
      'all relays answer, nothing new -> upToDate with exact counts',
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
        expect(state.responded, 2);
        expect(state.newCount, 0);
      },
    );

    test(
      'some relays unreachable -> partial with exact answered count',
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

        expect(state.outcome, InvitationPollOutcome.partial);
        expect(state.total, 3);
        expect(state.responded, 2);
        expect(state.notReturned, 1);
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
      expect(state.responded, 0);
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
      expect(state.outcome, InvitationPollOutcome.partial);
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
        expect(state.responded, 0);
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
