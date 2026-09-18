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
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';
import '../mocks/background_task_fakes.dart';

/// The retention a receiver reads off a kind-445 location: the widest publish
/// interval plus the network-propagation buffer.
final BigInt expectedTtlSecs = BigInt.from(
  kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
);

/// The schedule entry the cycle keeps for [circle], if any.
DateTime? dueOf(BackgroundTaskHarness harness, CircleWithMembersFfi circle) =>
    harness.handler.dueTrackerForTest.nextDueForTest[scheduleKeyOf(circle)];

/// A deferral carrying [commits] / [proposals], as the engine hands one back
/// when a stored convergence input still gates the circle or when it has just
/// staged a peer's eviction.
EncryptLocationOutcomeFfi deferralWith({
  List<CommitToPublishFfi> commits = const [],
  List<String> proposals = const [],
}) => EncryptLocationOutcomeFfi(
  deferredSend: DeferredSendFfi(
    unresolvedInputs: 1,
    discardedIntents: 0,
    repaired: false,
    commits: commits,
    proposals: proposals,
  ),
);

CommitToPublishFfi stagedCommit(int token) => CommitToPublishFfi(
  commitEventJson: '{"id":"staged-$token","kind":445}',
  pending: PendingStateRefFfi(token: BigInt.from(token)),
);

/// The kind-445 payload [FakeCircleManager.sentOutcomeFor] produces for
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

  group('a due circle is encrypted, published and stamped', () {
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

        final encrypt = harness.manager.encryptCalls.single;
        expect(hexOf(encrypt.mlsGroupId), hexOf(circle.circle.mlsGroupId));
        expect(encrypt.senderPubkeyHex, kHarnessPubkeyHex);
        expect(encrypt.latitude, FakeLocationService.defaultFix.latitude);
        expect(encrypt.longitude, FakeLocationService.defaultFix.longitude);
        expect(
          encrypt.updateIntervalSecs,
          expectedTtlSecs,
          reason:
              'the retention a receiver trusts is the widest publish '
              'interval plus the network buffer; anything shorter expires a '
              'live location before its successor can arrive',
        );

        final published = harness.relay.published.single;
        expect(published.eventJson, locationEventOf(circle));
        expect(
          published.relays,
          const ['wss://payload.relay.example'],
          reason:
              'routing comes from the engine outcome, never from the '
              'circle relay list — the fixture keeps the two different so a '
              'swap cannot pass',
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

    test('stamps no ack when no relay accepted the event', () async {
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

      expect(harness.manager.encryptCalls, hasLength(2));
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

  group('a deferred send runs the Rule-13 ladder instead of publishing', () {
    test('publishes a staged commit to the circle relays and confirms it on '
        'an ack', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      harness.manager.encryptOutcome = (_) =>
          deferralWith(commits: [stagedCommit(7)]);

      final base = DateTime.now();
      await harness.tick(base);

      final published = harness.relay.published.single;
      expect(published.eventJson, stagedCommit(7).commitEventJson);
      expect(
        published.relays,
        circle.circle.relays,
        reason:
            'a commit is routed by the circle, not by a location payload '
            'the engine never produced',
      );
      expect(harness.manager.confirmedTokens, [BigInt.from(7)]);
      expect(harness.manager.rolledBackTokens, isEmpty);
      expect(
        harness.manager.acks,
        isEmpty,
        reason: 'no location reached a relay, so nothing may report delivery',
      );
      expect(
        dueOf(harness, circle),
        base,
        reason: 'the circle is left due so the next tick retries the send',
      );
      expect(
        harness.events.sampledNominals,
        [BigInt.from(kLocationUpdateInterval.inSeconds)],
        reason: 'the interval is pre-sampled once per BURST, before the engine '
            'has answered — around the nominal cadence, never around '
            'anything derived from the outcome. What proves the deferral did '
            'not RE-ARM the circle is the untouched schedule asserted above, '
            'not whether the CSPRNG was consulted',
      );
    });

    test('leaves a staged commit owed when no relay accepted it', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        relay: FakeNostrRelayService()..acceptedBy = const [],
      );
      harness.manager.encryptOutcome = (_) =>
          deferralWith(commits: [stagedCommit(7)]);

      await harness.tick(DateTime.now());

      expect(harness.relay.published, hasLength(1));
      expect(
        harness.manager.rolledBackTokens,
        [BigInt.from(7)],
        reason:
            'confirming a commit no relay took applies state the group '
            'never agreed to; dropping it pins the group in PendingPublish. '
            'The fail rung is not a rollback for a peer eviction — Rust keeps '
            'the removal owed for a foreground pass to publish',
      );
      expect(harness.manager.confirmedTokens, isEmpty);
    });

    test('leaves a staged commit owed when the relay throws', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        relay: FakeNostrRelayService()..publishError = Exception('relay down'),
      );
      harness.manager.encryptOutcome = (_) =>
          deferralWith(commits: [stagedCommit(7)]);

      await harness.tick(DateTime.now());

      expect(harness.relay.published, hasLength(1));
      expect(harness.manager.rolledBackTokens, [BigInt.from(7)]);
      expect(harness.manager.confirmedTokens, isEmpty);
    });

    test('leaves a staged commit owed without a publish when the circle has '
        'no relays', () async {
      final circle = circleFixture(seed: 1, relays: const []);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      harness.manager.encryptOutcome = (_) =>
          deferralWith(commits: [stagedCommit(7)]);

      await harness.tick(DateTime.now());

      expect(
        harness.relay.published,
        isEmpty,
        reason: 'there is nowhere to send it, so no publish is attempted',
      );
      expect(
        harness.manager.rolledBackTokens,
        [BigInt.from(7)],
        reason:
            'an unsendable commit must still leave the ladder, or the '
            'group stays wedged with a commit that is neither confirmed nor '
            'rolled back',
      );
      expect(harness.manager.confirmedTokens, isEmpty);
    });

    test(
      'publishes bare proposals to the circle relays and confirms nothing',
      () async {
        final circle = circleFixture(seed: 1);
        final harness = await BackgroundTaskHarness.start(
          circles: [circle],
          events: FakeLocationEventService(jitteredSecs: 100),
        );
        harness.manager.encryptOutcome = (_) =>
            deferralWith(proposals: const ['p1', 'p2']);

        final base = DateTime.now();
        await harness.tick(base);

        expect(harness.relay.published.map((e) => e.eventJson).toList(), [
          'p1',
          'p2',
        ]);
        for (final event in harness.relay.published) {
          expect(event.relays, circle.circle.relays);
        }
        expect(
          harness.manager.confirmedTokens,
          isEmpty,
          reason:
              'a proposal carries no staged state, so there is nothing to '
              'apply and nothing to undo',
        );
        expect(harness.manager.rolledBackTokens, isEmpty);
        expect(harness.manager.acks, isEmpty);
        expect(dueOf(harness, circle), base, reason: 'still due');
      },
    );

    test('a proposal no relay accepted still lets the cycle finish', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(
        circles: [circle],
        relay: FakeNostrRelayService()..acceptedBy = const [],
      );
      harness.manager.encryptOutcome = (_) =>
          deferralWith(proposals: const ['p1', 'p2']);

      await harness.tick(DateTime.now());

      expect(harness.relay.published, hasLength(2));
      expect(harness.manager.rolledBackTokens, isEmpty);
      expect(harness.manager.confirmedTokens, isEmpty);
      expect(
        await readLastPublishMs(),
        isNotNull,
        reason: 'losing a proposal costs a cycle, so it must not abort one',
      );
    });
  });

  group('the two publish planes take different ladders', () {
    test('a location takes the one-shot ladder', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);

      await harness.tick(DateTime.now());

      expect(
        harness.relay.publishedLocations.map((e) => e.eventJson).toList(),
        [locationEventOf(circle)],
        reason:
            'a location nobody acked is superseded by the next tick within '
            'kLocationPublishMaxInterval, so it gets ONE bounded attempt — '
            'and the radio sleeps instead of climbing a 49 s retry ladder',
      );
      expect(
        harness.relay.publishedOnLadder,
        isEmpty,
        reason: 'nothing on this path is a commit',
      );
    });

    test('a staged commit keeps the retry ladder', () async {
      final circle = circleFixture(seed: 1);
      final harness = await BackgroundTaskHarness.start(circles: [circle]);
      harness.manager.encryptOutcome = (_) =>
          deferralWith(commits: [stagedCommit(7)], proposals: const ['p1']);

      await harness.tick(DateTime.now());

      expect(
        harness.relay.publishedOnLadder.map((e) => e.eventJson).toList(),
        [stagedCommit(7).commitEventJson, 'p1'],
        reason:
            'a commit that is neither confirmed nor rolled back forks the '
            'group (Rule 13); no later tick supersedes it, so it keeps the '
            '3-attempt ladder — as does the proposal that rides with it',
      );
      expect(
        harness.relay.publishedLocations,
        isEmpty,
        reason:
            'the one-shot ladder must never carry an event whose outcome '
            'resolves a PendingStateRef',
      );
      expect(harness.manager.confirmedTokens, [BigInt.from(7)]);
    });
  });

  group('an outcome the cycle cannot use costs one circle', () {
    test('an outcome with neither arm set skips its circle while the sibling '
        'publishes', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      final oneHex = hexOf(one.circle.mlsGroupId);
      harness.manager.encryptOutcome = (id) => hexOf(id) == oneHex
          ? const EncryptLocationOutcomeFfi()
          : harness.manager.sentOutcomeFor(id);

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

    test('an encrypt that throws leaves the sibling publishing', () async {
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        events: FakeLocationEventService(jitteredSecs: 100),
      );
      final oneHex = hexOf(one.circle.mlsGroupId);
      harness.manager.encryptOutcome = (id) {
        if (hexOf(id) == oneHex) throw StateError('engine unavailable');
        return harness.manager.sentOutcomeFor(id);
      };

      final base = DateTime.now();
      await harness.tick(base);

      expect(harness.manager.encryptCalls, hasLength(2));
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
        harness.manager.encryptCalls,
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
        harness.manager.encryptCalls,
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

      expect(harness.manager.encryptCalls, hasLength(1));
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
      expect(harness.manager.encryptCalls, isEmpty);
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
        expect(harness.manager.encryptCalls, hasLength(1));
        expect(harness.sharing.fetched, hasLength(1));

        dueNow();
        await harness.tick(base.add(const Duration(seconds: 60)));
        expect(harness.manager.encryptCalls, hasLength(2));
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
        expect(harness.manager.encryptCalls, hasLength(3));
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
        final before = harness.manager.encryptCalls.length;
        await harness.tick(DateTime.now());
        expect(
          harness.manager.encryptCalls.length,
          before + 2,
          reason: 'burst $burst must still publish both circles',
        );
        leaders.add(hexOf(harness.manager.encryptCalls[before].mlsGroupId));
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

      expect(harness.manager.encryptCalls, hasLength(2));
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

    test('a circle flagged Unrecoverable MID-burst is not published by it',
        () async {
      // The roster is snapshotted at the top of the cycle — BEFORE the GPS
      // acquisition and before the whole stagger spread — so without a
      // re-read a circle the engine flags inside either is still sent to,
      // which is the one thing `CircleService` says must never happen
      // (Rule 8). Every other eligibility test here blocks the circle before
      // the cycle starts, where the snapshot already answers correctly.
      const gap = Duration(milliseconds: 300);
      final one = circleFixture(seed: 1);
      final two = circleFixture(seed: 2);
      final harness = await BackgroundTaskHarness.start(
        circles: [one, two],
        stagger: PublishStagger(rng: Random(9), minGap: gap, maxGap: gap),
      );
      // Whichever circle the CSPRNG puts first, the OTHER is flagged while
      // that publish is in flight.
      harness.relay.onPublish = (_) async {
        final firstOut = hexOf(harness.manager.encryptCalls.first.mlsGroupId);
        final blocked = firstOut == hexOf(one.circle.mlsGroupId) ? two : one;
        harness.handler.circleServiceForTest!
            .markCircleBlocked(blocked.circle.mlsGroupId);
      };

      await harness.tick(DateTime.now());

      expect(
        harness.manager.encryptCalls,
        hasLength(1),
        reason: 'only the circle already in flight may go out; the one '
            'flagged mid-burst must be skipped',
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
      expect(harness.manager.encryptCalls, hasLength(2));

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
        harness.manager.encryptCalls,
        hasLength(3),
        reason: 'only the first due circle fits inside the budget',
      );
      // WHICH circle takes the slot is a CSPRNG permutation — both circles are
      // due in the same instant, so asserting an identity here would pin the
      // stable burst order the shuffle exists to prevent.
      final served = hexOf(harness.manager.encryptCalls.last.mlsGroupId);
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

      expect(harness.manager.encryptCalls, hasLength(4));
      expect(
        hexOf(harness.manager.encryptCalls.last.mlsGroupId),
        deferred,
        reason: 'most-overdue-first, so a deferred circle is never starved',
      );
    });
  });
}
