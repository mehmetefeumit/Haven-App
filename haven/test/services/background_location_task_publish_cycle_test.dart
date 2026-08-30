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
            'once per publish',
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
        isEmpty,
        reason: 'no re-arm was even attempted',
      );
    });

    test('rolls a staged commit back when no relay accepted it', () async {
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
            'never agreed to; dropping it pins the group in PendingPublish',
      );
      expect(harness.manager.confirmedTokens, isEmpty);
    });

    test('rolls a staged commit back when the relay throws', () async {
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

    test('rolls a staged commit back without a publish when the circle has '
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
        await readLastPublishMs(),
        isNull,
        reason: 'the cycle returned rather than falling through to its tail',
      );
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

        final base = DateTime.now();
        await harness.tick(base);
        expect(harness.manager.encryptCalls, hasLength(1));
        expect(harness.sharing.fetched, hasLength(1));

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
      final deferredDue = dueOf(harness, two);

      await harness.tick(base);

      expect(
        harness.manager.encryptCalls,
        hasLength(3),
        reason: 'only the first due circle fits inside the budget',
      );
      expect(
        hexOf(harness.manager.encryptCalls.last.mlsGroupId),
        hexOf(one.circle.mlsGroupId),
      );
      expect(
        dueOf(harness, two),
        deferredDue,
        reason: 'deferring is not re-arming: the circle stays overdue',
      );
      expect(dueOf(harness, two)!.isAfter(DateTime.now()), isFalse);

      await harness.tick(base);

      expect(harness.manager.encryptCalls, hasLength(4));
      expect(
        hexOf(harness.manager.encryptCalls.last.mlsGroupId),
        hexOf(two.circle.mlsGroupId),
        reason: 'most-overdue-first, so a deferred circle is never starved',
      );
    });
  });
}
