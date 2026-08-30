/// The GATES in front of `BackgroundLocationTaskHandler`'s publish cycle: who
/// may publish, when, and how this isolate comes to hold the MLS session.
///
/// Each gate is the only thing standing between the background isolate and a
/// behaviour the app promises never to have — collecting a GPS fix before the
/// Play disclosure was accepted, advancing an MLS epoch while the foreground
/// still owns publishing (Rule 14: exactly one live session per MLS DB), or
/// opening a session for a service that is already stopping. A gate that
/// silently stops gating is invisible everywhere else: the cycle still
/// publishes, it just publishes when it must not. So every test here is pinned
/// on what the isolate DID — the fix it did or did not request, the encrypt it
/// did or did not perform, the schedule it kept or cleared, the guard it did or
/// did not query — never on a log line or a private field.
///
/// Two of these gates are the reason the isolate can be trusted at all. The
/// disclosure gate is asserted through `fixRequests`, not through the publish:
/// Play's rule is about COLLECTION, so a cycle that took a fix and then
/// declined to publish it would already have broken the promise. And the
/// foreground-ownership gate is asserted with the circle re-armed due-now, so
/// a missing gate produces a visible second encrypt rather than a silent pass.
///
/// The publish LOOP itself (encrypt → publish → ack → deferred sends → fetch →
/// prune) belongs to `background_location_task_publish_cycle_test.dart`;
/// everything here stops at that loop's front door.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart' show ForceReleaseOutcomeFfi;
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/background_task_fakes.dart';

/// Short enough that the reclaim path's two real confirmation probes cost
/// tens of milliseconds instead of the production 5 s + 3 s + 5 s.
const _shortProbeTimeout = Duration(milliseconds: 30);
const _shortProbeGap = Duration(milliseconds: 10);

/// Older than `2 * kBackgroundRepeatInterval` (144 s), i.e. past the window
/// after which a foreground stamp is evidence of a killed process rather than
/// of a live UI.
const _staleStampAge = Duration(seconds: 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The steady state after a pause with sharing on: the background owns
  // publishing and both disclosures are accepted. Each test below closes
  // exactly ONE gate against this baseline, so a failure names its gate.
  setUp(
    () => SharedPreferences.setMockInitialValues(
      backgroundOwnsPublishingPrefs(),
    ),
  );

  /// Re-seeds the store with [overrides] applied to the steady state; a `null`
  /// value REMOVES the key (a key never written is not the same input as a key
  /// written `false`). Must run before the harness is built.
  void seedPrefs(Map<String, Object?> overrides) {
    final values = backgroundOwnsPublishingPrefs();
    for (final entry in overrides.entries) {
      final value = entry.value;
      if (value == null) {
        values.remove(entry.key);
      } else {
        values[entry.key] = value;
      }
    }
    SharedPreferences.setMockInitialValues(values);
  }

  /// Fires the real repeat entry point on a hand-built handler and waits for
  /// the cycle it started — `BackgroundTaskHarness.tick` for the cases the
  /// harness cannot construct.
  Future<void> tickOf(BackgroundLocationTaskHandler handler, DateTime at) {
    handler.onRepeatEvent(at);
    return handler.inFlightPublishForTest ?? Future<void>.value();
  }

  group('identity gate', () {
    test(
      'with no identity loaded the cycle collects nothing and still leaves '
      'the isolate marked idle',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
          identityPubkey: null,
        );

        await harness.tick(DateTime.now());

        expect(
          harness.location.fixRequests,
          0,
          reason: 'there is no sender to encrypt for, so a fix would be '
              'location collected for nothing',
        );
        expect(harness.manager.encryptCalls, isEmpty);
        expect(harness.relay.published, isEmpty);
        expect(
          await BackgroundTaskHarness.readIdleFlag(),
          isTrue,
          reason: 'the foreground blocks on this flag before it restarts its '
              'own publisher; an early return that skipped the idle-tracking '
              "`finally` would strand it behind an isolate that isn't even "
              'publishing',
        );
      },
    );
  });

  group('foreground ownership', () {
    test(
      'a cold service restart before the foreground has ever stamped itself '
      'defers rather than racing it',
      () async {
        // The key has never been written: a service auto-restarted by Android
        // before `MapShell.initState` runs. `isForegroundActive` alone reads
        // that as "not active", which is why the cycle carries its own
        // explicit assume-active branch for the missing key.
        seedPrefs(<String, Object?>{kForegroundActiveAtMsKey: null});
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
        );

        await harness.tick(DateTime.now());

        expect(
          harness.location.fixRequests,
          0,
          reason: 'nothing yet says the UI isolate is gone, and two isolates '
              'publishing to one MLS group is a fork, not a duplicate',
        );
        expect(harness.manager.encryptCalls, isEmpty);
      },
    );

    test(
      'a foreground that resumes takes ownership back, and the background '
      'drops every per-circle schedule it was keeping',
      () async {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(circles: [circle]);

        await harness.tick(DateTime.now());
        expect(
          harness.handler.dueTrackerForTest.nextDueForTest,
          contains(scheduleKeyOf(circle)),
          reason: 'the background owned publishing for that first tick, so it '
              'must have taken the circle onto its own schedule — otherwise '
              'the clearing asserted below proves nothing',
        );

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(
          kForegroundActiveAtMsKey,
          DateTime.now().millisecondsSinceEpoch,
        );

        await harness.tick(DateTime.now());

        expect(
          harness.handler.dueTrackerForTest.nextDueForTest,
          isEmpty,
          reason: 'an emptied schedule is what makes every circle due-now on '
              'the NEXT handoff, bounding the gap across it to one background '
              'cycle instead of a full jittered interval',
        );
        expect(
          harness.manager.encryptCalls,
          hasLength(1),
          reason: 'the first publish re-armed the circle due-now, so a second '
              'encrypt here is exactly what a missing gate would produce: two '
              'isolates advancing one MLS epoch',
        );
      },
    );

    test(
      'a foreground stamp older than the staleness window hands ownership to '
      'the background',
      () async {
        // The killed-foreground case: OOM or force-stop, so the clean pause
        // write of `0` never happened. Publishing must resume regardless, or a
        // stuck stamp mutes background sharing for the rest of the process.
        seedPrefs(<String, Object?>{
          kForegroundActiveAtMsKey: DateTime.now()
              .subtract(_staleStampAge)
              .millisecondsSinceEpoch,
        });
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(circles: [circle]);

        await harness.tick(DateTime.now());

        expect(harness.manager.encryptCalls, hasLength(1));
        expect(
          harness.manager.encryptCalls.single.mlsGroupId,
          circle.circle.mlsGroupId,
        );
        expect(harness.relay.published, hasLength(1));
      },
    );
  });

  group('Play disclosure before collection', () {
    const refusals = <({String situation, bool? foreground, bool? background})>[
      (
        situation: 'the foreground disclosure was never shown',
        foreground: null,
        background: true,
      ),
      (
        situation: 'the foreground disclosure was declined',
        foreground: false,
        background: true,
      ),
      (
        situation: 'the background disclosure was never shown',
        foreground: true,
        background: null,
      ),
      (
        situation: 'the background disclosure was declined',
        foreground: true,
        background: false,
      ),
      (
        situation: 'neither disclosure was ever shown',
        foreground: null,
        background: null,
      ),
    ];

    for (final refusal in refusals) {
      test('no location is collected when ${refusal.situation}', () async {
        seedPrefs(<String, Object?>{
          kLocationDisclosureAcceptedKey: refusal.foreground,
          kLocationDisclosureBackgroundAcceptedKey: refusal.background,
        });
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
        );

        await harness.tick(DateTime.now());

        expect(
          harness.location.fixRequests,
          0,
          reason: "Play's rule is about COLLECTION: a cycle that took the fix "
              'and then declined to publish it would already have broken the '
              'promise the disclosure makes',
        );
        expect(harness.manager.encryptCalls, isEmpty);
        expect(
          harness.relay.published,
          isEmpty,
          reason: 'nothing derived from the device location may leave it '
              'before both disclosures are accepted',
        );
      });
    }

    test('both disclosures accepted is what unblocks publishing', () async {
      // The complement: without this the refusals above would also pass on a
      // cycle that could never publish for some unrelated reason.
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );

      await harness.tick(DateTime.now());

      expect(harness.location.fixRequests, 1);
      expect(harness.manager.encryptCalls, hasLength(1));
      expect(harness.relay.published, hasLength(1));
    });
  });

  group('publish eligibility', () {
    test(
      'a roster of only ineligible circles wakes no GPS at all',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [
            circleFixture(seed: 2, membershipStatus: 'pending'),
            // Accepted with an empty roster: a pre-cutover orphan whose MLS
            // group no longer exists, so every encrypt against it fails.
            circleFixture(seed: 3, members: const []),
          ],
        );

        await harness.tick(DateTime.now());

        expect(
          harness.location.fixRequests,
          0,
          reason: 'nothing can be published, so the wake cost of a fix buys '
              'the user only battery drain',
        );
        expect(harness.manager.encryptCalls, isEmpty);
        expect(
          harness.handler.dueTrackerForTest.nextDueForTest,
          isEmpty,
          reason: 'an ineligible circle must never occupy a publish slot',
        );
      },
    );

    test(
      'only the eligible circle in a mixed roster is published to',
      () async {
        final eligible = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(
          circles: [
            circleFixture(seed: 2, membershipStatus: 'pending'),
            circleFixture(seed: 3, members: const []),
            eligible,
          ],
        );

        await harness.tick(DateTime.now());

        expect(harness.location.fixRequests, 1);
        expect(
          harness.manager.encryptCalls.map((c) => c.mlsGroupId),
          [eligible.circle.mlsGroupId],
          reason: 'the background applies the SAME eligibility filter as the '
              'foreground publisher; a pending invitation is not consent to '
              'share a location with that group',
        );
        expect(
          harness.handler.dueTrackerForTest.nextDueForTest.keys,
          [scheduleKeyOf(eligible)],
        );
      },
    );
  });

  group('single-flight and the cross-isolate idle flag', () {
    test(
      'a repeat event fired while a cycle is running starts no second cycle',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
        );
        final at = DateTime.now();

        harness.handler.onRepeatEvent(at);
        harness.handler.onRepeatEvent(at);
        final cycle = harness.handler.inFlightPublishForTest;
        expect(
          cycle,
          isNotNull,
          reason: 'the first event must have registered a cycle for the '
              'second one to be turned away by',
        );
        await cycle;

        expect(
          harness.manager.encryptCalls,
          hasLength(1),
          reason: 'two cycles in flight are two writers on one MLS group — the '
              'single-writer invariant this isolate exists to keep',
        );
        expect(harness.location.fixRequests, 1);
      },
    );

    test('the skip is not a latch: the next cycle runs', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );

      await harness.tick(DateTime.now());
      await harness.tick(DateTime.now());

      expect(
        harness.manager.encryptCalls,
        hasLength(2),
        reason: 'a guard that failed to clear on completion would stop '
            'background sharing permanently after one cycle',
      );
    });

    test(
      'the isolate reports itself busy for the whole cycle and idle after it',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
        );
        bool? idleMidPublish;
        harness.relay.onPublish = (_) async {
          idleMidPublish = await BackgroundTaskHarness.readIdleFlag();
        };

        await harness.tick(DateTime.now());

        expect(
          idleMidPublish,
          isFalse,
          reason: 'the foreground reads this flag from disk to decide it may '
              'start publishing; reading `true` mid-encrypt is how both '
              'isolates end up calling encryptLocation at once',
        );
        expect(await BackgroundTaskHarness.readIdleFlag(), isTrue);
      },
    );
  });

  group('acquiring the MLS session', () {
    test(
      'a failed open at bring-up leaves the isolate its services, and the '
      'next cycle opens the free guard and publishes',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
          injectManager: false,
        );

        expect(
          harness.relay.initializeCalls,
          1,
          reason: 'the manager open is the step that fails routinely; if its '
              'failure aborted the bring-up the isolate would hold no relay '
              'service, and the recovery path — which keys off a NULL manager '
              '— could never repair that',
        );

        var guardQueries = 0;
        harness.handler
          ..overrideIsSessionLive = (({required dataDir}) async {
            guardQueries++;
            return false;
          })
          ..overrideCircleManager = harness.manager;

        await harness.tick(DateTime.now());

        expect(
          guardQueries,
          1,
          reason: 'the isolate held no manager, so the cycle must have gone '
              'through the acquisition path rather than straight to the '
              'publish loop',
        );
        expect(
          harness.manager.encryptCalls,
          hasLength(1),
          reason: 'the post-handoff steady state is a FREE guard: an '
              'acquisition that only knew how to reclaim would decline here '
              'and background publishing would stay dead through the very '
              'handoff meant to enable it',
        );
        expect(harness.relay.published, hasLength(1));
        expect(
          harness.relay.initializeCalls,
          1,
          reason: 'the aux services survived the failed open, so the '
              'acquisition had nothing left to rebuild',
        );
      },
    );

    /// Brings an isolate up to the state the harness cannot express: a manager
    /// adopted, and `NostrRelayService.initialize` throwing before anything was
    /// wired over it. `BackgroundTaskHarness.start` awaits the same bring-up,
    /// so it rethrows before it can hand the pieces back.
    Future<
      ({
        BackgroundLocationTaskHandler handler,
        FakeCircleManager manager,
        FakeNostrRelayService relay,
        FakeLocationService location,
        List<String> guardQueries,
      })
    >
    startWithFailedWiring() async {
      final manager = FakeCircleManager(circles: [circleFixture(seed: 1)]);
      final relay = FakeNostrRelayService()
        ..initializeErrorOnce = Exception('relay unavailable');
      final location = FakeLocationService();
      final guardQueries = <String>[];
      final handler = BackgroundLocationTaskHandler(
        stagger: PublishStagger.none(),
      )
        ..overrideCircleManager = manager
        ..overrideRelayService = relay
        ..overrideLocationSharingService = FakeLocationSharingService()
        ..overrideLocationService = location
        ..overrideLocationEventService = FakeLocationEventService()
        ..overrideIsSessionLive = (({required dataDir}) async {
          guardQueries.add(dataDir);
          return false;
        });

      await expectLater(
        handler.startWithoutBridgeForTest(
          identityManager: FakeIdentityManager(pubkey: kHarnessPubkeyHex),
          dataDir: 'test-data-dir',
        ),
        throwsA(isA<Exception>()),
        reason: 'the seam deliberately does not swallow the failure, so a '
            'test can see exactly where bring-up stopped',
      );

      return (
        handler: handler,
        manager: manager,
        relay: relay,
        location: location,
        guardQueries: guardQueries,
      );
    }

    test(
      'an isolate holding a manager it never wired repairs its services '
      "without touching another isolate's session",
      () async {
        final isolate = await startWithFailedWiring();

        await tickOf(isolate.handler, DateTime.now());

        expect(
          isolate.guardQueries,
          isEmpty,
          reason: 'this isolate already owns the session — asking the registry '
              'at all would mean it had taken the destructive reclaim path to '
              'fix its own missing wiring',
        );
        expect(
          isolate.relay.initializeCalls,
          2,
          reason: 'the failed attempt left the field null on purpose, so the '
              'repair builds a fresh relay service rather than reusing a '
              'half-initialised one',
        );
        expect(
          isolate.manager.encryptCalls,
          hasLength(1),
          reason: 'without this repair the isolate would hold the Rule-14 '
              'guard forever while publishing nothing',
        );
        expect(isolate.relay.published, hasLength(1));
      },
    );

    test('a repair that fails again publishes nothing', () async {
      final isolate = await startWithFailedWiring();
      isolate.relay.initializeErrorOnce = Exception('relay still unavailable');

      await tickOf(isolate.handler, DateTime.now());

      expect(
        isolate.location.fixRequests,
        0,
        reason: 'no relay service means nothing can be delivered, so taking a '
            'fix would collect a location the cycle cannot use',
      );
      expect(isolate.manager.encryptCalls, isEmpty);
      expect(
        isolate.relay.initializeCalls,
        2,
        reason: 'the repair must have been ATTEMPTED — a cycle that silently '
            'skipped it would leave the isolate wedged with no way back',
      );
    });

    /// Arms [handler] for the reclaim path: the guard is held on every query
    /// and the main isolate never answers a probe.
    void armReclaim(
      BackgroundTaskHarness harness, {
      required ForceReleaseOutcomeFfi outcome,
      required void Function() onProbe,
    }) {
      harness.handler
        ..overrideCircleManager = harness.manager
        ..overrideIsSessionLive = (({required dataDir}) async => true)
        ..livenessChannelReady = () {
          onProbe();
          return true;
        }
        ..livenessProbeTimeout = _shortProbeTimeout
        ..livenessProbeGap = _shortProbeGap
        ..overrideForceReleaseLiveSession = () async => outcome;
    }

    test(
      'a reclaim from a dead foreground ends in a publish, in the same cycle',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
          injectManager: false,
        );
        var probes = 0;
        armReclaim(
          harness,
          outcome: ForceReleaseOutcomeFfi.drained,
          onProbe: () => probes++,
        );

        await harness.tick(DateTime.now());

        expect(
          probes,
          2,
          reason: 'one silent window can be a GC pause in a healthy isolate, '
              'so the destructive call is authorised only by two independent '
              'silences',
        );
        expect(
          harness.manager.encryptCalls,
          hasLength(1),
          reason: 'a reclaim that recovers the session but does not go on to '
              'publish in the same cycle costs a full 72 s tick for nothing — '
              'the claim no other test could reach',
        );
        expect(harness.relay.published, hasLength(1));
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getInt(kBackgroundSessionReclaimAtMsKey),
          isNotNull,
          reason: 'the rate limit is consumed before the probe, so a crash '
              'mid-reclaim still leaves it spent instead of allowing a tight '
              'retry loop of engine teardowns',
        );
      },
    );

    test(
      'a release that times out publishes nothing: the holder may still have '
      'the manager',
      () async {
        final harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
          injectManager: false,
        );
        var probes = 0;
        armReclaim(
          harness,
          outcome: ForceReleaseOutcomeFfi.stopTimedOut,
          onProbe: () => probes++,
        );

        await harness.tick(DateTime.now());

        expect(
          probes,
          2,
          reason: 'the decision must have reached the release — otherwise the '
              'absent publish below would prove nothing about its outcome',
        );
        expect(harness.manager.encryptCalls, isEmpty);
        expect(harness.relay.published, isEmpty);
        expect(harness.location.fixRequests, 0);
      },
    );

    test('a stopping service acquires nothing and publishes nothing', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
        injectManager: false,
      );
      var guardQueries = 0;
      harness.handler.overrideIsSessionLive = ({required dataDir}) async {
        guardQueries++;
        return false;
      };

      await harness.handler.onDestroy(DateTime.now(), false);
      harness.handler.overrideCircleManager = harness.manager;

      await harness.tick(DateTime.now());

      expect(harness.manager.encryptCalls, isEmpty);
      expect(harness.relay.published, isEmpty);
      expect(harness.location.fixRequests, 0);
      // `onDestroy` also drops the identity, so the tick above stops at the
      // identity gate and cannot, on its own, tell a shutdown refusal from a
      // missing pubkey. `background_publish_stagger_teardown_test.dart` pins
      // the refusal itself; repeating its question here is what makes the
      // silence above attributable to the stop.
      expect(
        await harness.handler.ensureSessionForTest(dataDir: 'test-data-dir'),
        isFalse,
      );
      expect(
        guardQueries,
        0,
        reason: 'a service on its way out must not even ask: the two '
            'confirmation probes behind that question would spend the stop '
            'window Android gives it on a session about to be released again',
      );
    });
  });
}
