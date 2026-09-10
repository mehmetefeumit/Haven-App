/// The Android foreground service's DELIVERY-DRIVEN cadence: one platform
/// location request, aimed at the earliest due-time, publishing on its fixes.
///
/// The gates in front of the cycle are pinned in
/// `background_location_task_cycle_gates_test.dart` and the publish loop in
/// `background_location_task_publish_cycle_test.dart`. What lives here is the
/// part that decides WHEN the GNSS receiver runs, and it is invisible
/// everywhere else: a service that registered nothing, or registered for one
/// second, still publishes — it just publishes on a 30 s HIGH_ACCURACY
/// one-shot per wake and keeps the receiver busy for a map nobody is looking
/// at. The only symptom is battery, hours later, off-device.
///
/// The promises asserted here:
///
///  * a delivered fix, not a timer, is what drives a publish, and the steady
///    state costs ZERO one-shots ([FakeLocationService.oneShotRequests]);
///  * the request is (re-)aimed BEFORE anything is published, even when
///    nothing is due — otherwise the 72 s watchdog is the only thing left
///    driving the cycle, through the very one-shot this phase retires;
///  * the aim is the earliest PRE-SAMPLED due minus the fix lead, so the fix
///    arrives just before the circle needs it and the realized inter-publish
///    gap stays inside the kind-445 retention;
///  * a re-registration's historical re-delivery of the fix just consumed
///    starts no second cycle, and an aligned aim is never re-registered — the
///    two halves of the loop breaker;
///  * a fix that lands mid-cycle is published by a follow-up cycle, never
///    dropped;
///  * displacement triggers NOTHING: the service has no motion awareness and
///    must not acquire one (`INV-L-MOTION-TRIGGER-BOUNDED`, and the
///    disclosure copy that rests on it);
///  * the scoped `Haven:publish` wake lock is taken before the first gate and
///    released on every exit path, including the failing ones — except once a
///    stop is signalled, from when it is `onDestroy`'s alone to release, so a
///    publish the drain abandoned cannot unlock the teardown behind it;
///  * the publish pool is closed at the end of every cycle — the Android half
///    of the presence copy's "no socket between publishes".
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/background_task_fakes.dart';

/// The schedule entry the cycle keeps for [key], if any.
DateTime? dueOfKey(BackgroundTaskHarness harness, String key) =>
    harness.handler.dueTrackerForTest.nextDueForTest[key];

/// The interval of the [n]th registration the cycle issued.
Duration registeredInterval(BackgroundTaskHarness harness, int n) {
  final profile = harness.location.capturedProfiles[n];
  if (profile is! BackgroundServiceStreamProfile) {
    fail(
      'registration $n asked for $profile — the foreground service must never '
      'take the map profile (1 m / 1 s), which is a continuous request',
    );
  }
  return profile.interval;
}

/// Asserts the [n]th registration aims a fix [kBackgroundFixLeadTime] ahead
/// of a due-time [dueIn] away, allowing only for the milliseconds the cycle
/// itself spent.
void expectAimedAt(
  BackgroundTaskHarness harness,
  int n, {
  required Duration dueIn,
  Duration slack = const Duration(seconds: 2),
}) {
  final want = dueIn - kBackgroundFixLeadTime;
  final got = registeredInterval(harness, n);
  expect(
    got,
    lessThanOrEqualTo(want),
    reason: 'the aim is measured from NOW, so it can only be shorter than '
        'the nominal $want by the time the cycle has already spent',
  );
  expect(
    got,
    greaterThan(want - slack),
    reason: 'a request $got against an expected $want is not measurement '
        'slack — the lead or the sampled interval is being applied wrongly',
  );
}

/// A stagger whose gap can be changed between cycles. The handler takes its
/// sampler once, at construction, so a test that needs a zero-gap seed and
/// then a burst-budget overrun switches the same instance.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWakeLockChannel lock;

  setUp(() {
    SharedPreferences.setMockInitialValues(backgroundOwnsPublishingPrefs());
    lock = FakeWakeLockChannel();
  });

  tearDown(() => lock.detach());

  /// A harness whose first cycle is fed by the S+ historical delivery, i.e.
  /// the steady state after a handoff on a modern device.
  Future<BackgroundTaskHarness> deliveringHarness({
    int circles = 1,
    int jitteredSecs = 100,
    PublishStagger? stagger,
  }) async {
    final harness = await BackgroundTaskHarness.start(
      circles: [for (var i = 1; i <= circles; i++) circleFixture(seed: i)],
      events: FakeLocationEventService(jitteredSecs: jitteredSecs),
      stagger: stagger,
    );
    harness.location.historicalFix = freshFix();
    return harness;
  }

  group('the cadence rides deliveries, not the watchdog', () {
    test('a delivered fix drives the cycle without a one-shot', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      harness.location.historicalFix = freshFix();

      // Cycle 1: the handoff. It registers, the provider answers with its
      // cached last location, and that fix is what gets published.
      await harness.tick(DateTime.now());
      expect(harness.manager.encryptCalls, hasLength(1));

      // Cycle 2: a genuine delivery at the circle's next due-time.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circle)],
        DateTime.now(),
      );
      await harness.deliverFix(freshFix(latitude: 40.7128, longitude: -74));

      expect(harness.manager.encryptCalls, hasLength(2));
      expect(
        harness.manager.encryptCalls.last.latitude,
        40.7128,
        reason: 'the publish carries the fix that woke it, not a re-read',
      );
      expect(
        harness.location.oneShotRequests,
        0,
        reason: 'the 30 s HIGH_ACCURACY one-shot is what this phase retires; '
            'a steady state that still pays one per publish saves nothing',
      );
      expect(
        harness.location.fixRequests,
        2,
        reason: 'the cycle must keep going through getCurrentLocation() — it '
            'is the one access-gated coordinate producer',
      );
    });

    test('a re-delivered fix with an identical timestamp runs no second '
        'cycle', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      final published = harness.manager.encryptCalls.length;
      final fix = freshFix();
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      await harness.deliverFix(fix);
      expect(harness.manager.encryptCalls.length, published + 1);

      // The circle is due AGAIN, so the only thing standing between the
      // replay and a second kind-445 carrying the identical coordinate is the
      // dedupe — and the roster read is what tells a cycle that ran and found
      // nothing from no cycle at all.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      final cycles = harness.manager.rosterReads;

      // Every re-registration re-delivers the fix just consumed (S+
      // historical delivery). Without the timestamp dedupe that is one
      // spurious cycle per registration, forever.
      await harness.deliverFix(fix);

      expect(
        harness.manager.encryptCalls.length,
        published + 1,
        reason: 'the same fix must not be published twice',
      );
      expect(
        harness.manager.rosterReads,
        cycles,
        reason: 'a replay carries no new information, so it must not cost a '
            'cycle at all — not even one that reads the roster and returns',
      );
      expect(harness.location.oneShotRequests, 0);
    });

    test('a delivery with nothing due publishes nothing and keeps the '
        'registration', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      final registrations = harness.location.capturedProfiles.length;

      await harness.deliverFix(freshFix());

      expect(
        harness.manager.encryptCalls,
        hasLength(1),
        reason: 'the circle is armed 100 s out; a fix arriving early is '
            'consumed silently, not published',
      );
      expect(
        harness.location.capturedProfiles,
        hasLength(registrations),
        reason: 'the aim did not move, so re-registering would only cost a '
            'cancel + listen and another historical re-delivery',
      );
    });

    test('a delivery that finds a circle due within the horizon publishes '
        'only that circle', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      harness.location.historicalFix = freshFix();
      await harness.tick(DateTime.now());
      expect(harness.manager.encryptCalls, hasLength(2));

      // Circle one comes due; circle two stays 100 s out.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(one)],
        DateTime.now(),
      );
      await harness.deliverFix(freshFix());

      expect(harness.manager.encryptCalls, hasLength(3));
      expect(
        hexOf(harness.manager.encryptCalls.last.mlsGroupId),
        hexOf(one.circle.mlsGroupId),
        reason: 'a shared fix must not collapse two circles onto one publish '
            'instant — the decorrelation the per-circle schedule exists for',
      );
    });

    test('a large displacement between two deliveries publishes nothing '
        'early', () async {
      // The foreground service has NO motion awareness and must not acquire
      // one: `INV-L-MOTION-TRIGGER-BOUNDED` says the extra motion-triggered
      // publish exists only in the UI isolate, and the disclosure copy is
      // written against that bound.
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      final publishes = harness.manager.encryptCalls.length;

      // ~9000 km, far past kMotionTriggerDistanceMeters, inside one cadence.
      await harness.deliverFix(freshFix(latitude: 51.5, longitude: -0.12));
      await harness.deliverFix(freshFix(latitude: -33.86, longitude: 151.2));

      expect(
        harness.manager.encryptCalls.length,
        publishes,
        reason: 'distance must not be a publish trigger in this isolate — a '
            'displacement-driven kind-445 is an activity-level leak the copy '
            'does not disclose for the background service',
      );
    });
  });

  group('the registration is aimed before anything is published', () {
    test('the registration is re-issued to the earliest pre-sampled due '
        'BEFORE the first publish', () async {
      final harness = await deliveringHarness();
      int? registrationsAtFirstEncrypt;
      harness.manager.encryptOutcome = (id) {
        registrationsAtFirstEncrypt ??=
            harness.location.capturedProfiles.length;
        return harness.manager.sentOutcomeFor(id);
      };

      await harness.tick(DateTime.now());

      expect(
        registrationsAtFirstEncrypt,
        1,
        reason: 'a publish can sit on a relay ladder for tens of seconds, and '
            'a teardown can cut the cycle short; the cadence has to already '
            'be armed by then or it is lost with the cycle',
      );
      expectAimedAt(harness, 0, dueIn: const Duration(seconds: 100));
    });

    test('a tick with nothing due from Idle registers for the earliest due '
        'and never one-shots', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(harness.location.capturedProfiles, hasLength(1));

      // The provider drops the request (a revoked provider, an unbound plugin
      // service): the isolate is back to Idle with every circle armed ~100 s
      // out. Nothing is due, so a cycle that only registered when it had
      // something to publish would leave the watchdog to drive sharing
      // through the one-shot it just retired.
      harness.location.failStream(Exception('provider disabled'));
      await harness.tick(DateTime.now().add(const Duration(seconds: 10)));

      expect(
        harness.location.capturedProfiles,
        hasLength(2),
        reason: 'the registration must be re-armed even with nothing due',
      );
      expectAimedAt(harness, 1, dueIn: const Duration(seconds: 100));
      expect(
        harness.manager.encryptCalls,
        hasLength(1),
        reason: 'nothing was due, so nothing more was published',
      );
      expect(
        harness.location.oneShotRequests,
        0,
        reason: 'a nothing-due cycle returns before it collects at all',
      );
    });

    test('an aligned registration is never re-issued', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(harness.location.capturedProfiles, hasLength(1));

      for (var i = 0; i < 3; i++) {
        await harness.deliverFix(freshFix(latitude: 51.0 + i));
      }

      expect(
        harness.location.capturedProfiles,
        hasLength(1),
        reason: 'a re-registration re-delivers the fix just consumed, which '
            'would drive another cycle, which would re-register: the '
            'alignment slack is the loop breaker',
      );
    });

    test('a failed publish leaves the circle due and shortens the '
        'registration to the retry cadence', () async {
      final harness = await deliveringHarness();
      harness.relay.publishError = Exception('relay refused');

      final base = DateTime.now();
      await harness.tick(base);

      expect(
        dueOfKey(harness, scheduleKeyOf(circleFixture(seed: 1))),
        isNotNull,
      );
      expect(
        dueOfKey(
          harness,
          scheduleKeyOf(circleFixture(seed: 1)),
        )!.isAfter(base.add(const Duration(seconds: 1))),
        isFalse,
        reason: 'a failed publish is not a publish: the circle stays due',
      );
      expect(
        harness.location.capturedProfiles,
        hasLength(2),
        reason: 'the first aim was the optimistic ~90 s one; a failure has to '
            'pull the retry back in, or the next attempt waits a full '
            'jittered interval instead of the watchdog period',
      );
      expectAimedAt(
        harness,
        1,
        dueIn: kBackgroundRepeatInterval,
      );
    });

    test('the registration is armed within the horizon surplus of the '
        'delivery that triggered it', () async {
      // The arithmetic bound: a fix is asked for `lead` before the due-time,
      // and `dueKeysUpTo` only looks `horizon` ahead — so a registration
      // issued more than `horizon - lead` after its triggering delivery aims
      // the NEXT fix outside the window that would select the circle it is
      // for. What makes it hold is placement, not speed: the two steps whose
      // own budgets each exceed the surplus on their own — the one-shot
      // (`kOneShotLocationTimeout`) and the publish burst
      // (`kPublishStaggerMaxSpread`) — both sit AFTER it.
      const surplus = Duration(seconds: 20);
      expect(kBackgroundFixHorizon - kBackgroundFixLeadTime, surplus);
      expect(kOneShotLocationTimeout, greaterThan(surplus));
      expect(kPublishStaggerMaxSpread, greaterThan(surplus));

      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      // A different interval for the next cadence, so the aim genuinely moves
      // and the re-registration this test measures actually happens.
      harness.events.jitteredSecs = 160;

      var registrationsAtFix = -1;
      var registrationsAtEncrypt = -1;
      harness.location.onGetCurrentLocation = () =>
          registrationsAtFix = harness.location.capturedProfiles.length;
      harness.manager.encryptOutcome = (id) {
        registrationsAtEncrypt = harness.location.capturedProfiles.length;
        return harness.manager.sentOutcomeFor(id);
      };

      final deliveredAt = DateTime.now();
      await harness.deliverFix(freshFix());
      final armedWithin = DateTime.now().difference(deliveredAt);

      expect(harness.location.capturedProfiles, hasLength(2));
      expect(
        registrationsAtFix,
        2,
        reason: 'the fix read can block for kOneShotLocationTimeout, which '
            'alone exceeds the surplus',
      );
      expect(
        registrationsAtEncrypt,
        2,
        reason: 'the publish burst can spend kPublishStaggerMaxSpread, which '
            'alone exceeds the surplus',
      );
      expect(
        armedWithin,
        lessThan(surplus),
        reason: 'measured end to end, so a future step inserted above the '
            'registration and slow only in production still has to justify '
            'itself here',
      );
    });

    test('an eligible roster that empties cancels the registration', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(harness.location.streamListeners, 1);

      harness.manager.circles = [];
      await harness.deliverFix(freshFix());

      expect(
        harness.location.streamListeners,
        0,
        reason: 'no circle can ever be published to, so keeping the receiver '
            'scheduled buys the user nothing but drain',
      );
    });
  });

  group('a fix delivered mid-cycle is not lost', () {
    /// Two circles, both due, with a burst budget that only fits the first —
    /// so the second is STILL due when the cycle ends, which is the state a
    /// follow-up has to serve.
    ///
    /// Seeded with a zero-gap stagger and widened afterwards, exactly as
    /// `background_location_task_publish_cycle_test.dart` does: the seed has
    /// to put both circles inside the fix horizon, and only then may the gap
    /// exceed the spread.
    Future<(BackgroundTaskHarness, _SwitchableStagger)> deferringHarness()
    async {
      final stagger = _SwitchableStagger();
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1), circleFixture(seed: 2)],
        events: FakeLocationEventService(jitteredSecs: 100),
        stagger: stagger,
      );
      harness.location.historicalFix = freshFix();
      await harness.tick(DateTime.now());
      stagger.gap = kPublishStaggerMaxSpread + const Duration(seconds: 1);
      for (final seed in [1, 2]) {
        harness.handler.dueTrackerForTest.markBurstPublished(
          [scheduleKeyOf(circleFixture(seed: seed))],
          DateTime.now(),
        );
      }
      return (harness, stagger);
    }

    test('a fix delivered mid-cycle is consumed by a follow-up cycle, never '
        'lost', () async {
      final (harness, _) = await deferringHarness();
      final seeded = harness.manager.encryptCalls.length;
      final second = freshFix(latitude: 40.7128, longitude: -74);
      harness.relay.onPublish = (_) {
        harness.relay.onPublish = null;
        harness.location.deliverFix(second);
      };

      await harness.deliverFix(freshFix(latitude: 51.5, longitude: -0.12));

      expect(
        harness.manager.encryptCalls.length,
        seeded + 2,
        reason: 'the burst budget deferred the second circle; the fix that '
            'landed mid-cycle is what a follow-up publishes it from',
      );
      expect(
        harness.manager.encryptCalls.last.latitude,
        40.7128,
        reason: 'the follow-up published the PENDING fix, not a re-read of '
            'the one the first cycle already used',
      );
      expect(
        harness.location.oneShotRequests,
        0,
        reason: 'a follow-up that one-shots has lost the fix it was for',
      );
    });

    test('with no delivery mid-cycle the deferred circle waits for the next '
        'one', () async {
      // The control for the test above: the follow-up must be caused by the
      // pending FIX, not by the deferral on its own.
      final (harness, _) = await deferringHarness();
      final seeded = harness.manager.encryptCalls.length;

      await harness.deliverFix(freshFix(latitude: 51.5, longitude: -0.12));

      expect(harness.manager.encryptCalls.length, seeded + 1);
    });

    test('a follow-up cycle dedupes the historical re-delivery of the '
        'pending fix', () async {
      final (harness, _) = await deferringHarness();
      final second = freshFix(latitude: 40.7128, longitude: -74);
      harness.relay.onPublish = (_) {
        harness.relay.onPublish = null;
        harness.location.deliverFix(second);
      };
      await harness.deliverFix(freshFix(latitude: 51.5, longitude: -0.12));
      final publishes = harness.manager.encryptCalls.length;

      // The follow-up's own re-registration replays that same fix.
      await harness.deliverFix(second);

      expect(
        harness.manager.encryptCalls.length,
        publishes,
        reason: 'without recording the pending fix as consumed, every '
            're-registration costs one spurious nothing-due cycle',
      );
    });
  });

  group('the first cycle after a handoff', () {
    test('waits the production constant, not whatever a test set', () {
      // The wait is shortened by the harness so an undelivered cycle costs
      // the suite nothing. Nothing else would notice if the seam's default
      // drifted away from the constant, and a production wait of zero would
      // put the 30 s one-shot back on every handoff.
      expect(
        BackgroundLocationTaskHandler().firstDeliveryWait,
        kFirstDeliveryWait,
      );
    });

    test('awaits the historical delivery and needs no one-shot', () async {
      final harness = await deliveringHarness();

      await harness.tick(DateTime.now());

      expect(harness.manager.encryptCalls, hasLength(1));
      expect(
        harness.location.oneShotRequests,
        0,
        reason: "the FGS isolate has its own service, so the map's warm fix "
            'is not in its cache; on S+ the registration itself answers with '
            "the provider's last location within milliseconds",
      );
    });

    test('without a historical delivery the first cycle one-shots once',
        () async {
      // API 23-30: no historical delivery exists, so the wait lapses and the
      // fallback runs — exactly as it always did.
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
        events: FakeLocationEventService(jitteredSecs: 100),
      );

      await harness.tick(DateTime.now());

      expect(harness.manager.encryptCalls, hasLength(1));
      expect(
        harness.location.oneShotRequests,
        1,
        reason: 'once, never twice: a second acquisition per cycle is the '
            'cost this phase exists to remove',
      );
    });
  });

  group('the watchdog only covers what a delivery cannot', () {
    test('the watchdog with a fresh delivery touches nothing', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      final registrations = harness.location.capturedProfiles.length;
      final fixes = harness.location.fixRequests;

      await harness.tick(DateTime.now().add(const Duration(seconds: 72)));

      expect(harness.manager.encryptCalls, hasLength(1));
      expect(harness.location.capturedProfiles, hasLength(registrations));
      expect(
        harness.location.fixRequests,
        fixes,
        reason: 'a delivering registration IS the cadence; a watchdog that '
            'ran a cycle anyway would re-introduce the 72 s poll',
      );
    });

    test('a tick that finds nothing to do leaves the cadence alive', () async {
      // The third input the test above never performs. `onRepeatEvent` records
      // the future it starts as THE in-flight cycle, and this no-op return
      // never reaches the method that clears that record — so a field left
      // pointing at a COMPLETED future makes every later tick, delivery and
      // handoff signal read "a cycle is already running" and return. The
      // symptom is the one this service exists not to have: one publish per
      // backgrounding, then silence, on the ordinary healthy path.
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(harness.manager.encryptCalls, hasLength(1));

      await harness.tick(DateTime.now().add(const Duration(seconds: 72)));

      // A circle comes due and the registration delivers for it, exactly as
      // the steady state does 100 s after the publish above.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      await harness.deliverFix(freshFix());

      expect(
        harness.manager.encryptCalls,
        hasLength(2),
        reason: 'a tick that had nothing to do must leave the isolate able to '
            'publish the next delivery — a latched single-flight field stops '
            'background sharing silently, ~72 s after it starts',
      );
    });

    test('the watchdog after kStreamPositionMaxAge of silence takes the '
        'one-shot fallback and re-registers', () async {
      // Indoors on a GNSS-only device the platform hibernates the provider
      // and its retry alarms wake nothing, so this is the ONLY thing that
      // publishes — which is why the plugin's permanent wake lock stays.
      final harness = await deliveringHarness();
      final base = DateTime.now();
      await harness.tick(base);
      expect(harness.location.oneShotRequests, 0);

      // The circle comes due during the silence, and the cached fix ages out
      // of kStreamPositionMaxAge while nothing is delivered.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      final silent = base.add(kStreamPositionMaxAge * 2);
      harness.location.clock = () => silent;
      await harness.tick(silent);

      expect(
        harness.manager.encryptCalls,
        hasLength(2),
        reason: 'the circle came due during the silence and must still be '
            'published, from the last known position if need be',
      );
      expect(
        harness.location.oneShotRequests,
        1,
        reason: 'the cached fix aged out, so the cycle falls through to the '
            'one-shot chain — the fallback the one-shot survives for',
      );
      expect(
        harness.location.capturedProfiles,
        hasLength(2),
        reason: 'a silent registration is re-issued, not trusted',
      );
    });

    test('a stream error re-arms the registration instead of latching Idle',
        () async {
      final harness = await deliveringHarness();
      final base = DateTime.now();
      await harness.tick(base);

      harness.location.failStream(Exception('provider disabled'));

      // Well inside kStreamPositionMaxAge: the ERROR, not staleness, is what
      // this tick has to act on. Without it the isolate would sit Armed on a
      // dead registration until the freshness window expired.
      await harness.tick(base.add(const Duration(seconds: 10)));

      expect(harness.location.capturedProfiles, hasLength(2));
      expect(harness.location.streamListeners, 1);
    });
  });

  group('ownership hand-offs', () {
    test('the foreground taking ownership cancels the registration and '
        'empties the schedule', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(harness.location.streamListeners, 1);

      await BackgroundLocationManager.markForegroundActive(active: true);
      await harness.tick(DateTime.now().add(const Duration(seconds: 10)));

      expect(
        harness.location.streamListeners,
        0,
        reason: 'two isolates holding a location registration at once is '
            'exactly the state the ownership stamp exists to prevent',
      );
      expect(harness.handler.dueTrackerForTest.nextDueForTest, isEmpty);
    });

    test('a tick that yields to the foreground leaves the isolate able to '
        'take publishing back', () async {
      // The ownership mirror of the no-op tick above: this exit never reaches
      // the cycle either, so a latch here means the handoff BACK to the
      // background never happens and the user's location stops leaving the
      // device for as long as the app stays backgrounded.
      final harness = await deliveringHarness();

      await BackgroundLocationManager.markForegroundActive(active: true);
      await harness.tick(DateTime.now());
      expect(
        harness.manager.encryptCalls,
        isEmpty,
        reason: 'the foreground owns publishing; two writers on one MLS group '
            'is what this yield exists to prevent',
      );

      // A real instant, not a synthetic future one: the tick's timestamp is
      // what every circle is seeded due AT, and a due-time past the burst
      // budget would defer the publish for a reason that has nothing to do
      // with the handoff under test.
      await BackgroundLocationManager.markForegroundActive(active: false);
      await harness.tick(DateTime.now());

      expect(
        harness.manager.encryptCalls,
        hasLength(1),
        reason: 'the foreground let go, so the next tick owns publishing and '
            'must run a cycle rather than read a completed future as one',
      );
      expect(harness.location.streamListeners, 1);
    });

    test('the paused signal runs a cycle immediately and the resumed signal '
        'cancels immediately', () async {
      final harness = await deliveringHarness();

      await harness.signal(kForegroundPausedSignal);

      expect(
        harness.manager.encryptCalls,
        hasLength(1),
        reason: 'waiting for the next 72 s watchdog tick to notice the '
            'handoff is up to 72 s of nobody publishing',
      );
      expect(harness.location.streamListeners, 1);

      await harness.signal(kForegroundResumedSignal);

      expect(
        harness.location.streamListeners,
        0,
        reason: 'the UI re-takes its own 1 Hz stream on resume; the service '
            'must have let go before that, not a delivery later',
      );
    });

    test('a resume during a cycle outlives the registration that cycle '
        're-arms', () async {
      // The signal cancels immediately, but a cycle already past its own
      // ownership gate can arm a request AFTER that cancel — here through the
      // retry cadence a failed publish sets. The UI isolate is re-taking its
      // 1 Hz stream at that moment, so what is left behind is the two-live-
      // requests state the ownership stamp exists to prevent.
      final harness = await deliveringHarness();
      harness.relay.publishError = Exception('relay down');
      harness.relay.onPublish = (_) =>
          harness.handler.onReceiveData(kForegroundResumedSignal);

      await harness.tick(DateTime.now());
      await pumpEventQueue();

      expect(
        harness.location.streamListeners,
        0,
        reason: 'the resumed signal only ever REMOVES capability, so nothing '
            'the cycle it interrupted arms may survive it',
      );
    });

    test('a paused signal while the foreground stamp is still fresh registers '
        'nothing', () async {
      // The signal is a prompt, never an authorisation: it goes through the
      // same reloaded-prefs ownership gate as every other input.
      SharedPreferences.setMockInitialValues({
        ...backgroundOwnsPublishingPrefs(),
        kForegroundActiveAtMsKey: DateTime.now().millisecondsSinceEpoch,
      });
      final harness = await deliveringHarness();

      await harness.signal(kForegroundPausedSignal);

      expect(harness.location.capturedProfiles, isEmpty);
      expect(harness.location.fixRequests, 0);
      expect(harness.manager.encryptCalls, isEmpty);
    });
  });

  group('the scoped publish wake lock', () {
    test('is acquired before the first gate and released on every exit path',
        () async {
      // Success, and then each way out: no identity, nothing due, an encrypt
      // that throws and a relay that throws. A lock leaked on a failure path
      // is a CPU held awake until the native 30 s timeout on every cycle.
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(lock.acquireCalls, isNotEmpty);
      expect(lock.held, isFalse, reason: 'released on the success path');

      for (final timeout in lock.acquireCalls) {
        expect(
          timeout,
          kPublishWakeLockTimeout,
          reason: 'the native side coerces into [1, MAX_TIMEOUT_MS]; asking '
              'for more is how the two sides drift apart unnoticed',
        );
      }

      // Nothing due.
      await harness.deliverFix(freshFix());
      expect(lock.held, isFalse);

      // The encrypt throws.
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      harness.manager.encryptOutcome = (_) =>
          throw StateError('engine unavailable');
      await harness.deliverFix(freshFix());
      expect(lock.held, isFalse, reason: 'released after an encrypt throw');

      // The relay throws.
      harness.manager.encryptOutcome = harness.manager.sentOutcomeFor;
      harness.relay.publishError = Exception('relay down');
      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      await harness.deliverFix(freshFix());
      expect(lock.held, isFalse, reason: 'released after a relay throw');
    });

    test('is held before the first encrypt and re-taken before the fetch',
        () async {
      final harness = await deliveringHarness();
      var heldAtEncrypt = false;
      var acquiresAtEncrypt = 0;
      var acquiresAtFetch = 0;
      harness.manager.encryptOutcome = (id) {
        heldAtEncrypt = lock.held;
        acquiresAtEncrypt = lock.acquireCalls.length;
        return harness.manager.sentOutcomeFor(id);
      };
      harness.sharing.onFetch = (_) =>
          acquiresAtFetch = lock.acquireCalls.length;

      await harness.tick(DateTime.now());

      expect(
        heldAtEncrypt,
        isTrue,
        reason: 'the fix is on its way off the device by then; the CPU hold '
            "has to be Haven's own and bounded before that, not a race",
      );
      expect(
        acquiresAtFetch,
        greaterThan(acquiresAtEncrypt),
        reason: 'a stagger wait plus a publish can spend most of the 30 s '
            'budget, so the fetch takes its own — the guarantee is "never '
            'held more than 30 s past the LAST acquire"',
      );
    });

    test('an identity-less cycle still releases what it took', () async {
      final harness = await BackgroundTaskHarness.start(
        circles: [circleFixture(seed: 1)],
        identityPubkey: null,
      );

      await harness.tick(DateTime.now());

      expect(
        lock.acquireCalls,
        isNotEmpty,
        reason: 'the lock is taken above the first gate, so a gate that '
            'returns is exactly the path a leak hides on',
      );
      expect(lock.held, isFalse);
    });

    test('onDestroy cancels the registration before draining, holds the lock '
        'through the drain and releases it last', () async {
      final harness = await deliveringHarness();
      Future<void>? teardown;
      var listenersDuringDrain = -1;
      harness.relay.onPublish = (_) async {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
        await pumpEventQueue();
        listenersDuringDrain = harness.location.streamListeners;
      };
      // The Rule-14 handback is the LAST thing the teardown does, and the only
      // sample that can see the state it runs in. Sampling `lock.held` from
      // inside the drained publish instead proves nothing: the cycle's own
      // `finally` has not run yet there, so the lock reads held whatever
      // `onDestroy` does afterwards.
      var heldAtHandback = false;
      harness.manager.onDispose = () => heldAtHandback = lock.held;
      // Every release, paired with whether the handback had already happened.
      // Once the stop is signalled there must be exactly ONE, the teardown's
      // own, after the handback: the drained cycle's `finally` stands down on
      // the same signal, because the lock is not reference-counted and its
      // release would drop the teardown's hold whenever it lands.
      final disposedAtEachRelease = <bool>[];
      lock.onRelease =
          () => disposedAtEachRelease.add(harness.manager.disposed);

      await harness.tick(DateTime.now());
      expect(teardown, isNotNull);
      await teardown!;

      expect(
        listenersDuringDrain,
        0,
        reason: 'a registration still delivering into a torn-down isolate is '
            'a fix nobody can publish and a receiver nobody turns off',
      );
      expect(
        heldAtHandback,
        isTrue,
        reason: "the plugin's permanent lock is already gone by then "
            '(stopForegroundService releases it synchronously before Dart '
            'runs), so the relay shutdown and this Rule-14 handback would '
            'otherwise be the one part of the teardown with no wake source '
            'at all',
      );
      expect(
        disposedAtEachRelease,
        [isTrue],
        reason: 'exactly one release, and it comes after the handback — not '
            'from the drained cycle on its way out, and not from the Kotlin '
            'lifecycle listeners that run before Dart has even begun',
      );
      expect(lock.held, isFalse);
    });

    test('the hold is re-taken after the unbounded commit-critical drain, '
        'never inherited across it', () async {
      // The other wait `onDestroy` performs, and the one that can outlast the
      // native 30 s ceiling on its own: a `fetchMemberLocations` that has
      // published a receiver-side auto-commit is drained WITHOUT a budget
      // (Rule 13). A hold taken before it is therefore worth nothing to the
      // relay shutdown and manager dispose that follow.
      final handler = BackgroundLocationTaskHandler()
        ..teardownDrainBudget = Duration.zero
        ..inFlightPublishForTest = Completer<void>().future;
      final wedgedFetch = Completer<void>();
      handler.inFlightCommitCriticalForTest = wedgedFetch.future;

      final destroy = handler.onDestroy(DateTime.now(), false);
      await pumpEventQueue();
      final acquiresBeforeTheFetchFinished = lock.acquireCalls.length;

      wedgedFetch.complete();
      await destroy;

      expect(
        lock.acquireCalls.length,
        greaterThan(acquiresBeforeTheFetchFinished),
        reason: 'the teardown that follows an unbounded wait must take its '
            'own hold; inheriting one from before the wait is a lock the '
            'native timeout may already have dropped',
      );
      expect(lock.held, isFalse, reason: 'and the last word is a release');
    });

    test('a publish abandoned by the drain releases nothing when it finally '
        'lands, and takes nothing either', () async {
      // The drain is BOUNDED, and past the budget the abandoned publish keeps
      // running — in Rust, for as long as its relay ladder takes
      // (`mls_session_handover.dart`). Whenever it lands, its own `finally`
      // runs; the native lock is `setReferenceCounted(false)`, so a release
      // there drops the hold `onDestroy` re-took for everything after the
      // drain. That hold is the whole point: the plugin's permanent lock is
      // already gone (`stopForegroundService` releases it synchronously
      // before Dart runs), so the unbounded Rule-13 wait, the relay shutdown
      // and the Rule-14 handback would have no wake source at all.
      final harness = await deliveringHarness();
      final wedgedPublish = Completer<void>();
      final wedgedFetch = Completer<void>();
      Future<void>? teardown;
      harness.handler
        ..teardownDrainBudget = Duration.zero
        ..inFlightCommitCriticalForTest = wedgedFetch.future;
      harness.relay.onPublish = (_) async {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
        await wedgedPublish.future;
      };

      final cycle = harness.tick(DateTime.now());
      // The zero budget lapses and the teardown settles into the unbounded
      // commit-critical wait, under the hold it took for it.
      await pumpEventQueue();
      expect(teardown, isNotNull);
      final acquiresAtAbandon = lock.acquireCalls.length;

      // ...and only now does the abandoned publish land.
      wedgedPublish.complete();
      await cycle;

      expect(
        lock.held,
        isTrue,
        reason: "from the stop signal on the scoped lock is onDestroy's "
            'alone — it releases once, after its drain. A cycle it abandoned '
            'that releases on its way out unlocks the CPU under the Rule-13 '
            'wait, the relay shutdown and the Rule-14 handback that follow',
      );
      expect(
        lock.acquireCalls.length,
        acquiresAtAbandon,
        reason: 'and it takes no new hold on its way out either: one acquired '
            'after onDestroy has already released would outlive the teardown '
            'with only the native 30 s ceiling to end it',
      );

      wedgedFetch.complete();
      await teardown!;
      expect(lock.held, isFalse, reason: 'and the last word is a release');
    });

    test('a cycle that starts after the stop signal takes no hold and arms '
        'no request', () async {
      // Not every route into the cycle knows a stop is in progress: the
      // pending-delivery follow-up in `_runCycleWithIdleTracking` runs after
      // the drain has abandoned the cycle it belongs to, and the plugin can
      // still hand the isolate a handoff signal — the entry point driven here
      // — while the teardown is inside its unbounded Rule-13 wait. Such a
      // cycle has nothing to publish, must not re-arm the platform request the
      // teardown just cancelled, and must not take a hold whose release now
      // belongs to `onDestroy` alone.
      final harness = await deliveringHarness();
      final wedgedFetch = Completer<void>();
      harness.handler.inFlightCommitCriticalForTest = wedgedFetch.future;
      final teardown = harness.handler.onDestroy(DateTime.now(), false);
      await pumpEventQueue();
      final acquires = lock.acquireCalls.length;
      final rosterReads = harness.manager.rosterReads;
      final registrations = harness.location.capturedProfiles.length;

      await harness.signal(kForegroundPausedSignal);

      expect(
        harness.manager.rosterReads,
        rosterReads,
        reason: 'the cycle must stand down above its first roster read — '
            'everything below it opens a session, a socket or a platform '
            'request underneath a teardown',
      );
      expect(
        harness.location.capturedProfiles.length,
        registrations,
        reason: 'a request armed here outlives the isolate that armed it: '
            'onDestroy has already cancelled, and nothing runs after it',
      );
      expect(
        lock.acquireCalls.length,
        acquires,
        reason: 'and a hold taken here is one onDestroy will not release — it '
            'releases exactly once, and it may already have done so',
      );
      expect(lock.held, isTrue, reason: 'the teardown still owns the hold');

      wedgedFetch.complete();
      await teardown;
      expect(lock.held, isFalse);
    });

    test('the teardown tail keeps its hold when the abandoned publish lands '
        'under it, with no commit-critical work to drain', () async {
      // The same abandonment on the overwhelmingly common teardown: nothing
      // commit-critical open, so all that is left after the drain is the tail
      // — the relay shutdown and the Rule-14 handback. `manager.onDispose` is
      // the only sample that can see the state the handback runs in.
      final harness = await deliveringHarness();
      final wedgedPublish = Completer<void>();
      Future<void>? teardown;
      late final Future<void> cycle;
      harness.handler.teardownDrainBudget = Duration.zero;
      harness.relay.onPublish = (_) async {
        teardown ??= harness.handler.onDestroy(DateTime.now(), false);
        await wedgedPublish.future;
      };
      // The teardown's own pool close is the one await between the abandoned
      // drain and the handback, so landing the publish from inside it ORDERS
      // the two instead of racing them.
      var landed = false;
      harness.relay.onShutdown = () async {
        if (landed) return;
        landed = true;
        wedgedPublish.complete();
        await cycle;
      };
      var heldAtHandback = false;
      harness.manager.onDispose = () => heldAtHandback = lock.held;

      cycle = harness.tick(DateTime.now());
      await cycle;
      await teardown!;

      expect(
        landed,
        isTrue,
        reason: 'anti-vacuity: the abandoned publish has to have landed '
            'BEFORE the handback, or this samples a teardown nothing '
            'interfered with',
      );
      expect(
        heldAtHandback,
        isTrue,
        reason: 'the Rule-14 handback is the last thing that frees the MLS '
            'session slot for the foreground, and it must not run on a CPU a '
            'cycle onDestroy abandoned handed back on its way out',
      );
      expect(lock.held, isFalse);
    });
  });

  group('the publish pool does not outlive the cycle', () {
    test('the publish pool is shut down at the end of every cycle', () async {
      final harness = await deliveringHarness();
      await harness.tick(DateTime.now());
      expect(
        harness.relay.shutdownCalls,
        1,
        reason: 'the Android presence claim is that no socket stays open '
            'between publishes; a pool closed only at teardown keeps one for '
            'the whole backgrounded session',
      );

      harness.handler.dueTrackerForTest.markBurstPublished(
        [scheduleKeyOf(circleFixture(seed: 1))],
        DateTime.now(),
      );
      await harness.deliverFix(freshFix());

      expect(harness.relay.shutdownCalls, 2);
      expect(
        harness.relay.published,
        hasLength(2),
        reason: 'a closed pool must re-connect on the next cycle, not stay '
            'shut — otherwise this saves the socket and loses the publish',
      );
    });

    test('a foreground resume mid-burst still closes the pool', () async {
      // The re-check between publishes protects the MLS single-writer
      // invariant, and it left the cycle by the one exit that skips the close
      // below — so on every resume-mid-burst the socket the Android presence
      // copy says is gone between publishes outlived the whole burst.
      final harness = await deliveringHarness(circles: 2);
      harness.relay.onPublish = (_) =>
          BackgroundLocationManager.markForegroundActive(active: true);

      await harness.tick(DateTime.now());

      expect(
        harness.manager.encryptCalls,
        hasLength(1),
        reason: 'the second circle must not advance an MLS epoch while the '
            'foreground owns publishing again',
      );
      expect(
        harness.relay.shutdownCalls,
        1,
        reason: 'leaving the burst early is still leaving the cycle; the pool '
            'closes on the way out or the presence claim has a hole exactly '
            'where the user came back',
      );
    });
  });
}
