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
    }) {
      final container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            _MockIdentityService(identityExists: identityExists),
          ),
          circleServiceProvider.overrideWithValue(
            circleService ?? MockCircleService(),
          ),
          relayServiceProvider.overrideWithValue(
            relayService ?? MockRelayService(),
          ),
          inboxRelaysProvider.overrideWith(
            () => _StubInboxRelays(inboxRelays),
          ),
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

    test('all relays answer, nothing new -> upToDate with exact counts',
        () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler =
            (relays) async => [for (final r in relays) _ok(r)];
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
    });

    test('some relays unreachable -> partial with exact answered count',
        () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _ok(relays[0]),
          _ok(relays[1]),
          _down(relays[2]),
        ];
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
    });

    test('no relay answers -> offline', () async {
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler =
            (relays) async => [for (final r in relays) _down(r)];
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

    test('a superseded rapid refresh does not overwrite the newer result',
        () async {
      // Refresh #1 is parked inside its (gated) fetch, past its guards; #2
      // then supersedes it and settles first. When #1 finally resolves it
      // must drop its stale result at the final generation guard.
      final entered = Completer<void>();
      final gate = Completer<void>();
      var calls = 0;
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          calls++;
          if (calls == 1) {
            entered.complete(); // #1 has reached the fetch (past its guards).
            await gate.future;
            // Would categorise as offline — must be discarded.
            return [for (final r in relays) _down(r)];
          }
          return [for (final r in relays) _ok(r)];
        };
      final container = makeContainer(
        inboxRelays: const ['wss://a', 'wss://b'],
        identityExists: true,
        relayService: relay,
      );
      final notifier = container.read(invitationPollStatusProvider.notifier);

      final first = notifier.refresh();
      await entered.future; // wait until #1 is parked mid-fetch
      final second = notifier.refresh();
      await second;

      // Newer refresh wins.
      expect(
        container.read(invitationPollStatusProvider).outcome,
        InvitationPollOutcome.upToDate,
      );

      gate.complete();
      await first;

      // The superseded refresh must not clobber the newer settled state.
      expect(
        container.read(invitationPollStatusProvider).outcome,
        InvitationPollOutcome.upToDate,
      );
    });

    test('same gift wrap on multiple relays is processed once (dedup)',
        () async {
      final circle = MockCircleService();
      // The identical event arrives from both relays.
      const sameEvent = '{"id":"dup-1"}';
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          _ok(relays[0], events: const [sameEvent]),
          _ok(relays[1], events: const [sameEvent]),
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

  static final _identity = Identity(
    pubkeyHex:
        'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
    npub: 'npub1test',
    createdAt: DateTime(2024),
  );

  @override
  Future<Identity?> getIdentity() async => identityExists ? _identity : null;

  @override
  Future<List<int>> getSecretBytes() async => List<int>.generate(32, (i) => i);

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
