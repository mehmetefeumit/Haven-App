/// A pause, a stop and a start must never cross.
///
/// Three states must not exist, and each has been reachable:
///
///  * a session up in a process the user has left, behind a pause that
///    believed it had ended it — nobody's foreground, and not inert: it
///    publishes what it receives through the legacy ladder and drives its
///    stored commits once, over standing REQs, and on Android it holds the
///    MLS database's single-session guard the foreground service was just
///    handed (Security Rule 14);
///  * a stopped engine in an app that is in front, which every flag still
///    reads as running;
///  * the rest of a pause — the released session, the "sharing in the
///    background" notification, the signal that starts the service's publish
///    cycle — landing on a user who has already come back, whether or not
///    the window still has focus when it lands.
///
/// `MapShell` cannot be pumped (CLAUDE.md), so these drive what its pause and
/// resume do with the engine through the statics it calls, over the REAL
/// `NostrSubscriptionService` and the REAL `LiveSyncResubscriber`, against
/// the real binding's lifecycle. Which static each branch of `_onPaused`
/// reaches is pinned from the source by
/// `map_shell_location_access_lifecycle_test.dart` and
/// `map_shell_detached_release_test.dart`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/rust/api.dart'
    show FfiRelayEvent, FfiRelayEventKind;
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../helpers/fake_live_sync_engine.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

LiveEventRouter _router() => LiveEventRouter(
  circleService: MockCircleService.new,
  circlesSnapshot: () async => const [],
  secretBytes: () async => const [],
  parseLocation: (_, _) async => null,
  ingestLocation: (_, _) async {},
  reconcileRoster: (_) async {},
  onLocationsChanged: () {},
  onGroupUpdated: (_) {},
  onInvitationReceived: () {},
  onStatus: (_) {},
);

/// One shell's engine, re-subscriber and pause, on one of the four
/// (platform × background sharing) branches.
class _Shell {
  _Shell(
    this.binding, {
    required this.isIOS,
    required this.backgroundSharing,
    Future<List<String>> Function()? inboxRelays,
  }) {
    service = NostrSubscriptionService(
      router: _router(),
      engineFactory: () {
        final build = _builds.isEmpty ? null : _builds.removeAt(0);
        if (build != null) return build.future.then(_built);
        return Future.value(_built(FakeLiveSyncEngine()));
      },
    );
    resubscriber = LiveSyncResubscriber(
      engine: service,
      inboxRelays: inboxRelays ?? () async => const ['wss://inbox.test'],
      initialCircles: const [],
      sessionWanted: () => MapShell.liveSyncWanted(
        lifecycle: binding.lifecycleState,
        isIOS: isIOS,
        backgroundSharingEnabled: backgroundSharing,
      ),
    );
  }

  final TestWidgetsFlutterBinding binding;
  final bool isIOS;
  final bool backgroundSharing;
  late final NostrSubscriptionService service;
  late final LiveSyncResubscriber resubscriber;

  /// Every engine the factory has handed over, in order.
  final List<FakeLiveSyncEngine> engines = [];

  /// Engines the factory must wait for, in order; with none queued it builds
  /// a plain one at once.
  final List<Completer<FakeLiveSyncEngine>> _builds = [];

  /// What the pause did, in order: `stop:<outcome>`, `release`,
  /// `announce:<handedOff>`.
  final List<String> pauseLog = [];

  FakeLiveSyncEngine _built(FakeLiveSyncEngine engine) {
    engines.add(engine);
    return engine;
  }

  /// Makes the next engine one the test hands over when it chooses.
  Completer<FakeLiveSyncEngine> gateNextEngine() {
    final build = Completer<FakeLiveSyncEngine>();
    _builds.add(build);
    return build;
  }

  /// Queues [engine] as the next one built.
  void nextEngine(FakeLiveSyncEngine engine) =>
      gateNextEngine().complete(engine);

  Future<LiveSyncStopOutcome> _stop() async {
    final outcome = await service.stop();
    pauseLog.add('stop:${outcome.name}');
    return outcome;
  }

  /// How many pauses and resumes have been dispatched — `_lifecycleTurn`.
  int turn = 0;

  /// The two platform writes the Android hand-off makes before it waits for
  /// the engine's stop. A test replaces them to hold or fail one.
  List<Future<void> Function()> ownershipWrites = [() async {}, () async {}];

  /// The app goes away: the lifecycle, then what `_onPaused` does with the
  /// engine on this branch — the stop first, on every branch that stops.
  Future<void> pause() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final mine = ++turn;
    Future<LiveSyncStopOutcome>? engineStop;
    if (MapShell.shouldStopLiveSyncOnPause(
      isIOS: isIOS,
      backgroundSharingEnabled: backgroundSharing,
    )) {
      engineStop = _stop();
    }
    _pauseStop = engineStop;
    if (backgroundSharing && !isIOS) {
      return MapShell.handOffMlsSession(
        engineStop: engineStop!,
        ownershipWrites: ownershipWrites,
        releaseSession: () {
          pauseLog.add('release');
          return true;
        },
        announce: ({required handedOff}) =>
            pauseLog.add('announce:$handedOff'),
        superseded: () => mine != turn,
      );
    }
    return Future.value();
  }

  /// The app comes back: the lifecycle, then the heal `_onResumed` runs.
  /// Answers whether that heal found the engine running.
  Future<bool> resume() async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    turn++;
    return await resubscriber.ensureRunning() == LiveSyncHealOutcome.running;
  }

  /// The stop the last pause issued, if it issued one.
  Future<LiveSyncStopOutcome>? _pauseStop;

  /// The consent that makes this process the background receiver resolves
  /// while paused (R1): what the watcher `_onPaused` installs does with the
  /// engine.
  Future<void> consentEdge() => MapShell.healBehindStop(
    stop: _pauseStop ?? Future.value(LiveSyncStopOutcome.idle),
    heal: resubscriber.ensureRunning,
  );

  /// A state that runs neither handler and does not move the turn:
  /// `inactive`, `hidden`.
  void enter(AppLifecycleState state) =>
      binding.handleAppLifecycleStateChanged(state);

  /// The Flutter engine is going away: the lifecycle, then the stop
  /// `_onDetached` issues. The turn does not move.
  Future<LiveSyncStopOutcome> detach() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    return service.stop();
  }
}

/// A circle service whose last-known store waits for the test: a write
/// parked across a pause, or a read parked across one.
class _ParkedStore extends MockCircleService {
  Completer<void>? park;
  Completer<void>? parkSnapshot;

  /// Store writes begun, parked or not.
  int upserts = 0;

  @override
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required DateTime timestamp,
    required DateTime expiresAt,
    required DateTime purgeAfter,
    required DateTime updatedAt,
    String? displayName,
  }) async {
    upserts++;
    await park?.future;
    await super.upsertLastKnownLocation(
      nostrGroupId: nostrGroupId,
      senderPubkey: senderPubkey,
      latitude: latitude,
      longitude: longitude,
      geohash: geohash,
      timestamp: timestamp,
      expiresAt: expiresAt,
      purgeAfter: purgeAfter,
      updatedAt: updatedAt,
      displayName: displayName,
    );
  }

  @override
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async {
    await parkSnapshot?.future;
    return super.snapshotLastKnownForCircle(
      nostrGroupId: nostrGroupId,
      now: now,
    );
  }
}

/// What a session brought up by a return to the app is handed: its own
/// start's claim, and the claim of the heal that started it.
const _claimedOnReturn = [true, true];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  tearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  group('MapShell.liveSyncWanted', () {
    bool wanted(
      AppLifecycleState? lifecycle, {
      required bool isIOS,
      required bool sharing,
    }) => MapShell.liveSyncWanted(
      lifecycle: lifecycle,
      isIOS: isIOS,
      backgroundSharingEnabled: sharing,
    );

    test('every state that is not a pause or a detach wants a session', () {
      for (final lifecycle in <AppLifecycleState?>[
        null,
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]) {
        for (final isIOS in [true, false]) {
          for (final sharing in [true, false]) {
            expect(
              wanted(lifecycle, isIOS: isIOS, sharing: sharing),
              isTrue,
              reason: 'a cold start begins its session before the first '
                  'lifecycle event, and an unfocused or covered window still '
                  'shows a map: $lifecycle, isIOS=$isIOS, sharing=$sharing',
            );
          }
        }
      }
    });

    test('a pause wants none on every branch whose pause stops the engine',
        () {
      for (final (isIOS, sharing) in [(false, true), (false, false)]) {
        expect(
          wanted(AppLifecycleState.paused, isIOS: isIOS, sharing: sharing),
          isFalse,
          reason: 'Android never receives in this isolate while paused',
        );
      }
      expect(
        wanted(AppLifecycleState.paused, isIOS: true, sharing: false),
        isFalse,
        reason: 'nothing receives on iOS with background sharing off',
      );
    });

    test('the iOS sharing-on pause wants one: that process is the receiver',
        () {
      expect(
        wanted(AppLifecycleState.paused, isIOS: true, sharing: true),
        isTrue,
        reason: 'refusing here ends background receive, and the R1 consent '
            'edge could never bring its session back',
      );
    });

    test('it agrees with the rule that decides the stop, branch for branch',
        () {
      for (final isIOS in [true, false]) {
        for (final sharing in [true, false]) {
          expect(
            wanted(AppLifecycleState.paused, isIOS: isIOS, sharing: sharing),
            !MapShell.shouldStopLiveSyncOnPause(
              isIOS: isIOS,
              backgroundSharingEnabled: sharing,
            ),
            reason: 'a branch that stops the engine and still wants a '
                'session restarts it behind its own stop',
          );
        }
      }
    });

    test('a detached app wants none, whatever the branch', () {
      for (final isIOS in [true, false]) {
        for (final sharing in [true, false]) {
          expect(
            wanted(AppLifecycleState.detached, isIOS: isIOS, sharing: sharing),
            isFalse,
          );
        }
      }
    });
  });

  group('the Android handoff', () {
    test('stops the engine, then releases, then announces', () async {
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true);
      expect(await shell.resume(), isTrue);

      await shell.pause();

      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);
      expect(shell.engines.single.stopCalls, 1);
      expect(shell.service.isRunning, isFalse);
    });

    test('a stop that did not drain keeps the session and says so', () async {
      // The C1 wedge, from the pause side: the engine's supervisor tasks
      // still hold the manager, so releasing this isolate's handle frees
      // nothing and removes the last Dart reference to a held guard.
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..nextEngine(FakeLiveSyncEngine()..failStopCalls = 2);
      expect(await shell.resume(), isTrue);

      await shell.pause();

      expect(
        shell.pauseLog,
        ['stop:stillHolding', 'announce:false'],
        reason: 'the release must be skipped, and the one thing a '
            'backgrounded user can see must not say the service is sharing',
      );
    });

    test('a release that throws is a session that was not handed over',
        () async {
      final logs = LogCapture.install();
      final announced = <bool>[];
      await MapShell.handOffMlsSession(
        engineStop: Future.value(LiveSyncStopOutcome.stopped),
        releaseSession: () =>
            throw StateError('boom for mls group deadbeefcafef00ddeadbeef'),
        announce: ({required handedOff}) => announced.add(handedOff),
        ownershipWrites: const [],
        superseded: () => false,
      );

      expect(announced, [false]);
      logs
        ..assertContains('handoff failed: StateError')
        ..assertNoNeedles(['deadbeefcafef00ddeadbeef']);
    });

    test('an announcement that throws does not escape the pause', () async {
      // It posts a notification and signals the service, synchronously. A
      // throw used to leave the pause there, with its local teardown undone.
      final logs = LogCapture.install();
      var released = 0;
      await MapShell.handOffMlsSession(
        engineStop: Future.value(LiveSyncStopOutcome.stopped),
        releaseSession: () {
          released++;
          return true;
        },
        announce: ({required handedOff}) =>
            throw StateError('boom for wss://relay.planted.example'),
        ownershipWrites: const [],
        superseded: () => false,
      );

      expect(released, 1);
      logs
        ..assertContains('handoff announce failed: StateError')
        ..assertNoNeedles(['relay.planted.example']);
    });

    test("the engine's stop is issued before either platform write "
        'completes', () async {
      // A claimed session used to outlive the pause by however long the two
      // writes took: they were awaited first, and the stop came after.
      final firstWrite = Completer<void>();
      final order = <String>[];
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..ownershipWrites = [
          () {
            order.add('seed');
            return firstWrite.future;
          },
          () async => order.add('ownership'),
        ];
      expect(await shell.resume(), isTrue);

      final paused = shell.pause();
      await pumpEventQueue();

      expect(order, ['seed'], reason: 'premise: the first write is out');
      expect(shell.engines.single.stopCalls, 1);
      expect(shell.service.isRunning, isFalse);
      expect(
        shell.pauseLog,
        ['stop:stopped'],
        reason: 'nothing is released before the service has been told',
      );

      firstWrite.complete();
      await paused;

      expect(order, ['seed', 'ownership']);
      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);
    });

    test('a platform write that throws still ends with the engine stopped '
        'and the hand-off decided', () async {
      // Unguarded, the first throw aborted the pause with the engine up, no
      // hand-off and none of the tail.
      final logs = LogCapture.install();
      final order = <String>[];
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..ownershipWrites = [
          () async {
            order.add('seed');
            throw StateError('boom for mls group deadbeefcafef00ddeadbeef');
          },
          () async {
            order.add('ownership');
            throw StateError('boom for wss://relay.planted.example');
          },
        ];
      expect(await shell.resume(), isTrue);

      await shell.pause();

      expect(order, ['seed', 'ownership']);
      expect(shell.engines.single.stopCalls, 1);
      expect(shell.service.isRunning, isFalse);
      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);
      logs
        ..assertContains('handoff write failed: StateError')
        ..assertNoNeedles([
          'deadbeefcafef00ddeadbeef',
          'relay.planted.example',
        ]);
    });

    test('with no engine there is still a session to hand over', () async {
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true);

      await shell.pause();

      expect(shell.pauseLog, ['stop:idle', 'release', 'announce:true']);
    });
  });

  group('a plain pause, branch by branch', () {
    test('Android, sharing on: stopped, handed over, and nothing restarts '
        'it', () async {
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true);
      expect(await shell.resume(), isTrue);

      await shell.pause();
      final healed = await shell.resubscriber.ensureRunning();
      await pumpEventQueue();

      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);
      expect(healed, LiveSyncHealOutcome.stoodDown);
      expect(
        shell.engines,
        hasLength(1),
        reason: 'a session came up behind the handoff, holding the guard the '
            'foreground service had just been given',
      );
    });

    /// A running shell with sharing off, paused, and whether a heal issued
    /// after that pause found it running.
    Future<(_Shell, LiveSyncHealOutcome)> pausedWithSharingOff({
      required bool isIOS,
    }) async {
      final shell = _Shell(binding, isIOS: isIOS, backgroundSharing: false);
      expect(await shell.resume(), isTrue);

      await shell.pause();
      await pumpEventQueue();
      final healed = await shell.resubscriber.ensureRunning();
      await pumpEventQueue();
      return (shell, healed);
    }

    test('Android, sharing off: stopped, nothing handed over, and nothing '
        'restarts it', () async {
      final (shell, healed) = await pausedWithSharingOff(isIOS: false);

      expect(
        shell.pauseLog,
        ['stop:stopped'],
        reason: 'with sharing off no isolate takes this session: a release '
            'would latch the database shut until the next resume',
      );
      expect(shell.service.isRunning, isFalse);
      expect(healed, LiveSyncHealOutcome.stoodDown);
      expect(shell.engines, hasLength(1));
    });

    test('iOS, sharing off: stopped, nothing handed over, and nothing '
        'restarts it', () async {
      final (shell, healed) = await pausedWithSharingOff(isIOS: true);

      expect(
        shell.pauseLog,
        ['stop:stopped'],
        reason: 'nothing reclaims this session on iOS, and the engine must '
            'not keep its REQs for the whole background window',
      );
      expect(shell.service.isRunning, isFalse);
      expect(healed, LiveSyncHealOutcome.stoodDown);
      expect(shell.engines, hasLength(1));
    });

    test('iOS, sharing on: the session is kept, and a dead one may be '
        'brought back', () async {
      final shell = _Shell(binding, isIOS: true, backgroundSharing: true);
      expect(await shell.resume(), isTrue);

      await shell.pause();
      await pumpEventQueue();

      expect(shell.pauseLog, isEmpty, reason: 'the burst plane owns it');
      expect(shell.service.isRunning, isTrue);
      expect(shell.engines.single.stopCalls, 0);

      // The session the bursts open dies underneath them.
      await shell.service.stop();
      expect(
        await shell.resubscriber.ensureRunning(),
        LiveSyncHealOutcome.running,
      );
      expect(shell.engines, hasLength(2));
      expect(
        shell.engines.last.foregroundClaims,
        isEmpty,
        reason: "started for the bursts, in nobody's foreground",
      );
    });

    test('the next resume brings it back and claims for it', () async {
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true);
      expect(await shell.resume(), isTrue);
      await shell.pause();

      expect(await shell.resume(), isTrue);

      expect(shell.engines, hasLength(2));
      expect(shell.engines.last.foregroundClaims, _claimedOnReturn);
      expect(shell.service.isRunning, isTrue);
    });
  });

  group('the user comes back while the pause is still stopping the engine',
      () {
    test('a stop waiting for the engine to be built: nothing is handed '
        'over, and the app ends with a running, claimed session', () async {
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true);
      final build = shell.gateNextEngine();
      final first = shell.resume();
      await pumpEventQueue();

      final paused = shell.pause();
      await pumpEventQueue();
      expect(shell.pauseLog, isEmpty, reason: 'premise: the stop is waiting');

      final healed = shell.resume();
      await pumpEventQueue();
      build.complete(FakeLiveSyncEngine());

      await paused;
      expect(await first, isFalse);
      expect(await healed, isTrue);
      await pumpEventQueue();

      expect(
        shell.pauseLog,
        ['stop:idle'],
        reason: 'the session was released, and the service told to publish, '
            'under an app the user is looking at',
      );
      expect(shell.engines, hasLength(2));
      expect(
        shell.engines.first.calls,
        isEmpty,
        reason: 'the start the pause ended still brought its session up',
      );
      expect(shell.engines.first.disposeCalls, 1);
      expect(
        shell.service.isRunning,
        isTrue,
        reason: 'the resume heal answered for a start the stop then ended: '
            'no engine, in an app that is in front, until the next heal tick',
      );
      expect(shell.engines.last.foregroundClaims, _claimedOnReturn);
    });

    test('a stop whose teardown is still unwinding: the restart waits for '
        'it, and nothing is handed over', () async {
      final slow = FakeLiveSyncEngine()..stopGate = Completer<void>();
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..nextEngine(slow);
      expect(await shell.resume(), isTrue);

      final paused = shell.pause();
      await pumpEventQueue();
      expect(slow.stopCalls, 1, reason: 'premise: the teardown is out');

      final healed = shell.resume();
      await pumpEventQueue();
      expect(
        shell.engines,
        hasLength(1),
        reason: 'a second session was started on the MLS state of one still '
            'being torn down',
      );

      slow.stopGate!.complete();
      await paused;
      expect(await healed, isTrue);
      await pumpEventQueue();

      expect(shell.pauseLog, ['stop:stopped']);
      expect(slow.stopCalls, 1);
      expect(shell.engines, hasLength(2));
      expect(shell.service.isRunning, isTrue);
      expect(shell.engines.last.foregroundClaims, _claimedOnReturn);
    });

    test('with sharing off the same return ends running and claimed',
        () async {
      for (final isIOS in [false, true]) {
        final shell = _Shell(binding, isIOS: isIOS, backgroundSharing: false);
        final build = shell.gateNextEngine();
        final first = shell.resume();
        await pumpEventQueue();

        await shell.pause();
        final healed = shell.resume();
        await pumpEventQueue();
        build.complete(FakeLiveSyncEngine());

        expect(await first, isFalse);
        expect(await healed, isTrue);
        await pumpEventQueue();
        expect(shell.pauseLog, ['stop:idle']);
        expect(shell.service.isRunning, isTrue, reason: 'isIOS=$isIOS');
        expect(shell.engines.last.foregroundClaims, _claimedOnReturn);
      }
    });
  });

  // The pause asks "has a pause or a resume been dispatched since I began",
  // never "is the app resumed now". Each of these is a sequence the two
  // questions answer differently.
  group('a pause that was overtaken does nothing further', () {
    /// A running Android sharing-on shell whose engine's stop waits for the
    /// test.
    Future<(_Shell, FakeLiveSyncEngine)> withSlowStop() async {
      final slow = FakeLiveSyncEngine()..stopGate = Completer<void>();
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..nextEngine(slow);
      expect(await shell.resume(), isTrue);
      return (shell, slow);
    }

    test('the user returns and the window then loses focus: nothing is '
        'released and nothing is announced', () async {
      for (final unfocused in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
      ]) {
        final (shell, slow) = await withSlowStop();

        final paused = shell.pause();
        await pumpEventQueue();
        expect(slow.stopCalls, 1, reason: 'premise: the stop is out');

        // The resume runs whole; then a shade, a permission dialog, a
        // biometric prompt. No handler runs for that.
        final healed = shell.resume();
        await pumpEventQueue();
        shell.enter(unfocused);

        slow.stopGate!.complete();
        await paused;
        expect(await healed, isTrue);
        await pumpEventQueue();

        expect(
          shell.pauseLog,
          ['stop:stopped'],
          reason: 'the app does not read `resumed`, so an instantaneous read '
              'releases the session and posts "sharing in the background" '
              'under a visible app whose resume has already run: $unfocused',
        );
        expect(shell.service.isRunning, isTrue, reason: '$unfocused');
        expect(shell.engines, hasLength(2));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
    });

    test('pause, resume, pause: one hand-off, one announcement', () async {
      final (shell, slow) = await withSlowStop();

      final first = shell.pause();
      await pumpEventQueue();
      final healed = shell.resume();
      await pumpEventQueue();
      final second = shell.pause();
      await pumpEventQueue();
      expect(shell.pauseLog, isEmpty, reason: 'premise: both are waiting');

      slow.stopGate!.complete();
      await first;
      await second;
      expect(await healed, isFalse);
      await pumpEventQueue();

      expect(
        shell.pauseLog,
        ['stop:stopped', 'stop:stopped', 'release', 'announce:true'],
        reason: 'the paused signal rides the announcement: two of them start '
            "the service's cycle twice",
      );
      expect(slow.stopCalls, 1, reason: 'the second stop joined the first');
      expect(shell.engines, hasLength(1));
      expect(shell.service.isRunning, isFalse);
    });

    test('a second pause with no resume between them: one hand-off',
        () async {
      // The app switcher opened over a backgrounded app and dismissed again:
      // `paused`, `inactive`, `paused`. No resume runs.
      final (shell, slow) = await withSlowStop();

      final first = shell.pause();
      await pumpEventQueue();
      shell.enter(AppLifecycleState.inactive);
      final second = shell.pause();
      await pumpEventQueue();

      slow.stopGate!.complete();
      await first;
      await second;

      expect(
        shell.pauseLog,
        ['stop:stopped', 'stop:stopped', 'release', 'announce:true'],
      );
      expect(slow.stopCalls, 1);
      expect(shell.service.isRunning, isFalse);
    });

    test('a detach does not overtake it: the session is still handed over',
        () async {
      // Nothing else would: `_onDetached` stops the engine and releases
      // nothing, and the foreground service is waiting for the guard.
      final (shell, slow) = await withSlowStop();

      final paused = shell.pause();
      await pumpEventQueue();
      final detached = shell.detach();
      await pumpEventQueue();

      slow.stopGate!.complete();
      await paused;
      expect(await detached, LiveSyncStopOutcome.stopped);

      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);
      expect(slow.stopCalls, 1);
    });

    test('a window on its way back does not overtake it: the pause ends '
        'whole, and the resume that follows takes the session back',
        () async {
      final (shell, slow) = await withSlowStop();

      final paused = shell.pause();
      await pumpEventQueue();
      shell
        ..enter(AppLifecycleState.hidden)
        ..enter(AppLifecycleState.inactive);

      slow.stopGate!.complete();
      await paused;
      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);

      expect(await shell.resume(), isTrue);
      expect(shell.engines.last.foregroundClaims, _claimedOnReturn);
    });

    test('a write the user returned during is the last thing it does',
        () async {
      final firstWrite = Completer<void>();
      final order = <String>[];
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..ownershipWrites = [
          () {
            order.add('seed');
            return firstWrite.future;
          },
          () async => order.add('ownership'),
        ];
      expect(await shell.resume(), isTrue);

      final paused = shell.pause();
      await pumpEventQueue();
      final healed = shell.resume();
      firstWrite.complete();
      await paused;
      expect(await healed, isTrue);

      expect(
        order,
        ['seed'],
        reason: 'the ownership write told the service the foreground had '
            'stood down, after the foreground was back',
      );
      expect(shell.pauseLog, ['stop:stopped']);
    });
  });

  // The consent watcher is installed on EVERY iOS pause, the one that kept
  // its session included, and the consent can flap while paused.
  group('the consent edge joins the stop the pause issued', () {
    test('on a pause that kept its session it stops nothing and starts '
        'nothing', () async {
      final shell = _Shell(binding, isIOS: true, backgroundSharing: true);
      expect(await shell.resume(), isTrue);
      await shell.pause();

      await shell.consentEdge();
      await pumpEventQueue();

      expect(
        shell.engines.single.stopCalls,
        0,
        reason: 'a healthy paused session was stopped, to be started again '
            'from the background with the foreground-shaped REQ set',
      );
      expect(shell.engines, hasLength(1));
      expect(shell.service.isRunning, isTrue);
    });

    test('on a pause that stopped its engine it waits for that stop, then '
        'brings the session back', () async {
      final slow = FakeLiveSyncEngine()..stopGate = Completer<void>();
      final shell = _Shell(binding, isIOS: true, backgroundSharing: false)
        ..nextEngine(slow);
      expect(await shell.resume(), isTrue);
      await shell.pause();
      await pumpEventQueue();
      expect(slow.stopCalls, 1, reason: 'premise: the stop is still out');

      // The consent resolves on: this process is the receiver now.
      final receiver = _Shell(binding, isIOS: true, backgroundSharing: true);
      final back = MapShell.healBehindStop(
        stop: shell._pauseStop!,
        heal: receiver.resubscriber.ensureRunning,
      );
      await pumpEventQueue();
      expect(receiver.engines, isEmpty, reason: 'ahead of the stop');

      slow.stopGate!.complete();
      await back;
      expect(slow.stopCalls, 1, reason: 'joined, not issued again');
      expect(receiver.engines, hasLength(1));
      expect(receiver.engines.single.foregroundClaims, isEmpty);
      await receiver.service.stop();
    });
  });

  // A shell mounted while the binding still holds the embedder's seed
  // (`detached`) is dispatched every state on the way out of it: `resumed`
  // first. So where a process the OS launched in the background leaves the
  // seed for `paused` after the mount, the resume handler runs in a process
  // nobody is looking at, with the pause right behind it in the same dispatch
  // loop. (That order is pinned in
  // `test/framework/lifecycle_synthesis_test.dart`; a shell mounted after the
  // binding left the seed is dispatched none of it.)
  group('a resume and a pause dispatched back to back', () {
    /// `resumed` then `paused` with nothing run between them, as one
    /// synthesised dispatch delivers them.
    Future<(_Shell, bool)> relaunched({
      required bool isIOS,
      required bool sharing,
    }) async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      final shell = _Shell(binding, isIOS: isIOS, backgroundSharing: sharing);
      final healed = shell.resume();
      final paused = shell.pause();
      await paused;
      final running = await healed;
      await pumpEventQueue();
      return (shell, running);
    }

    test('Android, sharing on: no start, no claim, one hand-off', () async {
      final (shell, running) = await relaunched(isIOS: false, sharing: true);

      expect(running, isFalse);
      expect(shell.engines, isEmpty);
      expect(shell.pauseLog, ['stop:idle', 'release', 'announce:true']);
    });

    test('sharing off, either platform: no start, no claim, nothing handed '
        'over', () async {
      for (final isIOS in [false, true]) {
        final (shell, running) = await relaunched(isIOS: isIOS, sharing: false);

        expect(running, isFalse, reason: 'isIOS=$isIOS');
        expect(shell.engines, isEmpty, reason: 'isIOS=$isIOS');
        expect(shell.pauseLog, ['stop:idle']);
      }
    });

    test('iOS, sharing on: one start, no claim — a session only started, '
        'which the next burst pauses', () async {
      // This process is the background receiver, so the start is wanted. It
      // reaches the engine behind the pause, and the claim is the strict
      // read: the lifecycle reads `paused` by then.
      final (shell, running) = await relaunched(isIOS: true, sharing: true);

      expect(running, isTrue);
      expect(shell.engines, hasLength(1));
      expect(shell.engines.single.foregroundClaims, isEmpty);
      expect(shell.pauseLog, isEmpty);

      // The burst that follows takes that session over and pauses it: no
      // standing REQ outlives the background tick.
      final coordinator = BackgroundBurstCoordinator(
        engine: shell.service,
        publisher: _NothingToPublish(),
        maintenance: _NothingToMaintain(),
        stagger: PublishStagger.none(),
        shutdownPublishPool: () async {},
        burstEnabled: () => true,
        onOpenOutcome: (_) {},
      );
      await coordinator.onTick(
        circleKey: 'a',
        circle: TestCircleFactory.createCircle(),
      );

      expect(shell.engines.single.burstOpenCalls, 1);
      expect(shell.engines.single.pauseCalls, 1);
      expect(shell.service.isPaused, isTrue);
      expect(shell.engines, hasLength(1), reason: 'a second session started');
    });
  });

  // The location service's in-memory cache holds plaintext coordinates. On a
  // branch where nothing receives while away it is dropped at the pause — and
  // the engine is still delivering then, through handlers that outlive its
  // stop. These go through the SERVICE's own handler chain: a direct call to
  // the ingest completes before anything that could race it.
  group('the location cache at a pause', () {
    final t0 = DateTime.utc(2026, 10, 11, 12);
    final circle = TestCircleFactory.createCircle(
      nostrGroupId: const [1, 2, 3],
      mlsGroupId: const [9, 9, 9],
      members: [
        TestCircleFactory.createMember(pubkey: 'peer-a'),
        TestCircleFactory.createMember(pubkey: 'peer-b'),
      ],
    );

    FfiRelayEvent located(String sender) => FfiRelayEvent(
      kind: FfiRelayEventKind.location,
      nostrGroupId: Uint8List.fromList(circle.nostrGroupId),
      senderPubkey: sender,
      content: '{}',
    );

    /// A running session whose streamed locations are ingested by a real
    /// [LocationSharingService], over a store whose write waits for the test.
    Future<
      (
        NostrSubscriptionService,
        FakeLiveSyncEngine,
        LocationSharingService,
        _ParkedStore,
      )
    >
    streaming() async {
      final store = _ParkedStore();
      final sharing = LocationSharingService(
        circleService: store,
        relayService: MockRelayService(),
        now: () => t0,
      );
      final engine = FakeLiveSyncEngine();
      final service = NostrSubscriptionService(
        router: LiveEventRouter(
          circleService: MockCircleService.new,
          circlesSnapshot: () async => [circle],
          secretBytes: () async => const [],
          parseLocation: (_, sender) async => DecryptedLocation(
            senderPubkey: sender,
            latitude: 1,
            longitude: 2,
            geohash: 'g',
            timestamp: t0,
            expiresAt: t0.add(const Duration(hours: 1)),
          ),
          ingestLocation: (circle, decrypted) => sharing.ingestStreamedLocation(
            circle: circle,
            decrypted: decrypted,
          ),
          reconcileRoster: (_) async {},
          onLocationsChanged: () {},
          onGroupUpdated: (_) {},
          onInvitationReceived: () {},
          onStatus: (_) {},
        ),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      return (service, engine, sharing, store);
    }

    test('is empty once the stop has completed, whatever arrived meanwhile',
        () async {
      final (service, engine, sharing, store) = await streaming();
      store.park = Completer<void>();
      // One handler parked inside the store write, one queued behind it.
      engine.controller
        ..add(located('peer-a'))
        ..add(located('peer-b'));
      await pumpEventQueue();
      expect(store.upserts, 1, reason: 'premise: the first is mid-write');

      // The pause: the stop first, the drop in the same run.
      final stopping = service.stop();
      sharing.onAppPaused();
      expect(await stopping, LiveSyncStopOutcome.stopped);
      expect(sharing.debugCachedLocationCount, 0);

      // Both handlers outlive the stop.
      store.park!.complete();
      await pumpEventQueue();

      expect(
        sharing.debugCachedLocationCount,
        0,
        reason: 'a coordinate was merged into the cache of a paused process: '
            'by the handler that was mid-write when the drop ran, or by the '
            'one that had not started yet',
      );
      expect(await sharing.cachedLocations(circle), isEmpty);
      expect(
        store.lastKnownRows.map((row) => row['senderPubkey']),
        ['peer-a', 'peer-b'],
        reason: 'both are persisted: a pause ends no identity, so the one '
            'that began after the stop is not dropped whole — it reaches the '
            'store and stays out of the closed cache',
      );

      // The resume opens it, and the store gives back what it was given.
      sharing.onAppResumed();
      store.snapshotLastKnownRows = [
        for (final row in store.lastKnownRows)
          DecryptedLocation(
            senderPubkey: row['senderPubkey']! as String,
            latitude: row['latitude']! as double,
            longitude: row['longitude']! as double,
            geohash: row['geohash']! as String,
            timestamp: row['timestamp']! as DateTime,
            expiresAt: row['expiresAt']! as DateTime,
          ),
      ];
      expect(await sharing.cachedLocations(circle), hasLength(2));
    });

    test('takes what the engine streams while the app is in front',
        () async {
      // Anti-vacuity for the test above: the same chain, with no pause.
      final (service, engine, sharing, store) = await streaming();
      engine.controller.add(located('peer-a'));
      await pumpEventQueue();

      expect(store.upserts, 1);
      expect(sharing.debugCachedLocationCount, 1);
      await service.stop();
    });

    test('is not refilled from the store by a read that was in flight',
        () async {
      final (service, _, sharing, store) = await streaming();
      store
        ..snapshotLastKnownRows = [
          DecryptedLocation(
            senderPubkey: 'peer-a',
            latitude: 1,
            longitude: 2,
            geohash: 'g',
            timestamp: t0,
            expiresAt: t0.add(const Duration(hours: 1)),
          ),
        ]
        ..parkSnapshot = Completer<void>();
      final reading = sharing.cachedLocations(circle);
      await pumpEventQueue();

      sharing.onAppPaused();
      store.parkSnapshot!.complete();

      expect(await reading, isEmpty);
      expect(
        sharing.debugCachedLocationCount,
        0,
        reason: 'every last-known row went back into the cache the pause '
            'had just dropped',
      );
      await service.stop();
    });
  });

  group('no session comes up behind the pause', () {
    test('a start the pause finds in flight is ended, then handed over',
        () async {
      final starting = FakeLiveSyncEngine()..startGate = Completer<void>();
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true)
        ..nextEngine(starting);
      final first = shell.resume();
      await pumpEventQueue();
      expect(starting.calls, ['start'], reason: 'premise: still connecting');

      // The gate is never opened: only the pause can end this start.
      await shell.pause();

      expect(await first, isFalse);
      expect(starting.calls, ['start', 'stop']);
      expect(shell.pauseLog, ['stop:stopped', 'release', 'announce:true']);
      expect(shell.service.isRunning, isFalse);
    });

    test('a restart between its own stop and its start', () async {
      final inbox = Completer<List<String>>();
      final shell = _Shell(
        binding,
        isIOS: false,
        backgroundSharing: true,
        inboxRelays: () => inbox.future,
      );
      final first = shell.resume();
      await pumpEventQueue();

      // The pause's stop finds no start in flight and no engine.
      await shell.pause();
      expect(shell.pauseLog, ['stop:idle', 'release', 'announce:true']);

      inbox.complete(const ['wss://inbox.test']);
      expect(await first, isFalse);
      await pumpEventQueue();
      expect(
        shell.engines,
        isEmpty,
        reason: 'the restart went on to start a session in a backgrounded '
            'process, behind the handoff',
      );
    });

    test('a heal that reaches the chain only after the pause', () async {
      final shell = _Shell(binding, isIOS: false, backgroundSharing: true);
      await shell.pause();

      expect(
        await shell.resubscriber.ensureRunning(),
        LiveSyncHealOutcome.stoodDown,
      );

      expect(shell.engines, isEmpty);
    });

    test('a detach, and whatever was queued behind it', () async {
      final shell = _Shell(binding, isIOS: true, backgroundSharing: true);
      expect(await shell.resume(), isTrue);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await shell.service.stop();
      expect(
        await shell.resubscriber.ensureRunning(),
        LiveSyncHealOutcome.stoodDown,
      );

      expect(shell.engines, hasLength(1));
    });
  });
}

/// A burst publisher with no circle to publish to.
class _NothingToPublish implements BurstPublisher {
  @override
  Circle? eligibleCircle(String circleKey) => null;

  @override
  Future<BurstFix?> openBurstPublishWindow(Iterable<Circle> circles) async =>
      null;

  @override
  void recordBurstPublishSkipped(Iterable<Circle> circles) {}

  @override
  Future<void> publishInBurst(
    Circle circle,
    BurstFix fix, {
    required bool received,
    required bool meshOnly,
  }) async {}
}

/// A burst's maintenance, with nothing due.
class _NothingToMaintain implements BurstMaintenance {
  @override
  Future<void> runKeyPackageIfDue(DateTime now) async {}

  @override
  Future<void> runRelayListIfDue(DateTime now) async {}

  @override
  Future<void> carryOnLeaves() async {}
}
