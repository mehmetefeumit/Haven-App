/// What the background publish cycle does with the circles it decided to
/// serve.
///
/// The gates in front of this step — identity, foreground ownership, the Play
/// disclosure pair, eligibility, session bring-up and reclaim — are pinned in
/// `background_location_task_cycle_gates_test.dart`. Everything here starts
/// from "at least one circle is due" and holds the promises the cycle makes
/// from that point on:
///
///  * the encrypt names the circle's MLS group, the account's identity pubkey
///    and a TTL a receiver can trust, and the event goes to the ROUTING relays
///    the engine handed back — a different set from the circle's own relay
///    list, which is why the fixtures below keep the two distinct;
///  * `notePublishAcked` is stamped if and only if at least one relay accepted
///    the event. A publish plane nobody acked must never read as healthy to
///    the sharing-health model the next foreground open consults (Rule 13:
///    acked means acked);
///  * a DEFERRED send is neither a failure nor a publish. It runs its staged
///    commits through publish → confirm-on-ack / roll-back-otherwise, stamps
///    nothing, and leaves the circle due — nothing reached a relay, so nothing
///    may read as if it had;
///  * one circle's failure costs one circle, never the cycle;
///  * a foreground resume or a service stop mid-loop stops the cycle where it
///    stands rather than advancing another MLS epoch behind the new owner's
///    back, and a stop still hands the Rule-14 single-session slot back;
///  * the peer-location fetch rides the wake-up the publish already paid for,
///    on its own nominal throttle (battery parity), and the periodic prune
///    yields to a foreground that came back mid-cycle;
///  * two circles served by one cycle never publish in the same wall-clock
///    second, and a burst that cannot fit its budget defers rather than
///    compresses.
///
/// All of it is driven through the real `onRepeatEvent` entry point over the
/// fakes in `test/mocks/background_task_fakes.dart`, so every assertion is
/// about a call the cycle actually made.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';
import '../mocks/background_task_fakes.dart';

/// The schedule entry the cycle keeps for [circle], if any.
DateTime? dueOf(BackgroundTaskHarness harness, CircleWithMembersFfi circle) =>
    harness.handler.dueTrackerForTest.nextDueForTest[scheduleKeyOf(circle)];

/// The kind-445 payload [FakeCircleManager.sealedOutcomeFor] produces for
/// [circle], so a published event can be tied back to the circle it came from.
String locationEventOf(CircleWithMembersFfi circle) =>
    '{"kind":445,"h":"${hexOf(circle.circle.nostrGroupId)}"}';

/// A stagger whose gap can be changed between ticks. The handler takes its
/// sampler once, at construction, so a test that needs a zero-gap seed tick
/// and then a wide gap switches the same instance.
class _SwitchableStagger extends PublishStagger {
  _SwitchableStagger()
    : super(
        rng: Random(1),
        minGap: Duration.zero,
        maxGap: Duration.zero,
        maxSpread: Duration.zero,
      );

  Duration gap = Duration.zero;

  @override
  Duration sampleGap({int totalPublishes = 2}) => gap;
}

/// The cross-isolate stamp the cycle writes at its very end, so "the cycle
/// reached its tail" is an observable rather than an inference.
Future<int?> readLastPublishMs() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(kBackgroundLastPublishMsKey);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(
    () =>
        SharedPreferences.setMockInitialValues(backgroundOwnsPublishingPrefs()),
  );

  group('the cycle carries every leave on', () {
    // Nothing calls the core's leave on a timer, so each cycle is one of its
    // wakes; the core alone holds the circle's sends from the intent on, on
    // every plane (`haven-core/tests/leave_fanout_e2e.rs`
    // `a_pending_leave_stops_location_publishing_on_every_plane_immediately`,
    // the full and the finish-only drives and the legacy seal).
    test('once per circle per cycle, claiming no foreground', () async {
      final a = circleFixture(seed: 1);
      final b = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(circles: [a, b]);

      await harness.tick(DateTime.now());

      expect(harness.relay.leaveCarryOns, [
        (groupId: hexOf(a.circle.mlsGroupId), foreground: false),
        (groupId: hexOf(b.circle.mlsGroupId), foreground: false),
      ]);
    });

    test('a circle whose leave named a wait is not asked again inside it',
        () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      harness.relay.leaveOutcomes[hexOf(circle.circle.mlsGroupId)] =
          LeaveOutcomeFfi(
            status: LeaveStatusFfi.proposed,
            retryAfterMs: BigInt.from(600000),
          );
      final at = DateTime.now();
      var now = at;
      harness.handler.clockForTest = () => now;

      await harness.tick(at);
      now = at.add(const Duration(minutes: 9));
      await harness.tick(now);
      expect(harness.relay.leaveCarryOns, hasLength(1), reason: 'inside it');

      now = at.add(const Duration(minutes: 20));
      await harness.tick(now);
      expect(harness.relay.leaveCarryOns, hasLength(2));
    });

    test('a cycle the stop overtook mid-drive carries no leave on after it',
        () async {
      // Every step checks the stop: what the teardown's unbounded wait reads
      // is the drive in flight, not a chain the abandoned cycle keeps adding
      // to.
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      final inFlight = Completer<void>();
      harness.relay
        ..driveGate = Completer<void>()
        ..inFlightNonLocationDrives = inFlight.future;
      harness.handler.teardownDrainBudget = Duration.zero;

      final cycle = harness.tick(DateTime.now());
      await pumpEventQueue();
      expect(harness.relay.drives, hasLength(1), reason: 'premise: driving');
      // The teardown waits on the drives in flight, its services still up.
      final teardown = harness.handler.onDestroy(DateTime.now(), false);
      await pumpEventQueue();
      harness.relay.driveGate!.complete();
      await cycle;

      expect(harness.relay.leaveCarryOns, isEmpty);
      inFlight.complete();
      await teardown;
    });

    test('a stop that lands inside the cycle starts no drive and no '
        'carry-on', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );
      // The teardown is held on a drive in flight, its services still up:
      // only the stop itself can keep the cycle from starting another.
      final inFlight = Completer<void>();
      harness.relay.inFlightNonLocationDrives = inFlight.future;
      harness.handler.teardownDrainBudget = Duration.zero;
      // The stop lands inside the cycle's own hold, past its first stop read.
      Future<void>? teardown;
      FakeWakeLockChannel().onAcquire = () {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
      };

      final cycle = harness.tick(DateTime.now());
      await cycle;

      expect(teardown, isNotNull, reason: 'premise: the stop landed');
      expect(harness.relay.drives, isEmpty);
      expect(harness.relay.leaveCarryOns, isEmpty);
      inFlight.complete();
      await teardown;
    });

    test('a stop landing mid-carry-on asks no further circle', () async {
      final a = circleFixture(seed: 1);
      final b = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(circles: [a, b]);
      harness.handler.teardownDrainBudget = Duration.zero;
      Future<void>? teardown;
      harness.relay.onResumeLeave = () {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
      };

      await harness.tick(DateTime.now());
      await teardown;

      expect(
        harness.relay.leaveCarryOns,
        hasLength(1),
        reason: "the second circle's leave started after the stop",
      );
    });

    test('a circle a leave ended for is forgotten', () async {
      final left = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [left]);
      harness.relay.leaveOutcomes[hexOf(left.circle.mlsGroupId)] =
          const LeaveOutcomeFfi(status: LeaveStatusFfi.completed);

      await harness.tick(DateTime.now());

      expect(harness.sharing.removed, [left.circle.mlsGroupId]);
    });
  });

  group("the cycle drives this isolate's stored records", () {
    // No live plane runs in the Android service's isolate, so nothing else
    // sends a change a relay has not taken yet while it holds the session.
    test('once per cycle, claiming no foreground', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );

      await harness.tick(DateTime.utc(2026, 10, 16, 12));

      expect(harness.relay.drives, [false]);
    });

    test('a cycle that drove and then published nothing still shuts the '
        'pool', () async {
      // Before: only the tail's 9b closed it, and every early return after
      // the drive left its sockets open until the next cycle that published.
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1, membershipStatus: 'pending')],
      );

      await harness.tick(DateTime.now());

      expect(harness.relay.drives, [false], reason: 'premise: it drove');
      expect(harness.manager.sealCalls, isEmpty, reason: 'premise');
      expect(harness.relay.shutdownCalls, 1);
    });

    test('never sooner than the wait the last drive named', () async {
      // A cycle runs when a circle is due; each tick below lands on one.
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      harness.relay.driveOutcome = ResumeOutcomeFfi(
        withdrawn: const [],
        requeued: const [],
        replayed: const [],
        retryAfterMs: BigInt.from(600000),
        errored: false,
      );
      // The cycle's schedule is kept on the wall clock, as every cycle test
      // here keeps it; the drive's wait is read against each tick's instant.
      final at = DateTime.now();

      await harness.tick(at);
      await harness.tick(at.add(const Duration(minutes: 9)));
      expect(harness.relay.drives, hasLength(1), reason: 'asked inside it');

      await harness.tick(at.add(const Duration(minutes: 20)));
      expect(harness.relay.drives, hasLength(2));
    });

    test('no drive log line names a circle, a relay or a group', () async {
      final logs = LogCapture.install();
      final circle = circleFixture(seed: 1);
      final planted = 'circle ${hexOf(circle.circle.mlsGroupId)} at '
          'wss://planted.relay.example';
      final errored = await BackgroundTaskHarness.start(circles: [circle]);
      errored.relay.driveOutcome = ResumeOutcomeFfi(
        withdrawn: const [],
        requeued: const [],
        replayed: [
          LocationMessageResultFfi(
            kind: LocationMessageResultKindFfi.location,
            location: const DecryptedLocationFfi(
              senderPubkey: 'cc',
              latitude: 1,
              longitude: 2,
              geohash: 'u0',
              timestamp: 1,
              expiresAt: 2,
            ),
            mlsGroupId: Uint8List.fromList(List.filled(32, 0xdd)),
            epoch: BigInt.zero,
          ),
        ],
        errored: true,
      );
      // The replayed fix's circle lookup fails.
      errored.manager.circleLookupThrows = StateError(planted);
      await errored.tick(DateTime.now());
      final failing = await BackgroundTaskHarness.start(circles: [circle]);
      failing.relay.driveThrows = StateError(planted);
      await failing.tick(DateTime.now());

      logs
        ..assertContains('[BackgroundTask] drive ended on an error')
        ..assertContains('[BackgroundTask] drive failed')
        ..assertContains('[BackgroundTask] replayed fix circle lookup failed')
        ..assertNoNeedles([
          hexOf(circle.circle.mlsGroupId),
          hexOf(circle.circle.nostrGroupId),
          'dd' * 32,
          'wss://planted.relay.example',
        ]);
    });

    test('a fix the drive replays is filed under its own circle', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      harness.relay.driveOutcome = ResumeOutcomeFfi(
        withdrawn: const [],
        requeued: const [],
        replayed: [
          LocationMessageResultFfi(
            kind: LocationMessageResultKindFfi.location,
            location: DecryptedLocationFfi(
              senderPubkey: 'cc' * 32,
              latitude: 48.8566,
              longitude: 2.3522,
              geohash: 'u09tvw',
              timestamp: 1700000000,
              expiresAt: 1700000228,
            ),
            mlsGroupId: circle.circle.mlsGroupId,
            epoch: BigInt.zero,
          ),
        ],
        errored: false,
      );

      await harness.tick(DateTime.utc(2026, 10, 16, 12));

      expect(
        harness.sharing.ingested.map((i) => hexOf(i.circle.nostrGroupId)),
        [hexOf(circle.circle.nostrGroupId)],
      );
      expect(harness.sharing.ingested.single.decrypted.senderPubkey, 'cc' * 32);
    });
  });

  group('a due circle is sealed, sent and stamped', () {
    test(
      'publishes to the engine-supplied relays and stamps one ack',
      () async {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(
          circles: [circle],
          events: FakeLocationEventService(jitteredSecs: 100),
        );

        final base = DateTime.now();
        await harness.tick(base);
        final after = DateTime.now();

        expect(
          harness.location.fixRequests,
          1,
          reason: 'one wake-up buys one GPS fix, shared by every due circle',
        );

        // Before: the cycle sealed with its own identity and an update
        // interval; the core now seals with the account's identity and stamps
        // the retention from the group's component (Rust's), and this isolate
        // claims no foreground.
        final seal = harness.manager.sealCalls.single;
        expect(hexOf(seal.mlsGroupId), hexOf(circle.circle.mlsGroupId));
        expect(seal.latitude, FakeLocationService.defaultFix.latitude);
        expect(seal.longitude, FakeLocationService.defaultFix.longitude);
        expect(seal.foreground, isFalse);

        final published = harness.relay.published.single;
        expect(published.eventJson, locationEventOf(circle));
        expect(
          published.relays,
          const ['wss://payload.relay.example'],
          reason:
              "routing comes from the sealed record, never from the circle's "
              'relay list — the fixture keeps the two different so a swap '
              'cannot pass',
        );

        final ack = harness.manager.acks.single;
        expect(hexOf(ack.nostrGroupId), hexOf(circle.circle.nostrGroupId));
        expect(ack.atMs, greaterThanOrEqualTo(base.millisecondsSinceEpoch));
        expect(ack.atMs, lessThanOrEqualTo(after.millisecondsSinceEpoch));

        final due = dueOf(harness, circle);
        expect(due, isNotNull);
        expect(
          due!.difference(base),
          greaterThanOrEqualTo(const Duration(seconds: 100)),
          reason: 'the circle is re-armed on the interval just sampled for it',
        );
        expect(
          due.difference(after),
          lessThanOrEqualTo(const Duration(seconds: 100)),
        );

        expect(await readLastPublishMs(), isNotNull);
        expect(
          hexOf(harness.sharing.fetched.single.nostrGroupId),
          hexOf(circle.circle.nostrGroupId),
        );
      },
    );

    test('stamps no ack when every relay refused the event', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        relay: FakeNostrRelayService()..acceptedBy = const [],
        events: FakeLocationEventService(jitteredSecs: 100),
      );

      final base = DateTime.now();
      await harness.tick(base);

      expect(
        harness.relay.published,
        hasLength(1),
        reason:
            'the publish was attempted, so the difference under test is '
            'the ack and nothing else',
      );
      expect(
        harness.manager.acks,
        isEmpty,
        reason:
            'stamping a publish nobody took makes a dead plane read as '
            'healthy on the next foreground open (Rule 13)',
      );
      expect(
        dueOf(harness, circle)!.difference(base),
        greaterThanOrEqualTo(const Duration(seconds: 100)),
        reason:
            'a rejected publish is a lost sample, not a reason to hammer '
            'the relay on every 72 s tick',
      );
    });

    test('a relay failure costs one circle, not the cycle', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      // The fake fails every publish while armed, so arm it from inside the
      // publish itself: only circle one's event throws.
      harness.relay.onPublish = (event) {
        harness.relay.publishError = event.eventJson == locationEventOf(one)
            ? Exception('relay refused')
            : null;
      };

      final base = DateTime.now();
      await harness.tick(base);

      expect(harness.manager.sealCalls, hasLength(2));
      expect(harness.relay.published, hasLength(2));
      expect(
        hexOf(harness.manager.acks.single.nostrGroupId),
        hexOf(two.circle.nostrGroupId),
        reason: 'only the circle whose publish survived is stamped',
      );
      expect(
        dueOf(harness, one),
        base,
        reason:
            'the failed circle keeps its seeded due-time, so the next '
            'tick retries it instead of waiting out a fresh cadence',
      );
      expect(
        dueOf(harness, two)!.difference(base),
        greaterThanOrEqualTo(const Duration(seconds: 100)),
      );
      expect(
        await readLastPublishMs(),
        isNotNull,
        reason: 'the cycle still reached its tail',
      );
    });

    test('re-arms on the nominal cadence when the jitter sampler is '
        'unavailable', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        events: FakeLocationEventService(jitteredSecs: null),
      );

      final base = DateTime.now();
      await harness.tick(base);
      final after = DateTime.now();

      expect(
        harness.events.sampledNominals,
        [BigInt.from(kLocationUpdateInterval.inSeconds)],
        reason:
            'the sampler is asked for jitter around the nominal cadence, '
            'once per burst',
      );
      final due = dueOf(harness, circle);
      expect(
        due!.difference(base),
        greaterThanOrEqualTo(kLocationUpdateInterval),
        reason:
            'an unavailable CSPRNG must not stall sharing; the nominal '
            'interval is the fallback',
      );
      expect(due.difference(after), lessThanOrEqualTo(kLocationUpdateInterval));
    });
  });

  group('a seal the core held', () {
    // The core alone holds a circle's sends — a leave, a change awaiting its
    // relays, a departure owed — and this isolate claims no foreground, so a
    // removal owed is left to a foreground and the seal answers
    // `Deferred(DepartureDue)` until then (in FinishOnly mode, the mode
    // `foreground: false` gives; `haven-core/tests/poll_send_drive_e2e.rs`
    // `the_fgs_cycles_finish_only_calls_leave_an_owed_removal_to_a_foreground_and_hold_sends`). Before: the
    // legacy seal staged the eviction itself and the cycle ran the Rule-13
    // ladder over it here; what a seal stages is now driven in Rust.
    // Every hold the core can name, `routingCollision` included: a circle
    // whose routing id another circle on this device holds is held until IT
    // is left, and nothing here retries it sooner.
    for (final cause in SendHeldFfi.values.where(
      (cause) => cause != SendHeldFfi.nothing,
    )) {
      test('${cause.name}: sends nothing for that circle, raises no failure '
          'and pulls no retry forward, while its sibling is sent', () async {
        final held = circleFixture(seed: 1);
        final sibling = circleFixture(seed: 2);
        Future<BackgroundTaskHarness> run({required bool hold}) async {
          final harness = await BackgroundTaskHarness.start(
            circles: [held, sibling],
            events: FakeLocationEventService(jitteredSecs: 100),
          );
          final heldHex = hexOf(held.circle.mlsGroupId);
          harness.manager.sealOutcome = (id) => hold && hexOf(id) == heldHex
              ? SealOutcomeFfi(
                  heldBy: cause,
                  replayed: const [],
                  errored: false,
                )
              : harness.manager.sealedOutcomeFor(id);
          return harness;
        }

        final base = DateTime.now();
        final unheld = await run(hold: false);
        await unheld.tick(base);
        final harness = await run(hold: true);
        await harness.tick(base);

        expect(
          harness.manager.sealCalls.map((c) => c.foreground),
          everyElement(isFalse),
          reason: 'the cycle asked the core as the Android service does',
        );
        expect(
          harness.relay.published.map((e) => e.eventJson),
          [locationEventOf(sibling)],
          reason: 'a location was sent for a circle whose sends are held',
        );
        expect(
          harness.manager.acks.map((a) => hexOf(a.nostrGroupId)),
          [hexOf(sibling.circle.nostrGroupId)],
        );
        expect(
          dueOf(harness, held),
          base,
          reason: 'a held circle stays due and is not re-armed as published',
        );
        expect(
          harness.location.capturedProfiles,
          hasLength(unheld.location.capturedProfiles.length),
          reason: 'a hold is no failure: the retry is not pulled forward, so '
              'a hold that lasts until a foreground costs no extra wake',
        );
      });
    }

    test("an ack is stamped at the task's own clock, which a test drives",
        () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      final at = DateTime.utc(2026, 10, 18, 9, 30);
      harness.handler.clockForTest = () => at;

      await harness.tick(at);

      expect(harness.manager.acks.single.atMs, at.millisecondsSinceEpoch);
    });

    test('the task reads no clock but its own', () {
      // One clock for every decision, so a test that moves it moves them all.
      final code = File('lib/src/services/background_location_task.dart')
          .readAsStringSync()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect('DateTime.now()'.allMatches(code), isEmpty);
      expect(code, isNot(contains('Stopwatch')));
    });

    test('the isolate routes a replay through NO provider', () {
      // "a fix the drive replays is filed under its own circle" proves a
      // replay lands on the injected service. This is the isolate half:
      // `background_location_task.dart`
      // runs in a separate Dart isolate with its own service instances, where
      // a Riverpod container does not exist — reaching for one would crash the
      // wake rather than refresh a map nobody is looking at.
      final code = File('lib/src/services/background_location_task.dart')
          .readAsStringSync()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final symbol in const [
        'flutter_riverpod',
        'ProviderContainer',
        'ref.read',
        'ref.watch',
        'ref.invalidate',
      ]) {
        expect(
          code,
          isNot(contains(symbol)),
          reason: 'the foreground-service isolate must not reach for `$symbol`'
              ' — it has no provider container of its own, and the foreground'
              " container belongs to another isolate's memory",
        );
      }
    });
  });

  group('every send outcome by variant', () {
    test('a send a relay answered is re-armed as published; one no relay '
        'took, or not made, stays due', () async {
      final base = DateTime.now();
      for (final answer in LocationPublishFfi.values) {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(
          circles: [circle],
          events: FakeLocationEventService(jitteredSecs: 100),
        );
        harness.relay.publishAnswer = answer;

        await harness.tick(base);

        final answered = answer == LocationPublishFfi.accepted ||
            answer == LocationPublishFfi.refused;
        expect(
          dueOf(harness, circle) == base,
          !answered,
          reason: '$answer',
        );
      }
    });

    test('an accepted send is stamped; every other one is not', () async {
      for (final answer in LocationPublishFfi.values) {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(circles: [circle]);
        harness.relay.publishAnswer = answer;

        await harness.tick(DateTime.now());

        expect(
          harness.manager.acks,
          answer == LocationPublishFfi.accepted ? hasLength(1) : isEmpty,
          reason: '$answer',
        );
      }
    });
  });

  group('Rule 15', () {
    test('no seal or send log line names a circle, a relay or a group',
        () async {
      final circle = circleFixture(
        seed: 1,
        relays: const ['wss://circle.needlehost.example'],
      );
      final capture = LogCapture.install();
      for (final (seal, answer) in [
        (
          const SealOutcomeFfi(
            heldBy: SendHeldFfi.departureDue,
            replayed: [],
            errored: true,
          ),
          null,
        ),
        (null, LocationPublishFfi.clockAhead),
        (null, LocationPublishFfi.superseded),
      ]) {
        final harness = await BackgroundTaskHarness.start(circles: [circle]);
        if (seal != null) harness.manager.sealOutcome = (_) => seal;
        harness.relay.publishAnswer = answer;
        await harness.tick(DateTime.now());
      }

      capture
        ..restore()
        ..assertContains('[BackgroundTask] seal drive ended on an error')
        ..assertContains('[BackgroundTask] send held by the core')
        ..assertContains('[BackgroundTask] publish reached no relay')
        ..assertContains('[BackgroundTask] sealed location not sent')
        ..assertNoNeedles([
          'wss://circle.needlehost.example',
          'wss://payload.relay.example',
          hexOf(circle.circle.mlsGroupId),
          hexOf(circle.circle.nostrGroupId),
        ]);
    });
  });

  group("a location takes the driver's one send", () {
    test('and never a commit ladder', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);

      await harness.tick(DateTime.now());

      expect(
        harness.relay.publishedLocations.map((e) => e.eventJson).toList(),
        [locationEventOf(circle)],
        reason:
            'a location nobody acked is superseded by the next tick within '
            'kLocationPublishMaxInterval, so it gets ONE send',
      );
      expect(
        harness.relay.publishedOnLadder,
        isEmpty,
        reason: 'nothing on this path is a commit',
      );
    });
  });

  group('an outcome the cycle cannot use costs one circle', () {
    test('a seal with neither a sealed location nor a hold skips its circle '
        'while the sibling publishes', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      final oneHex = hexOf(one.circle.mlsGroupId);
      harness.manager.sealOutcome = (id) => hexOf(id) == oneHex
          ? const SealOutcomeFfi(replayed: [], errored: false)
          : harness.manager.sealedOutcomeFor(id);

      final base = DateTime.now();
      await harness.tick(base);

      expect(harness.relay.published, hasLength(1));
      expect(harness.relay.published.single.eventJson, locationEventOf(two));
      expect(
        hexOf(harness.manager.acks.single.nostrGroupId),
        hexOf(two.circle.nostrGroupId),
      );
      expect(
        dueOf(harness, one),
        base,
        reason:
            'a circle that produced nothing is not re-armed as though it '
            'had published',
      );
      expect(
        dueOf(harness, two)!.difference(base),
        greaterThanOrEqualTo(const Duration(seconds: 100)),
      );
    });

    test('a seal that throws leaves the sibling publishing', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      final oneHex = hexOf(one.circle.mlsGroupId);
      harness.manager.sealOutcome = (id) {
        if (hexOf(id) == oneHex) throw StateError('engine unavailable');
        return harness.manager.sealedOutcomeFor(id);
      };

      final base = DateTime.now();
      await harness.tick(base);

      expect(harness.manager.sealCalls, hasLength(2));
      expect(harness.relay.published.single.eventJson, locationEventOf(two));
      expect(dueOf(harness, one), base, reason: 'not re-armed');
      expect(await readLastPublishMs(), isNotNull);
    });
  });

  group('ownership lost mid-cycle stops the cycle where it stands', () {
    test('a foreground resume mid-loop leaves the queued circles alone and '
        'skips the fetch', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(circles: [one, two]);
      harness.relay.onPublish = (_) =>
          BackgroundLocationManager.markForegroundActive(active: true);

      await harness.tick(DateTime.now());

      expect(
        harness.manager.sealCalls,
        hasLength(1),
        reason:
            'the queued circle must not advance an MLS epoch while the '
            'foreground owns publishing',
      );
      expect(
        harness.manager.acks,
        hasLength(1),
        reason: 'the publish that had already landed is still stamped',
      );
      expect(harness.sharing.fetched, isEmpty);
      expect(
        harness.location.streamListeners,
        0,
        reason: 'the UI isolate holds its own 1 Hz registration the moment it '
            'resumes, and two live platform requests coalesce at the provider '
            'to the tighter one — so keeping this one until the next watchdog '
            'tick quietly restores continuous GNSS. The top-of-cycle gate '
            'stands down for exactly this reason; mid-loop is the same '
            'handover, later',
      );
      expect(
        harness.handler.dueTrackerForTest.nextDueForTest,
        isEmpty,
        reason: 'and the schedules go with it, so the next handoff seeds '
            'every circle due-now rather than waiting out a stale jittered '
            'interval',
      );
      expect(
        await readLastPublishMs(),
        isNotNull,
        reason: 'the burst is abandoned but the cycle still leaves through its '
            'own tail — where the publish pool is closed — so the stamp for '
            'the publish that DID land is written. It cannot mislead the '
            'foreground into skipping a publish: the resume that caused this '
            'sets `_lastPublishTime` to now on its own',
      );
    });

    test('a foreground resume between the publishes and the fetch releases '
        'the registration too', () async {
      // The other mid-cycle exit: the burst finished on its own, and the
      // resume lands in the gap before the peer fetch. Same handover, same
      // two live requests if this path keeps its own.
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );
      harness.relay.onPublish = (_) =>
          BackgroundLocationManager.markForegroundActive(active: true);

      await harness.tick(DateTime.now());

      expect(
        harness.manager.sealCalls,
        hasLength(1),
        reason: 'the only due circle published before the resume landed',
      );
      expect(harness.sharing.fetched, isEmpty);
      expect(harness.location.streamListeners, 0);
    });

    /// A harness one full cycle in, re-armed and about to be interrupted
    /// mid-burst on a cycle whose peer fetch is NOT due.
    ///
    /// The throttle is what makes this isolating: on a first cycle the fetch
    /// loop runs, sees the same resume and stands down itself — so a mid-loop
    /// path that kept its registration would still end with none, and the
    /// assertion would pass against the defect it exists for.
    Future<BackgroundTaskHarness> reclaimedMidBurst() async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1), circleFixture(seed: 2)],
      );
      await harness.tick(DateTime.now());
      expect(
        harness.sharing.fetched,
        isNotEmpty,
        reason: 'the throttle is armed',
      );
      for (final seed in [1, 2]) {
        harness.handler.dueTrackerForTest.markBurstPublished(
          [scheduleKeyOf(circleFixture(seed: seed))],
          DateTime.now(),
        );
      }
      harness.relay.onPublish = (_) =>
          BackgroundLocationManager.markForegroundActive(active: true);
      return harness;
    }

    test('the mid-loop hand-back releases the registration on its own',
        () async {
      final harness = await reclaimedMidBurst();
      final fetchesBefore = harness.sharing.fetched.length;

      await harness.tick(DateTime.now());

      expect(
        harness.sharing.fetched,
        hasLength(fetchesBefore),
        reason: 'the fetch is throttled to its own cadence, so this cycle has '
            'no fetch-side stand-down for the mid-loop one to hide behind',
      );
      expect(harness.location.streamListeners, 0);
    });

    test('a failed publish does not re-arm the registration the mid-loop '
        'hand-back just released', () async {
      // The two recovery paths meet here: a publish that fails pulls the next
      // fix back to the watchdog period, and a foreground reclaim releases the
      // request outright. Taken in that order the retry re-registers for an
      // isolate that no longer owns publishing — and that request stands for
      // the rest of the session, because every later cycle stops at the
      // ownership gate above the only code that could cancel it.
      final harness = await reclaimedMidBurst();
      harness.relay.publishError = Exception('relay down');

      await harness.tick(DateTime.now());

      expect(harness.location.streamListeners, 0);
    });

    test('a service stop mid-loop drops the queued circles and hands the '
        'Rule-14 slot back', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(circles: [one, two]);
      Future<void>? teardown;
      harness.relay.onPublish = (_) {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
      };

      await harness.tick(DateTime.now());
      expect(teardown, isNotNull);
      await teardown!;

      expect(harness.manager.sealCalls, hasLength(1));
      expect(
        harness.sharing.fetched,
        isEmpty,
        reason:
            'a stop must not start commit-critical work that onDestroy '
            'would then have to drain without a budget',
      );
      expect(
        harness.manager.disposed,
        isTrue,
        reason:
            'the MLS single-session slot is freed by the dispose, not by '
            'dropping the reference — otherwise the foreground is locked out '
            'of its own database (Rule 14)',
      );
      expect(harness.relay.shutdownCalled, isTrue);
    });

    test('the stop latches the relay service before the teardown drains, '
        'so nothing the abandoned cycle starts reaches a relay', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );
      // Read before the teardown's first await, which every drain follows.
      final teardown = harness.handler.onDestroy(DateTime.now(), false);

      expect(harness.relay.latched, isTrue);
      await teardown;
    });

    test("each fetch is handed the service's stop, so a fetch under way "
        'takes in no further event after it', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
      );

      await harness.tick(DateTime.now());
      final stopped = harness.sharing.fetchStops.single;
      expect(stopped?.call(), isFalse);
      await harness.handler.onDestroy(DateTime.now(), false);

      expect(stopped?.call(), isTrue);
    });

    group('a stop landing past every earlier stop read', () {
      // Each test holds the teardown on a drive in flight, its services
      // still up: only the cycle's own stop read keeps the next step from
      // running.
      late BackgroundTaskHarness harness;
      late Completer<void> inFlight;
      Future<void>? teardown;
      // A block body: an arrow would hand the teardown's future back to a
      // fake that awaits its hook, and the cycle would wait on the teardown
      // that is draining it.
      void stop() {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
      }

      setUp(() async {
        harness = await BackgroundTaskHarness.start(
          circles: [circleFixture(seed: 1)],
        );
        inFlight = Completer<void>();
        harness.relay.inFlightNonLocationDrives = inFlight.future;
        harness.handler.teardownDrainBudget = Duration.zero;
        teardown = null;
      });

      Future<void> finish() async {
        expect(teardown, isNotNull, reason: 'premise: the stop landed');
        inFlight.complete();
        await teardown;
      }

      test('inside the last leave carry-on: the roster is not read again, no '
          'registration is listened to and no fix is asked', () async {
        int? rosterAtStop;
        harness.relay.onResumeLeave = () {
          stop();
          rosterAtStop ??= harness.manager.rosterReads;
        };

        await harness.tick(DateTime.now());

        expect(harness.manager.rosterReads, rosterAtStop);
        expect(harness.location.streamListeners, 0);
        expect(harness.location.fixRequests, 0);
        await finish();
      });

      test("inside the cycle's roster read: no registration is listened to "
          'and no fix is asked', () async {
        // The carry-on reads the roster first; the cycle's own read is next.
        final readsBefore = harness.manager.rosterReads;
        harness.manager.onRosterRead = () {
          if (harness.manager.rosterReads == readsBefore + 2) stop();
        };

        await harness.tick(DateTime.now());

        expect(harness.location.streamListeners, 0);
        expect(harness.location.fixRequests, 0);
        await finish();
      });

      test("in the hold taken before a circle's seal: nothing is sealed",
          () async {
        var acquires = 0;
        FakeWakeLockChannel().onAcquire = () {
          if (++acquires == 2) stop();
        };

        await harness.tick(DateTime.now());

        expect(harness.location.fixRequests, 1, reason: 'premise: fixed');
        expect(harness.manager.sealCalls, isEmpty);
        await finish();
      });

      test('between the seal and the send: nothing is sent', () async {
        harness.manager.sealOutcome = (mlsGroupId) {
          stop();
          return harness.manager.sealedOutcomeFor(mlsGroupId);
        };

        await harness.tick(DateTime.now());

        expect(harness.manager.sealCalls, hasLength(1), reason: 'premise');
        expect(harness.relay.publishedLocations, isEmpty);
        await finish();
      });
    });

    test('a stop while the GPS fix is outstanding abandons the fix', () async {
      final circle = circleFixture(seed: 1);
      final fixRequested = Completer<void>();
      final fix = Completer<Position>();
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        location: FakeLocationService(
          fix: () {
            fixRequested.complete();
            return fix.future;
          },
        ),
      );
      // Short, so a broken race fails here in milliseconds instead of sitting
      // out the real 15 s drain budget.
      harness.handler.teardownDrainBudget = const Duration(milliseconds: 500);

      var cycleFinished = false;
      final cycle = harness
          .tick(DateTime.now())
          .then((_) => cycleFinished = true);
      await fixRequested.future;

      await harness.handler.onDestroy(DateTime.now(), false);

      expect(
        cycleFinished,
        isTrue,
        reason:
            'the one-shot fix is the longest step in a cycle and holds no '
            'MLS state, so a stopping service must lose it rather than spend '
            'its stop window inside it',
      );
      await cycle;
      expect(harness.location.fixRequests, 1);
      expect(fix.isCompleted, isFalse);
      expect(harness.manager.sealCalls, isEmpty);
      expect(harness.relay.published, isEmpty);
    });
  });

  group('the peer fetch is throttled, fault-tolerant and abortable', () {
    test(
      'fetches on its own nominal throttle while every tick publishes',
      () async {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(circles: [circle]);

        // Due again before every tick, stated rather than borrowed from a
        // zero-second fake interval: a burst re-arms on `nextBurstDue`, which
        // never re-arms a circle sooner than `kLocationPublishMinInterval`
        // after its own publish. The subject here is the FETCH throttle, so
        // the publish cadence is set up rather than assumed.
        void dueNow() => harness.handler.dueTrackerForTest.markBurstPublished(
              [scheduleKeyOf(circle)],
              DateTime.now(),
            );

        final base = DateTime.now();
        await harness.tick(base);
        expect(harness.manager.sealCalls, hasLength(1));
        expect(harness.sharing.fetched, hasLength(1));

        dueNow();
        await harness.tick(base.add(const Duration(seconds: 60)));
        expect(harness.manager.sealCalls, hasLength(2));
        expect(
          harness.sharing.fetched,
          hasLength(1),
          reason:
              'per-circle decorrelation wakes more often than the nominal '
              'cadence; fetching every circle on every wake multiplies relay '
              'round-trips by the circle count, which is the battery cost this '
              'throttle exists to avoid',
        );

        dueNow();
        await harness.tick(base.add(kLocationUpdateInterval));
        expect(harness.manager.sealCalls, hasLength(3));
        expect(
          harness.sharing.fetched,
          hasLength(2),
          reason: 'a nominal interval has passed, so the receive plane runs',
        );
      },
    );

    test('a failing fetch does not stop the remaining circles', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(circles: [one, two]);
      harness.sharing.failFor.add(hexOf(one.circle.nostrGroupId));

      await harness.tick(DateTime.now());

      expect(
        harness.sharing.fetched.map((c) => hexOf(c.nostrGroupId)).toList(),
        [hexOf(one.circle.nostrGroupId), hexOf(two.circle.nostrGroupId)],
        reason:
            'one circle whose proposal cannot be processed must not cost '
            'every other circle its inbound locations',
      );
      expect(await readLastPublishMs(), isNotNull);
    });

    test(
      'a foreground resume during a fetch aborts the remaining fetches',
      () async {
        final one = circleFixture(seed: 1);
        final two = circleFixture(seed: 2);
        final harness = await BackgroundTaskHarness.start(circles: [one, two]);
        harness.sharing.onFetch = (_) =>
            BackgroundLocationManager.markForegroundActive(active: true);

        await harness.tick(DateTime.now());

        expect(
          harness.relay.published,
          hasLength(2),
          reason: 'both publishes had already landed before the resume',
        );
        expect(
          harness.sharing.fetched.map((c) => hexOf(c.nostrGroupId)).toList(),
          [hexOf(one.circle.nostrGroupId)],
          reason:
              'a fetch can publish and confirm a receiver-side auto-commit, '
              'so it belongs to whichever isolate owns the session',
        );
      },
    );
  });

  group('the prune runs on its own cadence and yields to the foreground', () {
    test(
      'prunes once every thirty cycles, then starts the count over',
      () async {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(circles: [circle]);
        final base = DateTime.now();

        for (var i = 0; i < 29; i++) {
          await harness.tick(base.add(Duration(seconds: 130 * i)));
        }
        expect(
          harness.manager.pruneExpiredLastKnownCalls,
          0,
          reason: 'the prune is an hourly SQLCipher write, not a per-tick one',
        );
        expect(harness.manager.pruneProcessedGiftWrapsCalls, 0);

        await harness.tick(base.add(const Duration(seconds: 130 * 29)));
        expect(harness.manager.pruneExpiredLastKnownCalls, 1);
        expect(harness.manager.pruneProcessedGiftWrapsCalls, 1);

        await harness.tick(base.add(const Duration(seconds: 130 * 30)));
        expect(
          harness.manager.pruneExpiredLastKnownCalls,
          1,
          reason: 'the counter restarts after a prune',
        );
        expect(harness.manager.pruneProcessedGiftWrapsCalls, 1);
      },
    );

    test('a foreground that resumed during the fetch defers the prune to the '
        'next cycle', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      final base = DateTime.now();

      for (var i = 0; i < 30; i++) {
        if (i == 29) {
          harness.sharing.onFetch = (_) =>
              BackgroundLocationManager.markForegroundActive(active: true);
        }
        await harness.tick(base.add(Duration(seconds: 130 * i)));
      }

      expect(
        harness.manager.pruneExpiredLastKnownCalls,
        0,
        reason:
            'the prune writes to the same database the foreground has '
            'just taken back',
      );
      expect(harness.manager.pruneProcessedGiftWrapsCalls, 0);

      harness.sharing.onFetch = null;
      await BackgroundLocationManager.markForegroundActive(active: false);
      await harness.tick(base.add(const Duration(seconds: 130 * 30)));

      expect(
        harness.manager.pruneExpiredLastKnownCalls,
        1,
        reason: 'a deferred prune is owed, not forgotten',
      );
      expect(harness.manager.pruneProcessedGiftWrapsCalls, 1);
    });

    test('the prune line states a magnitude, never how many rows went',
        () async {
      // The depth of the cached peer-location table is a property of who the
      // user shares with and how often (Rule 15), so only a bucket is logged.
      final logs = LogCapture.install();
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      harness.manager.pruneExpiredLastKnownRows = 7;
      final base = DateTime.now();

      for (var i = 0; i < 30; i++) {
        await harness.tick(base.add(Duration(seconds: 130 * i)));
      }

      expect(harness.manager.pruneExpiredLastKnownCalls, 1);
      logs
        ..assertContains('[BackgroundTask] Pruned 5+ expired row(s).')
        ..assertNoNeedles(['Pruned 7']);
    });
  });

  group('publishes inside one cycle are decorrelated', () {
    test('two circles served by one cycle publish a full gap apart', () async {
      // min == max, so the scheduled gap is an exact 250 ms rather than a
      // draw from a range; the assertion below allows for measurement slack.
      const gap = Duration(milliseconds: 250);
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        stagger: PublishStagger(rng: Random(1), minGap: gap, maxGap: gap),
      );
      final publishedAt = <DateTime>[];
      harness.relay.onPublish = (_) => publishedAt.add(DateTime.now());

      await harness.tick(DateTime.now());

      expect(
        harness.relay.published.map((e) => e.eventJson).toSet(),
        {locationEventOf(one), locationEventOf(two)},
        reason: 'staggering delays a publish, it never drops one',
      );
      expect(
        publishedAt[1].difference(publishedAt[0]),
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
        reason:
            'the engine binds the outer kind-445 created_at to the inner '
            'whole-second clock, so co-timed publishes link two circles to '
            'one device inside the signed event. Measured from inside the '
            'relay call, which sits after an unbounded encrypt, so the bound '
            'is the scheduled 250 ms less measurement slack',
      );
    });

    test('which circle leads a burst varies across BURSTS on one harness',
        () async {
      // Coalescing makes every circle of a burst due in the same instant, so
      // the order the cycle publishes them in is decided by the CSPRNG
      // permutation the cycle asks for — on EVERY burst, not just the first.
      //
      // Iterating BURSTS rather than harnesses is the whole point. A fresh
      // harness per seed only ever exercises the first burst after a seed,
      // and the defect this covers lives after it: re-arming each circle off
      // its OWN publish instant leaves no ties for the second burst, so
      // `dueKeysUpTo` sorts by due, the shuffle becomes dead code, the same
      // circle leads every burst for the whole session, and the delta between
      // the two circles' `created_at` prints the same number every time.
      //
      // The re-arm to one shared instant below is the shape `nextBurstDue`
      // records — pinned by the neighbouring test — driven directly so this
      // test does not have to wait out a 72 s cadence floor per burst.
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        // Zero gaps: the subject here is the ORDER, not the pacing.
        stagger: PublishStagger(
          rng: Random(4),
          minGap: Duration.zero,
          maxGap: Duration.zero,
          maxSpread: Duration.zero,
        ),
      );

      final leaders = <String>[];
      for (var burst = 0; burst < 12; burst++) {
        harness.handler.dueTrackerForTest.markBurstPublished(
          [one, two].map(scheduleKeyOf).toList(),
          DateTime.now(),
        );
        final before = harness.manager.sealCalls.length;
        await harness.tick(DateTime.now());
        expect(
          harness.manager.sealCalls.length,
          before + 2,
          reason: 'burst $burst must still publish both circles',
        );
        leaders.add(hexOf(harness.manager.sealCalls[before].mlsGroupId));
      }

      expect(
        leaders.toSet().length,
        greaterThan(1),
        reason: 'a stable "who goes first" across a session is a second-order '
            'fingerprint of the same burst; leaders were $leaders',
      );
    });

    test('a burst samples ONE jittered interval and re-arms every circle it '
        'published onto ONE due', () async {
      // The wake claim on this plane: the roster is re-armed on ONE draw and
      // ONE due, so the circles stay inside one selection window and one
      // cycle keeps serving them all. An independent draw per circle scatters
      // their dues across the whole [72 s, 168 s] band within a few cycles
      // and the device is back to a wake apiece.
      //
      // A REAL gap, deliberately. With `PublishStagger.none()` the two
      // publishes land ~0 ms apart, so a due-per-circle re-arm produces two
      // dues ~0 ms apart too and every bound below is satisfied by an
      // implementation that has none of these properties.
      // A gap wide enough that the cadence FLOOR is the binding clause: with
      // a 72 s draw and a 3 s spread, a due anchored only at the burst's
      // first publish lands 3 s inside the floor, which clears the one second
      // of measurement slack below by a factor of three.
      const gap = Duration(seconds: 3);
      const sampled = Duration(seconds: 72);
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        stagger: PublishStagger(rng: Random(5), minGap: gap, maxGap: gap),
        events: FakeLocationEventService(jitteredSecs: sampled.inSeconds),
      );
      // Recorded from inside the relay call, which sits just after the
      // encrypt: close enough to the publish start that a 2 s violation is
      // unambiguous, and the only observation point the fakes offer.
      final publishedAt = <DateTime>[];
      harness.relay.onPublish = (_) => publishedAt.add(DateTime.now());

      await harness.tick(DateTime.now());

      expect(harness.manager.sealCalls, hasLength(2));
      expect(
        harness.events.sampledNominals,
        [BigInt.from(kLocationUpdateInterval.inSeconds)],
        reason: 'one draw for the burst, not one per circle',
      );

      final dueOne = dueOf(harness, one)!;
      final dueTwo = dueOf(harness, two)!;
      expect(
        dueTwo,
        dueOne,
        reason: 'ONE due, exactly. Distinct dues make the next cycle order '
            'by them instead of by the CSPRNG permutation, so the shuffle '
            'becomes dead code from the second burst on and the two circles '
            'carry a constant delta between their created_at stamps forever',
      );

      // The floor, from the LAST publish. A due anchored only at the burst's
      // first publish re-arms the circle that published last a whole spread
      // early — 42 s against the 72 s Haven discloses.
      expect(publishedAt, hasLength(2));
      expect(
        dueOne.difference(publishedAt.last),
        greaterThanOrEqualTo(
          kLocationPublishMinInterval - const Duration(seconds: 1),
        ),
        reason: 'no circle may be re-armed sooner than the disclosed cadence '
            'floor after its OWN publish. Measured from inside the relay '
            'call, which sits after an unbounded encrypt, so the bound is the '
            'floor less one second of measurement slack — a third of what the '
            'first-publish anchor gets wrong here',
      );
      // ...and the ceiling, from the FIRST. A due anchored only at the last
      // publish adds the spread on top of the sampled interval, which the
      // 228 s retention has no room for.
      expect(
        dueOne.difference(publishedAt.first),
        lessThanOrEqualTo(sampled + kPublishStaggerMaxSpread),
        reason: 'the burst must not push its own spread on top of the '
            'interval it sampled',
      );
    });

    test('a circle MDK halts MID-burst publishes nothing', () async {
      // The roster is snapshotted at the top of the cycle, so a circle MDK
      // halts inside the GPS acquisition or the stagger spread is still asked
      // for a seal. MDK refuses a send to a halted group, and the refusal must
      // send nothing (Rule 8): the circle already in flight still goes out.
      const gap = Duration(milliseconds: 300);
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        stagger: PublishStagger(rng: Random(9), minGap: gap, maxGap: gap),
      );
      String? haltedHex;
      harness.manager.sealOutcome = (id) {
        if (hexOf(id) == haltedHex) throw StateError('group unrecoverable');
        return harness.manager.sealedOutcomeFor(id);
      };
      // Whichever circle the CSPRNG puts first, the OTHER is halted while
      // that publish is in flight.
      harness.relay.onPublish = (_) async {
        final firstOut = hexOf(harness.manager.sealCalls.first.mlsGroupId);
        final oneHex = hexOf(one.circle.mlsGroupId);
        haltedHex = firstOut == oneHex ? hexOf(two.circle.mlsGroupId) : oneHex;
      };

      await harness.tick(DateTime.now());

      expect(
        harness.relay.published,
        hasLength(1),
        reason: 'only the circle already in flight may go out; the seal MDK '
            'refused for the halted one sends nothing',
      );
    });

    test('a cycle whose stagger budget is spent defers the rest to the next '
        'tick', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final stagger = _SwitchableStagger();
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        stagger: stagger,
      );
      final base = DateTime.now();
      await harness.tick(base);
      expect(harness.manager.sealCalls, hasLength(2));

      // A gap wider than the whole burst budget. No single production draw
      // is this wide (`maxGapFor` caps one at 9 s); it stands in for a burst
      // whose accumulated gaps have spent the 30 s spread, which reaches the
      // same branch: the second slot cannot fit, and compressing it back to
      // zero is exactly what would put both circles in one wall-clock second.
      stagger.gap = kPublishStaggerMaxSpread + const Duration(seconds: 1);
      // Both due again, stated rather than borrowed from a zero-second fake
      // interval: `nextBurstDue` never re-arms a circle sooner than
      // `kLocationPublishMinInterval` after its own publish, and the subject
      // here is the SPREAD budget, not the cadence floor.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [one, two].map(scheduleKeyOf).toList(),
        DateTime.now(),
      );
      final dueBefore = {
        for (final circle in [one, two])
          hexOf(circle.circle.mlsGroupId): dueOf(harness, circle),
      };

      // A LATER tick than the publishes above. The repeat event is a watchdog
      // now, and it only acts on a registration that is not delivering or on
      // a circle that is already overdue — a tick stamped before the publish
      // it is meant to follow is neither.
      await harness.tick(base.add(const Duration(seconds: 1)));

      expect(
        harness.manager.sealCalls,
        hasLength(3),
        reason: 'only the first due circle fits inside the budget',
      );
      // WHICH circle takes the slot is a CSPRNG permutation — both circles are
      // due in the same instant, so asserting an identity here would pin the
      // stable burst order the shuffle exists to prevent.
      final served = hexOf(harness.manager.sealCalls.last.mlsGroupId);
      final deferred = [one, two]
          .map((c) => hexOf(c.circle.mlsGroupId))
          .firstWhere((hex) => hex != served);

      expect(
        dueOf(
          harness,
          [one, two].firstWhere(
            (c) => hexOf(c.circle.mlsGroupId) == deferred,
          ),
        ),
        dueBefore[deferred],
        reason: 'deferring is not re-arming: the circle stays overdue',
      );
      expect(dueBefore[deferred]!.isAfter(DateTime.now()), isFalse);

      await harness.tick(base.add(const Duration(seconds: 2)));

      expect(harness.manager.sealCalls, hasLength(4));
      expect(
        hexOf(harness.manager.sealCalls.last.mlsGroupId),
        deferred,
        reason: 'most-overdue-first, so a deferred circle is never starved',
      );
    });
  });
}
