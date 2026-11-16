/// The Relays page on a device, against real relays that behave and relays
/// that misbehave on purpose: what it shows for every relay of the user's own
/// lists and every lookup relay, and what Haven sends where.
///
/// The real app (`HavenApp`, its providers, the maintenance scheduler and the
/// Rust core) runs against R1 and R2 (strfry) and the `haven-fault-relay`
/// processes the runner starts (`HAVEN_E2E_FAULT_RELAYS`): `green` and
/// `lookup` store what they are sent and count every offer; `refuse` answers
/// every event `OK false`; `drop` never answers `OK`; `stall` never ends a
/// `REQ`; `hole` never completes the WebSocket handshake; nothing listens on
/// `closed`. The test talks to each fault relay over a control socket of its
/// own (`HAVEN_FAULT_*` verbs) and never from a log.
///
/// What is asserted where:
///
/// * A state held on screen for many board reads by a production bound is
///   asserted as rendered: `checking` on the stalling relay (its `REQ` is
///   waited out) and `publishing` on the dropping one (its `OK` is waited
///   for). Every other state is asserted where it settles. [_proofOf] maps
///   each [KindPresence] to "seen on the device" or to the named Rust (L1) or
///   Flutter (L2) test that proves it; `check_relay_status_states_covered.sh`
///   holds each citation to a test that exists.
/// * Every step waits for the board to settle, with a deadline sized from the
///   pass bounds ([_kSettleBound]); never a sleep. Scheduler ticks can add
///   passes at any time, so the test asserts orders and final states, never
///   exact sequences, and counts offers exactly only where none is the
///   promise.
/// * Adds go through the production notifiers (the add sheet refuses `ws://`
///   by design and is proved with a `wss://` address at L2); remove and
///   restore are tapped by key.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/pages/settings/relay_status_cell.dart';
import 'package:haven/src/providers/identity_provider.dart'
    show identityProvider;
import 'package:haven/src/providers/live_sync_provider.dart'
    show liveSyncEnabled;
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/app_lifecycle.dart';
import 'e2e/_lib/fake_location_service.dart';
import 'e2e/_lib/plane_store_check.dart';
import 'e2e/_lib/pump_helpers.dart';
import 'e2e/_lib/test_relay.dart';
import 'e2e/_lib/test_user.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

/// The fault relays, `<role>=<mode>@<port>`; the runner's self-test holds this
/// default to the workflow's value and its own.
const String _kFaultRelays = String.fromEnvironment(
  'HAVEN_E2E_FAULT_RELAYS',
  defaultValue:
      'green=store@7779,refuse=refuse@7780,drop=drop@7781,stall=stall@7782,'
      'hole=blackhole@7783,closed=closed@7784,lookup=store@7785',
);

// The production bounds a maintenance pass is made of
// (haven-core/src/relay/manager.rs).
const Duration _kConnect = Duration(seconds: 5); // CONNECTION_TIMEOUT
const Duration _kReq = Duration(seconds: 10); // DEFAULT_TIMEOUT, one REQ
const Duration _kAck = Duration(seconds: 6); // OFFER_ACK_TIMEOUT

/// A relay-list pass and a `KeyPackage` pass against a stalling relay: each
/// dials, the relay-list pass waits out two `REQ`s and the `KeyPackage` pass
/// one, and each waits out an `OK` that never comes.
final Duration _kPassBound = _kConnect * 2 + _kReq * 3 + _kAck * 2;

/// The pass running, the one queued behind it (further requests join that
/// one), and the one the step itself asked for.
final Duration _kSettleBound = _kPassBound * 3;

/// From `pumpWidget` to a resolved identity on the map: Rust start-up, the
/// keyring and the database open.
const Duration _kAppStart = Duration(minutes: 1);

/// A tap or a list write is on screen within this, whatever is running.
const Duration _kInputTakesEffect = Duration(seconds: 2);

/// A control verb or a store read on a hermetic relay.
const Duration _kRelayAnswer = Duration(seconds: 15);

/// Two app starts, seven waits bounded by [_kSettleBound] (A, the two
/// transients and the end of B, D, E, C) and the reads between them: 2 + 18.2
/// min, rounded up. The runner's drive bound for this target covers it plus
/// the install and attach (its self-test holds the two together).
const Duration _kTestTimeout = Duration(minutes: 22);

const String _r1 = 'R1';
const String _r2 = 'R2';

/// The proof of one state: seen on the device by this test, or a named test.
sealed class _Proof {
  const _Proof();
}

final class _SeenOnDevice extends _Proof {
  const _SeenOnDevice();
}

final class _ProvedBy extends _Proof {
  const _ProvedBy(this.path, this.test);

  final String path;
  final String test;
}

/// Exhaustive by construction: a new [KindPresence] does not compile until it
/// is mapped here, and `check_relay_status_states_covered.sh` refuses a
/// wildcard arm and a citation of a test that does not exist.
_Proof _proofOf(KindPresence state) => switch (state) {
  // A row reads not checked only until its pass begins, which a busy board can
  // reach before the next read.
  KindPresence.notChecked => const _ProvedBy(
    'haven/test/providers/relay_status_provider_test.dart',
    'a list edit rebuilds the rows at once; the new relay reads not '
        'checked until the board has a cell for it',
  ),
  KindPresence.checking => const _SeenOnDevice(),
  KindPresence.publishing => const _SeenOnDevice(),
  KindPresence.current => const _SeenOnDevice(),
  // Missing and outdated last from the probe to the offer, inside one pass.
  KindPresence.missing => const _ProvedBy(
    'haven-core/tests/relay_management_e2e.rs',
    'a_cell_waits_for_its_own_relays_ok_after_checking_and_judging',
  ),
  KindPresence.outdated => const _ProvedBy(
    'haven-core/src/relay/maintenance/own_board.rs',
    'a_relay_list_is_current_only_when_its_newest_copy_names_'
        'the_configured_list',
  ),
  KindPresence.refused => const _SeenOnDevice(),
  KindPresence.unconfirmed => const _SeenOnDevice(),
  KindPresence.noAnswer => const _SeenOnDevice(),
  // The publish toggles are forced on and the reset notice needs a storage
  // reset: no device run of this lane can reach a hold.
  KindPresence.held => const _ProvedBy(
    'haven/test/providers/relay_status_provider_test.dart',
    'a held kind reads held on every row that expects it, with its '
        'reason; the other kinds keep their cells',
  ),
};

final class _Fault {
  const _Fault(this.role, this.mode, this.port);

  final String role;
  final String mode;
  final int port;

  String get address => 'ws://${Uri.parse(defaultStrfryUrl).host}:$port';
}

Map<String, _Fault> _parseFaults() {
  final faults = <String, _Fault>{};
  for (final entry in _kFaultRelays.split(',')) {
    final match = RegExp(
      r'^([a-z][a-z0-9-]*)=([a-z]+)@(\d+)$',
    ).firstMatch(entry);
    if (match == null) {
      throw StateError('HAVEN_E2E_FAULT_RELAYS holds a malformed entry');
    }
    faults[match.group(1)!] = _Fault(
      match.group(1)!,
      match.group(2)!,
      int.parse(match.group(3)!),
    );
  }
  return faults;
}

/// The test's own socket to one fault relay. Its replies come back in the
/// order its verbs were sent.
final class _FaultControl {
  _FaultControl._(this._socket) {
    _socket.listen(
      _onFrame,
      onDone: _failPending,
      onError: (Object _) => _failPending(),
      cancelOnError: true,
    );
  }

  static Future<_FaultControl> connect(_Fault fault) async =>
      _FaultControl._(await WebSocket.connect(fault.address));

  final WebSocket _socket;
  final List<Completer<List<dynamic>>> _pending = [];

  void _onFrame(dynamic data) {
    if (data is! String) return;
    final frame = jsonDecode(data);
    if (frame is! List || frame.isEmpty || _pending.isEmpty) return;
    final verb = frame.first;
    if (verb is String && verb.startsWith('HAVEN_FAULT_')) {
      _pending.removeAt(0).complete(frame);
    }
  }

  void _failPending() {
    for (final pending in _pending) {
      pending.completeError(StateError('a fault relay closed its socket'));
    }
    _pending.clear();
  }

  Future<List<dynamic>> _ask(List<Object> frame) {
    final reply = Completer<List<dynamic>>();
    _pending.add(reply);
    _socket.add(jsonEncode(frame));
    return reply.future.timeout(_kRelayAnswer);
  }

  /// Events offered to the relay so far, by kind — the app's sockets only.
  Future<Map<int, int>> offers() async {
    final reply = await _ask(['HAVEN_FAULT_OFFERS']);
    return {
      for (final entry in (reply[1] as Map<String, dynamic>).entries)
        int.parse(entry.key): entry.value as int,
    };
  }

  /// Every event the relay stores.
  Future<List<Map<String, dynamic>>> kept() async {
    final reply = await _ask(['HAVEN_FAULT_KEPT']);
    return [
      for (final e in reply[1] as List<dynamic>) e as Map<String, dynamic>,
    ];
  }

  Future<void> close() => _socket.close();
}

/// The relay URLs a kind-10002 (`r`) or kind-10050 (`relay`) event names.
Set<String> _named(Map<String, dynamic> event) {
  final tag = event['kind'] == 10050 ? 'relay' : 'r';
  return {
    for (final t in event['tags'] as List<dynamic>)
      if (t is List && t.length >= 2 && t[0] == tag && t[1] is String)
        normalizeRelayUrlForComparison(t[1] as String),
  };
}

/// The newest of [author]'s [kind] events (NIP-01: the lower id on a tie).
Map<String, dynamic>? _newest(
  Iterable<Map<String, dynamic>> events,
  int kind,
  String author,
) {
  Map<String, dynamic>? newest;
  for (final e in events) {
    if (e['kind'] != kind || e['pubkey'] != author) continue;
    final at = e['created_at'] as int;
    final best = newest?['created_at'] as int?;
    if (best == null ||
        at > best ||
        (at == best &&
            (e['id'] as String).compareTo(newest!['id'] as String) < 0)) {
      newest = e;
    }
  }
  return newest;
}

bool _names(Map<String, dynamic>? event, List<String> addresses) =>
    event != null &&
    setEquals(_named(event), {
      for (final a in addresses) normalizeRelayUrlForComparison(a),
    });

Future<List<Map<String, dynamic>>> _stored(TestRelay store) async => [
  for (final e in await store.dumpStore()) e.raw,
];

int _total(Map<int, int> offers) => offers.values.fold(0, (a, b) => a + b);

bool _unsettled(KindPresence state) =>
    state == KindPresence.notChecked ||
    state == KindPresence.checking ||
    state == KindPresence.publishing;

const Set<RelayKind> _allKinds = {
  RelayKind.keyPackage,
  RelayKind.relayList,
  RelayKind.inboxRelayList,
};
const Set<RelayKind> _inboxOnly = {RelayKind.inboxRelayList};
const Set<RelayKind> _kpOnly = {RelayKind.keyPackage, RelayKind.relayList};
const Set<RelayKind> _lookupKinds = {
  RelayKind.relayList,
  RelayKind.inboxRelayList,
};

/// What the drive saw: every state a rendered cell showed, and each cell's
/// rendered history (a state is appended only when it changes).
final class _Seen {
  _Seen(this._roleOf);

  final String Function(String) _roleOf;
  final Set<KindPresence> rendered = {};
  final Map<(String, RelayKind), List<KindPresence>> history = {};

  void record(WidgetTester tester) {
    for (final cell in tester.widgetList<RelayKindStatusCell>(
      find.byType(RelayKindStatusCell),
    )) {
      rendered.add(cell.status);
      final states = history.putIfAbsent((
        _roleOf(cell.relayUrl),
        cell.kind,
      ), () => []);
      if (states.isEmpty || states.last != cell.status) states.add(cell.status);
    }
  }

  bool any(String role, KindPresence state) =>
      history.entries.any((e) => e.key.$1 == role && e.value.contains(state));

  /// Whether, on one of [role]'s cells, [before] was rendered and [after]
  /// only later.
  bool inOrder(String role, KindPresence before, KindPresence after) =>
      history.entries.any((e) {
        if (e.key.$1 != role) return false;
        final first = e.value.indexOf(before);
        return first >= 0 && e.value.indexOf(after, first + 1) > first;
      });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  resumeAppBeforeEachTest();

  testWidgets(
    'the Relays page shows every state a device can hold, and Haven sends '
    'each relay exactly what it lacks',
    (tester) async {
      installThrowTimeErrorLogging();
      final faults = _parseFaults();
      _Fault fault(String role) =>
          faults[role] ?? (throw StateError('no fault relay named $role'));
      final green = fault('green');
      final refuse = fault('refuse');
      final drop = fault('drop');
      final stall = fault('stall');
      final hole = fault('hole');
      final closed = fault('closed');
      final lookup = fault('lookup');
      expect(
        {for (final f in faults.values) f.role: f.mode},
        {
          'green': 'store',
          'refuse': 'refuse',
          'drop': 'drop',
          'stall': 'stall',
          'hole': 'blackhole',
          'closed': 'closed',
          'lookup': 'store',
        },
        reason: 'every role behaves the way this test reads it',
      );

      final roles = <String, String>{
        normalizeRelayUrlForComparison(defaultStrfryUrl): _r1,
        normalizeRelayUrlForComparison(secondStrfryUrl): _r2,
        for (final f in faults.values)
          normalizeRelayUrlForComparison(f.address): f.role,
      };
      String roleOf(String address) =>
          roles[normalizeRelayUrlForComparison(address)] ?? 'unknown';
      final seen = _Seen(roleOf);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      await TestUser.bootstrapProcess(
        relays: [defaultStrfryUrl],
        discoveryRelays: [lookup.address],
      );
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
      final me = (await TestUser.derivePubkeyAndNpub(aliceSeed)).pubkeyHex;

      final r1 = await connectProbeRelay(defaultStrfryUrl);
      final r2 = await connectProbeRelay(secondStrfryUrl);
      final control = <String, _FaultControl>{
        for (final f in [green, refuse, drop, stall, lookup])
          f.role: await _FaultControl.connect(f),
      };

      Widget app() => ProviderScope(
        overrides: [
          onboardingControllerProvider.overrideWith(
            (ref) => OnboardingController(
              const OnboardingFlags(introSeen: true, completed: true),
            ),
          ),
          locationServiceProvider.overrideWithValue(
            FakeLocationService(
              latitude: aliceFakeLatitude,
              longitude: aliceFakeLongitude,
            ),
          ),
        ],
        child: const HavenApp(),
      );

      ProviderContainer container() => ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      Future<void> pumpUntil(
        bool Function() condition, {
        required String description,
        required Duration timeout,
      }) async {
        final deadline = DateTime.now().add(timeout);
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          seen.record(tester);
          if (condition()) return;
        }
        fail('"$description" did not hold within ${timeout.inSeconds}s.');
      }

      // The board as of this instant, joined to the lists the way the page
      // joins it; the page's own read lags it by at most one poll.
      RelayStatusState board() {
        final c = container();
        return relayStatusOf(
          c.read(inboxRelaysProvider).valueOrNull ?? const [],
          c.read(keyPackageRelaysProvider).valueOrNull ?? const [],
          c.read(maintenanceServiceProvider).ownRelayBoard(),
        );
      }

      Map<String, RelayPresence> rows(RelayStatusState state) => {
        for (final row in state.relays) roleOf(row.relayUrl): row,
      };

      bool settledTo(RelayStatusState state, Map<String, Set<RelayKind>> want) {
        if (state.running) return false;
        final byRole = rows(state);
        if (!setEquals(byRole.keys.toSet(), want.keys.toSet())) return false;
        for (final MapEntry(key: role, value: kinds) in want.entries) {
          for (final kind in RelayKind.values) {
            final status = byRole[role]!.of(kind);
            if ((status != null) != kinds.contains(kind)) return false;
            if (status != null && _unsettled(status)) return false;
          }
        }
        return true;
      }

      bool pageShows(RelayStatusState state) {
        final byRole = rows(state);
        return tester
            .widgetList<RelayKindStatusCell>(find.byType(RelayKindStatusCell))
            .every(
              (cell) =>
                  byRole[roleOf(cell.relayUrl)]?.of(cell.kind) == cell.status,
            );
      }

      // Waits, within one settle bound, until [delivered] has seen the step's
      // events on the wire, the board is settled over exactly [want], and the
      // page shows that board; returns that board.
      Future<RelayStatusState> settle(
        String step,
        Map<String, Set<RelayKind>> want, {
        Future<bool> Function()? delivered,
      }) async {
        final deadline = DateTime.now().add(_kSettleBound);
        var onWire = delivered == null;
        var askedAt = DateTime.fromMillisecondsSinceEpoch(0);
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          seen.record(tester);
          if (!onWire &&
              DateTime.now().difference(askedAt) >=
                  const Duration(seconds: 1)) {
            askedAt = DateTime.now();
            onWire = await delivered!();
          }
          final state = board();
          if (onWire && settledTo(state, want) && pageShows(state)) {
            debugPrint('[relay-status] $step settled');
            return state;
          }
        }
        // Roles, kinds and states only: never an address.
        final last = [
          for (final MapEntry(key: role, value: row) in rows(board()).entries)
            for (final kind in RelayKind.values)
              if (row.of(kind) case final status?)
                '$role ${kind.name}=${status.name}',
        ].join(', ');
        fail(
          '[$step] the board did not settle within '
          '${_kSettleBound.inSeconds}s (wire evidence seen: $onWire; '
          'board: $last).',
        );
      }

      void expectStates(
        String step,
        RelayStatusState state,
        Map<String, KindPresence> want,
      ) {
        expect(state.holds, isEmpty, reason: '[$step] nothing is held');
        for (final MapEntry(key: role, value: row) in rows(state).entries) {
          for (final kind in RelayKind.values) {
            final status = row.of(kind);
            if (status == null) continue;
            expect(status, want[role], reason: '[$step] $role ${kind.name}');
          }
        }
      }

      Future<Map<String, dynamic>?> newestKept(String role, int kind) async =>
          _newest(await control[role]!.kept(), kind, me);

      Future<void> startApp(String step) async {
        expectAppResumed();
        await tester.pumpWidget(app());
        await pumpUntilFound(
          tester,
          find.byType(MapShell),
          timeout: _kAppStart,
          description: '[$step] the map',
        );
        await pumpUntil(
          () => container().read(identityProvider).valueOrNull != null,
          description: '[$step] the pre-seeded identity resolved',
          timeout: _kAppStart,
        );
        // Opening the page is what starts its board reads.
        unawaited(
          Navigator.of(tester.element(find.byType(MapShell))).push(
            MaterialPageRoute<void>(builder: (_) => const RelaySettingsPage()),
          ),
        );
        await pumpUntilFound(
          tester,
          find.byType(RelaySettingsPage),
          description: '[$step] the Relays page',
        );
      }

      // The engine holds its own handle on the session, so it stops first;
      // then the circle service hands the database's single session back
      // (Security Rule 14), or the next app cannot open it.
      Future<void> stopApp() async {
        final c = container();
        if (liveSyncEnabled) await c.read(subscriptionServiceProvider).stop();
        await c.read(circleServiceProvider).closeAndInvalidate();
        await tester.pumpWidget(const SizedBox.shrink());
      }

      AppLocalizations l10n() =>
          AppLocalizations.of(tester.element(find.byType(RelaySettingsPage)));

      var appRunning = false;
      try {
        // ---------------------------------------------------------------
        // A. Launch with the defaults: R1 on both lists, the lookup relay.
        // ---------------------------------------------------------------
        await startApp('A');
        appRunning = true;
        final launch = {_r1: _allKinds, lookup.role: _lookupKinds};
        final settledA = await settle(
          'A',
          launch,
          delivered: () async =>
              _names(await newestKept(lookup.role, 10050), [
                defaultStrfryUrl,
              ]) &&
              _names(await newestKept(lookup.role, 10002), [defaultStrfryUrl]),
        );
        expectStates('A', settledA, {
          _r1: KindPresence.current,
          lookup.role: KindPresence.current,
        });
        final r1Store = await _stored(r1);
        final r1Inbox = _newest(r1Store, 10050, me);
        final r1KpList = _newest(r1Store, 10002, me);
        expect(
          _names(r1Inbox, [defaultStrfryUrl]),
          isTrue,
          reason: '[A] R1 serves the inbox list as configured',
        );
        expect(
          _names(r1KpList, [defaultStrfryUrl]),
          isTrue,
          reason: '[A] R1 serves the KeyPackage relay list as configured',
        );
        expect(
          _newest(r1Store, 30443, me),
          isNotNull,
          reason: '[A] R1 serves the KeyPackage',
        );
        expect(
          (await control[lookup.role]!.offers())[30443],
          isNull,
          reason: '[A] a lookup relay is never offered the KeyPackage',
        );

        // ---------------------------------------------------------------
        // B. Add every relay through the production notifiers: the
        //    behaving ones first, the slow ones last, in one batch.
        // ---------------------------------------------------------------
        // R2 starts holding R1's lists, own-signed and about to be outdated.
        for (final event in [r1Inbox!, r1KpList!]) {
          final (accepted, _) = await r2.publishAndAwaitOk(jsonEncode(event));
          expect(accepted, isTrue, reason: '[B] R2 takes the stale copy');
        }
        final inbox = container().read(inboxRelaysProvider.notifier);
        final kpList = container().read(keyPackageRelaysProvider.notifier);
        for (final address in [secondStrfryUrl, green.address]) {
          await inbox.addRelay(address);
          await kpList.addRelay(address);
        }
        for (final f in [refuse, drop, stall]) {
          await inbox.addRelay(f.address);
          await kpList.addRelay(f.address);
        }
        await inbox.addRelay(hole.address);
        // The stalling relay holds its cells checking while its REQ is waited
        // out; an add landing now takes effect at once.
        await pumpUntil(
          () => seen.any(stall.role, KindPresence.checking),
          description: '[B] the stalling relay rendered checking',
          timeout: _kSettleBound,
        );
        await inbox.addRelay(closed.address);
        await pumpUntil(
          () => tester
              .widgetList<RelayKindStatusCell>(find.byType(RelayKindStatusCell))
              .any((cell) => roleOf(cell.relayUrl) == closed.role),
          description: '[B] a relay added mid-check is on the page at once',
          timeout: _kInputTakesEffect,
        );
        expect(
          seen.history[(closed.role, RelayKind.inboxRelayList)]!.first,
          anyOf(KindPresence.notChecked, KindPresence.checking),
          reason: '[B] a relay just added reads not checked or checking',
        );
        // The dropping relay holds its cells publishing while its OK is
        // waited for.
        await pumpUntil(
          () => seen.any(drop.role, KindPresence.publishing),
          description: '[B] the dropping relay rendered publishing',
          timeout: _kSettleBound,
        );
        final inboxB = [
          defaultStrfryUrl,
          secondStrfryUrl,
          green.address,
          refuse.address,
          drop.address,
          stall.address,
          hole.address,
          closed.address,
        ];
        final kpB = [
          defaultStrfryUrl,
          secondStrfryUrl,
          green.address,
          refuse.address,
          drop.address,
          stall.address,
        ];
        final everyRelay = {
          for (final role in [
            _r1,
            _r2,
            green.role,
            refuse.role,
            drop.role,
            stall.role,
          ])
            role: _allKinds,
          hole.role: _inboxOnly,
          closed.role: _inboxOnly,
          lookup.role: _lookupKinds,
        };
        final settledB = await settle(
          'B',
          everyRelay,
          delivered: () async =>
              _names(await newestKept(lookup.role, 10050), inboxB) &&
              _names(await newestKept(lookup.role, 10002), kpB),
        );
        final finals = {
          _r1: KindPresence.current,
          _r2: KindPresence.current,
          green.role: KindPresence.current,
          lookup.role: KindPresence.current,
          refuse.role: KindPresence.refused,
          drop.role: KindPresence.unconfirmed,
          stall.role: KindPresence.noAnswer,
          hole.role: KindPresence.noAnswer,
          closed.role: KindPresence.noAnswer,
        };
        expectStates('B', settledB, finals);
        final r2Store = await _stored(r2);
        expect(
          _names(_newest(r2Store, 10050, me), inboxB),
          isTrue,
          reason: '[B] R2 serves the inbox list it held an old copy of',
        );
        expect(
          _names(_newest(r2Store, 10002, me), kpB),
          isTrue,
          reason: '[B] R2 serves the KeyPackage relay list',
        );
        expect(
          _newest(r2Store, 30443, me),
          isNotNull,
          reason: '[B] R2 serves the KeyPackage',
        );
        final greenKept = await control[green.role]!.kept();
        expect(
          _names(_newest(greenKept, 10050, me), inboxB),
          isTrue,
          reason: '[B] green serves the inbox list',
        );
        expect(
          _names(_newest(greenKept, 10002, me), kpB),
          isTrue,
          reason: '[B] green serves the KeyPackage relay list',
        );
        expect(
          _newest(greenKept, 30443, me),
          isNotNull,
          reason: '[B] green serves the KeyPackage',
        );
        for (final f in [refuse, drop]) {
          // Booleans, never the events: a failure must not print an id.
          expect(
            (await control[f.role]!.kept()).isEmpty,
            isTrue,
            reason: '[B] ${f.role} keeps nothing',
          );
          final offers = await control[f.role]!.offers();
          for (final kind in const [10050, 10002, 30443]) {
            expect(
              offers[kind],
              greaterThanOrEqualTo(1),
              reason: '[B] ${f.role} was offered kind $kind',
            );
          }
        }
        expect(
          await control[stall.role]!.offers(),
          isEmpty,
          reason: '[B] a relay that never answered is offered nothing',
        );

        // ---------------------------------------------------------------
        // D. Remove green from the inbox list, tapped by key.
        // ---------------------------------------------------------------
        final greenBefore = await control[green.role]!.offers();
        // The page labels the button with the stored entry, as it shows it.
        final greenShown = rows(
          settledB,
        )[green.role]!.relayUrl.replaceFirst('wss://', '');
        final greenRemove = find.descendant(
          of: find.byKey(WidgetKeys.relaySettingsSection('inbox')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is IconButton &&
                w.key == WidgetKeys.relaySettingsRemoveRelay &&
                w.tooltip == l10n().relaySettingsRemoveTooltip(greenShown),
            description: "the green relay's inbox remove button",
          ),
        );
        await tapWhenHittable(
          tester,
          greenRemove,
          description: "[D] the green relay's inbox remove button",
        );
        await pumpUntil(
          () => rows(board())[green.role]?.inboxRelayList == null,
          description: '[D] the removed inbox item left the row at once',
          timeout: _kInputTakesEffect,
        );
        final inboxD = [
          for (final a in inboxB)
            if (a != green.address) a,
        ];
        final afterRemove = {...everyRelay, green.role: _kpOnly};
        final settledD = await settle(
          'D',
          afterRemove,
          delivered: () async =>
              _names(await newestKept(lookup.role, 10050), inboxD) &&
              _names(_newest(await _stored(r1), 10050, me), inboxD),
        );
        expectStates('D', settledD, finals);
        final greenAfter = await control[green.role]!.offers();
        for (final kind in const [10050, 10002, 30443]) {
          expect(
            greenAfter[kind],
            greenBefore[kind],
            reason: '[D] green is sent no new kind $kind',
          );
        }
        expect(
          (greenAfter[5] ?? 0) - (greenBefore[5] ?? 0),
          lessThanOrEqualTo(1),
          reason: '[D] green gets at most the removal scrub',
        );

        // ---------------------------------------------------------------
        // E. Restore the inbox defaults, tapped by key and confirmed.
        // ---------------------------------------------------------------
        await tapWhenHittable(
          tester,
          find.byKey(WidgetKeys.relaySettingsRestoreDefaults('inbox')),
          description: '[E] Restore defaults for the inbox list',
        );
        await tapWhenHittable(
          tester,
          find.widgetWithText(TextButton, l10n().relaySettingsRestoreConfirm),
          description: '[E] the restore confirmation',
        );
        await pumpUntil(
          () => rows(board())[closed.role] == null,
          description: '[E] the inbox list is back to its defaults at once',
          timeout: _kInputTakesEffect,
        );
        final restored = {
          _r1: _allKinds,
          for (final role in [
            _r2,
            green.role,
            refuse.role,
            drop.role,
            stall.role,
          ])
            role: _kpOnly,
          lookup.role: _lookupKinds,
        };
        final settledE = await settle(
          'E',
          restored,
          delivered: () async =>
              _names(await newestKept(lookup.role, 10050), [
                defaultStrfryUrl,
              ]) &&
              _names(_newest(await _stored(r1), 10050, me), [defaultStrfryUrl]),
        );
        expectStates('E', settledE, finals);
        // R2 left the inbox list here and keeps what it last held: a relay
        // dropped from a list is never sent the new one.
        expect(
          _names(_newest(await _stored(r2), 10050, me), inboxD),
          isTrue,
          reason: '[E] R2, dropped from the inbox list, never got the new one',
        );

        // ---------------------------------------------------------------
        // C. Relaunch: nothing new for a relay that has it, everything
        //    owed asked again.
        // ---------------------------------------------------------------
        final greenOffers = _total(await control[green.role]!.offers());
        final lookupOffers = _total(await control[lookup.role]!.offers());
        final refuseOffers = _total(await control[refuse.role]!.offers());
        Set<String> listIds(List<Map<String, dynamic>> store) => {
          for (final e in store)
            if (e['kind'] == 10002 || e['kind'] == 10050) e['id'] as String,
        };
        final r1Lists = listIds(await _stored(r1));
        final r2Lists = listIds(await _stored(r2));
        await stopApp();
        appRunning = false;
        await startApp('C');
        appRunning = true;
        final settledC = await settle(
          'C',
          restored,
          delivered: () async =>
              _total(await control[refuse.role]!.offers()) > refuseOffers,
        );
        expectStates('C', settledC, finals);
        expect(
          _total(await control[green.role]!.offers()),
          greenOffers,
          reason: '[C] a relay that has everything is sent nothing',
        );
        expect(
          _total(await control[lookup.role]!.offers()),
          lookupOffers,
          reason: '[C] a lookup relay that has the lists is sent nothing',
        );
        expect(
          setEquals(listIds(await _stored(r1)), r1Lists),
          isTrue,
          reason: '[C] R1 is sent no new list',
        );
        expect(
          setEquals(listIds(await _stored(r2)), r2Lists),
          isTrue,
          reason: '[C] R2 is sent no new list',
        );

        // ---------------------------------------------------------------
        // Close-out.
        // ---------------------------------------------------------------
        for (final state in KindPresence.values) {
          switch (_proofOf(state)) {
            case _SeenOnDevice():
              expect(
                seen.rendered,
                contains(state),
                reason: 'the page never rendered ${state.name}',
              );
            case _ProvedBy():
              break;
          }
        }
        expect(
          seen.inOrder(
            stall.role,
            KindPresence.checking,
            KindPresence.noAnswer,
          ),
          isTrue,
          reason: 'the stalling relay was checked, then judged',
        );
        expect(
          seen.inOrder(
            drop.role,
            KindPresence.publishing,
            KindPresence.unconfirmed,
          ),
          isTrue,
          reason:
              'the dropping relay was sent the event, then judged on its '
              'missing OK',
        );
        for (final f in [refuse, drop, stall, hole, closed]) {
          expect(
            seen.any(f.role, KindPresence.current),
            isFalse,
            reason: '${f.role} accepted nothing and never read current',
          );
        }
        await assertStoreWithinRoles(
          r1,
          check: 'relay status R1',
          roles: const {'inbox', 'keypackage'},
          harnessIds: r1.publishedIds,
        );
        await assertStoreLacksKinds(
          r1,
          check: 'relay status R1',
          kinds: const {0},
          harnessIds: r1.publishedIds,
        );
        await assertStoreWithinRoles(
          r2,
          check: 'relay status R2',
          roles: const {'inbox', 'keypackage'},
          harnessIds: r2.publishedIds,
        );
        final rolesOf = {
          for (final f in [green, refuse, drop, stall])
            f.role: const {'inbox', 'keypackage'},
          lookup.role: const {'discovery'},
        };
        for (final MapEntry(key: role, value: planes) in rolesOf.entries) {
          final admitted = {for (final p in planes) ...kRoleEventKinds[p]!};
          final offered = (await control[role]!.offers()).keys.toSet();
          expect(
            offered.difference(admitted),
            isEmpty,
            reason: '$role was offered only what its roles admit',
          );
        }
      } finally {
        for (final socket in control.values) {
          await socket.close();
        }
        await r1.dispose();
        await r2.dispose();
        if (appRunning) {
          try {
            await stopApp();
          } on Object catch (e) {
            // The body's own failure, if any, is the verdict.
            debugPrint('[relay-status] app teardown failed: ${e.runtimeType}');
          }
        }
        await TestUser.clearPreSeededIdentity();
      }
    },
    timeout: const Timeout(_kTestTimeout),
  );
}
