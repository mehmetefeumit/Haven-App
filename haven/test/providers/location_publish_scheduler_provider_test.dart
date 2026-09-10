/// Tests for `LocationPublishSchedulerNotifier` — the foreground publish tick,
/// which arms ONE jittered cadence for the whole device and publishes every
/// eligible circle on each tick.
///
/// Verifies: one armed wake whatever the circle count, and one tick reaching
/// every eligible circle; the FIFO chain serializes concurrent bursts (Rule 14
/// single-writer); a wedged circle does not take its siblings down with it;
/// ineligible circles (orphaned / blocked) are never published; the disclosure
/// gate blocks publishing; add/remove on circle-set changes; stop/start across
/// the background handoff; and the fairness half of [kMaxCirclesPerBurst] — the
/// service-period ladder, the three lifecycle events that must NOT re-phase
/// the queue it rests on (a pause/resume, a failed roster read, and a join) —
/// `build()` is what rewinds it, and a rewind is the benign one, because it
/// re-serves the SAME head deterministically rather than shuffling turns — the
/// departure that must PRUNE it, and the tick that lands while the queue and
/// the roster disagree.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// Service period in BURSTS — how many bursts a circle waits between two of its
/// own publishes — for each roster size the ladder sweep drives.
///
/// A LITERAL table, not `ceil(n / kMaxCirclesPerBurst)` re-derived. The sibling
/// file says why for the per-gap ceiling ("re-deriving it here would make the
/// test agree with any pricing rule") and it applies verbatim: a re-derived
/// expectation moves WITH a changed cap, so the sweep values stop being rung
/// boundaries and every value below stays green at a cap of 10 or 12. The
/// rung→seconds join is carried only by these literals and by `and past the
/// cap, the deferral ladder in SECONDS`
/// (`test/services/publish_stagger_test.dart`), so a cap move must be a visible
/// edit here.
const _expectedServicePeriodBursts = <int, int>{
  11: 1,
  12: 2,
  13: 2,
  22: 2,
  23: 3,
  24: 3,
  33: 3,
  34: 4,
};

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final identity = Identity(
    pubkeyHex: _selfPubkey,
    npub: 'npub1self',
    createdAt: DateTime(2025),
  );

  /// Builds a container whose scheduler publishes through a
  /// [MockCircleService] (returns [circles] from getVisibleCircles and records
  /// encryptLocation calls). The jitter sampler is deterministic. Disclosure is
  /// accepted unless [disclosureAccepted] is false.
  ///
  /// The inter-publish decorrelation stagger is neutralised here
  /// ([PublishStagger.none]) because it is not the subject of this file: these
  /// tests are about WHICH circles a burst publishes, wedge recovery, and
  /// lifecycle, and a real 2-9 s hold before each publish would turn every one
  /// of them into a timing test of something else. The stagger a burst actually
  /// applies in production is asserted, with the production constants, by
  /// `location_publish_decorrelation_test.dart` and
  /// `test/lints/publish_decorrelation_wiring_test.dart`.
  ({ProviderContainer container, _FlakyCircleService mock}) build(
    List<Circle> circles, {
    bool disclosureAccepted = true,
    int sample = 120,
    LocationService? locationService,
    _SpyHealthNotifier? health,
    PublishStagger? stagger,
  }) {
    SharedPreferences.setMockInitialValues({
      if (disclosureAccepted) kLocationDisclosureAcceptedKey: true,
    });
    final mock = _FlakyCircleService(circles: circles);
    final sharing = LocationSharingService(
      circleService: mock,
      relayService: MockRelayService(),
    );
    final container = ProviderContainer(
      overrides: [
        if (health != null) sharingHealthProvider.overrideWith(() => health),
        identityServiceProvider.overrideWithValue(
          _MockIdentityService(identity: identity),
        ),
        locationServiceProvider.overrideWithValue(
          locationService ?? _FixedLocationService(),
        ),
        circleServiceProvider.overrideWithValue(mock),
        locationSharingServiceProvider.overrideWithValue(sharing),
        locationPublishJitterSamplerProvider.overrideWithValue((_) => sample),
        locationPublishStaggerProvider.overrideWithValue(
          stagger ?? PublishStagger.none(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mock: mock);
  }

  /// Reads the notifier and lets its `circlesProvider` listen resolve so the
  /// roster is populated and the tick is armed.
  Future<LocationPublishSchedulerNotifier> ready(
    ProviderContainer container,
  ) async {
    final notifier =
        container.read(locationPublishSchedulerProvider.notifier);
    // circlesProvider is async (reads getVisibleCircles); pump until the
    // listen callback has synced the schedulers.
    await container.read(circlesProvider.future);
    await pumpEventQueue();
    return notifier;
  }

  group('LocationPublishSchedulerNotifier', () {
    test('one scheduler publishes every eligible circle per tick', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);

      expect(
        notifier.eligibleKeysForTest,
        {_hex(const [10]), _hex(const [20])},
        reason: 'both circles are publish targets of the one burst',
      );
      expect(
        notifier.armedWakesForTest,
        1,
        reason: 'one wake for the device, not one per circle — the wake count '
            'is what coalescing buys',
      );

      await notifier.triggerTickForTest();

      expect(
        env.mock.encryptedMlsGroupIds,
        unorderedEquals(<List<int>>[const [1], const [2]]),
        reason: 'a single wake may only replace two if it reaches both '
            'circles; the ORDER is CSPRNG-permuted on purpose, so it is not '
            'asserted here',
      );
    });

    test('concurrent bursts are FIFO-serialized (Rule 14 single-writer)',
        () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      // The gaps stay collapsed here on purpose. This test holds every
      // encrypt open at its start, and the stagger is measured from the
      // previous publish's ACTUAL start — so a gated publish legitimately
      // consumes the gap, and asserting a separation under a gate would be
      // asserting how fast the machine ran. The burst BOUNDARY gap has its
      // own test below, ungated.
      final env = build([a, b]);
      final notifier = await ready(env.container);

      // Hold every encryptLocation open at its start.
      final gate = Completer<void>();
      env.mock.encryptGate = gate;

      // Two ticks — a burst plus the motion-driven one that can land on top of
      // it — enqueued without awaiting.
      unawaited(notifier.triggerTickForTest());
      final second = notifier.triggerTickForTest();
      await pumpEventQueue();

      // Only the FIRST publish of the FIRST burst has started; everything else
      // is queued behind it.
      expect(
        env.mock.encryptedMlsGroupIds.length,
        1,
        reason: 'the FIFO chain must not start a second encryptLocation while '
            'the first is in flight (no two concurrent session writers)',
      );

      gate.complete();
      await second;

      expect(
        env.mock.encryptedMlsGroupIds,
        unorderedEquals(<List<int>>[
          const [1],
          const [2],
          const [1],
          const [2],
        ]),
        reason: 'both bursts complete, each reaching BOTH circles, once the '
            'first publish releases — a count alone would pass a chain that '
            'published one circle four times and left the other silent, which '
            'is the failure a serialization bug actually produces; the ORDER '
            'is CSPRNG-permuted, so only the multiset is asserted',
      );
      expect(
        env.mock.encryptConcurrencyPeak,
        1,
        reason: 'serialized: two encrypts must never overlap, within a burst '
            'or across two of them',
      );
    });

    test('EVERY publish is spaced, the BURST BOUNDARY included', () async {
      // `sampleGaps` leaves index 0 unwaited because nothing inside ITS burst
      // precedes it — but `_lastChainPublishAt` is chain-GLOBAL. So the first
      // circle of burst N+1 is measured against the last publish of burst N,
      // and with index 0 taken as an unconditional zero those two circles are
      // dispatched one microtask apart: two different circles, one whole
      // second, two signed events. That is the equality join the whole chain
      // exists to prevent, and it is not exotic — `kPublishLinkTimeout` is
      // 180 s against a 72-168 s interval, so a tick is routinely already
      // queued when a slow burst ends.
      //
      // Ungated, unlike the FIFO test above: the gap is measured from the
      // previous publish's ACTUAL start, so an artificially held-open publish
      // consumes it legitimately. With instant publishes the wait is the only
      // thing spacing them, and a slow machine can only make the separations
      // larger.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      const gap = Duration(milliseconds: 400);
      // The chain measures its wait from `_lastChainPublishAt`, stamped just
      // BEFORE the publish call; the mock records the encrypt on ENTRY, a few
      // awaits later. So each separation carries the difference between two
      // such offsets, either sign, and the bound below is the gap less that
      // measurement slack — never a loosened property: the defect this covers
      // collapses the boundary to a handful of MILLISECONDS, four hundred
      // times inside the tolerance.
      const slack = Duration(milliseconds: 100);
      final env = build(
        [a, b],
        stagger: PublishStagger(rng: Random(31), minGap: gap, maxGap: gap),
      );
      final notifier = await ready(env.container);

      // Two ticks back to back — a burst plus the motion-driven one that can
      // land on top of it. The second queues behind the first, so its first
      // publish follows the first burst's last one immediately.
      unawaited(notifier.triggerTickForTest());
      await notifier.triggerTickForTest();

      expect(env.mock.encryptCallTimes, hasLength(4));
      final separations = <int>[
        for (var i = 1; i < env.mock.encryptCallTimes.length; i++)
          env.mock.encryptCallTimes[i]
              .difference(env.mock.encryptCallTimes[i - 1])
              .inMilliseconds,
      ];
      for (var i = 0; i < separations.length; i++) {
        expect(
          separations[i],
          greaterThanOrEqualTo((gap - slack).inMilliseconds),
          reason: i == 1
              ? 'separation ${i + 1} is the BURST BOUNDARY, and it measured '
                  '${separations[i]} ms — two circles of two different bursts '
                  'inside one whole-second created_at'
              : 'separation ${i + 1} fell inside the sampled gap: '
                  '$separations',
        );
      }
    });

    test('a HUNG publish window costs its burst and nothing after it',
        () async {
      // The FIFO chain's structural failure mode: a link that never
      // completes raises no error, so `catchError` cannot see it, every
      // later burst queues behind it, and only `build()` resets the chain.
      // One hung await therefore ends location sharing for the rest of the
      // process, silently. The route that made this reachable was a
      // backgrounded iOS permission prompt that iOS defers and geolocator
      // never resolves.
      //
      // A burst opens ONE window for every circle it publishes, so a wedged
      // fix costs the whole burst by construction — there is no sibling that
      // could have published, because there is no second fix. What must
      // still hold is that the CHAIN recovers: the wedged burst gives up at
      // its bound, and the next tick publishes normally.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final wedging = _WedgingLocationService();
      addTearDown(wedging.release);
      final spy = _SpyHealthNotifier();
      final env = build([a, b], locationService: wedging, health: spy);
      final notifier = await ready(env.container);
      notifier.publishLinkTimeoutForTest = const Duration(milliseconds: 50);

      await notifier.triggerTickForTest().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the burst never gave up on the wedged window — one hung fix kills '
          'location sharing for the whole process lifetime',
        ),
      );

      expect(
        env.mock.encryptedMlsGroupIds,
        isEmpty,
        reason: 'no fix was ever produced, so nothing may be published',
      );
      expect(
        spy.publishOutcomes.map((o) => o.key).toSet(),
        {_hex(const [10]), _hex(const [20])},
        reason: 'a window that never answered is every waiting circle\'s '
            'failed publish; without the attribution a dead GPS reads as '
            'healthy until the silence threshold expires',
      );
      expect(spy.publishOutcomes.every((o) => !o.acked), isTrue);

      // The chain moved on: the next tick's window succeeds and both circles
      // publish.
      await notifier.triggerTickForTest().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the chain stayed wedged behind the abandoned '
            'window'),
      );
      expect(
        env.mock.encryptedMlsGroupIds,
        unorderedEquals(<List<int>>[const [1], const [2]]),
        reason: 'the wedge must cost one burst, never the plane — and a count '
            'alone would pass a burst that published one circle twice while '
            'the other stayed silent',
      );
    });

    test('a legacy-orphaned circle is never in the burst', () async {
      final healthy = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      // Default factory circle: accepted + no members == legacy-orphaned.
      final orphan = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
      );
      final env = build([healthy, orphan]);
      final notifier = await ready(env.container);

      expect(notifier.eligibleKeysForTest, {_hex(const [10])});

      await notifier.triggerTickForTest();

      expect(
        env.mock.encryptedMlsGroupIds,
        [const [1]],
        reason: 'one tick now reaches every circle in the roster, so keeping '
            'an orphan OUT of the roster is what keeps it unpublished',
      );
    });

    test('a blocked (Unrecoverable) circle is never in the burst', () async {
      final healthy = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final blocked = TestCircleFactory.createCircle(
        mlsGroupId: const [3],
        nostrGroupId: const [30],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([healthy, blocked])
        ..mock.markCircleBlocked(const [3]);
      final notifier = await ready(env.container);

      expect(notifier.eligibleKeysForTest, {_hex(const [10])});

      await notifier.triggerTickForTest();

      expect(
        env.mock.encryptedMlsGroupIds,
        [const [1]],
        reason: 'a blocked circle must never be sent to, and a burst that '
            'publishes the whole roster is the one path that would',
      );
    });

    test('the disclosure gate blocks the burst', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a], disclosureAccepted: false);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest();

      expect(
        env.mock.encryptedMlsGroupIds,
        isEmpty,
        reason: 'no publish before the foreground disclosure is accepted',
      );
    });

    test('stopScheduling cancels the armed tick; startScheduling re-arms',
        () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final notifier = await ready(env.container);
      expect(notifier.eligibleKeysForTest, isNotEmpty);
      expect(notifier.armedWakesForTest, 1);

      notifier.stopScheduling();
      expect(notifier.isActiveForTest, isFalse);
      expect(
        notifier.eligibleKeysForTest,
        isEmpty,
        reason: 'paused (backgrounded): nothing left to publish to',
      );
      expect(
        notifier.armedWakesForTest,
        0,
        reason: 'and no live foreground timer',
      );

      notifier.startScheduling();
      await pumpEventQueue();
      expect(notifier.isActiveForTest, isTrue);
      expect(
        notifier.eligibleKeysForTest,
        {_hex(const [10])},
        reason: 'resumed: the roster is rebuilt from the current circles',
      );
      expect(notifier.armedWakesForTest, 1, reason: 'and the tick is re-armed');
    });

    test('a circle blocked MID-burst is not published by it', () async {
      // A burst spans tens of seconds now, so the window between "this circle
      // was eligible when the tick fired" and "this circle is being encrypted"
      // is long enough for the engine to flag it Unrecoverable — and sending to
      // a blocked circle is the one thing `CircleService` says must never
      // happen.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);

      // Hold the burst inside its first publish.
      final gate = Completer<void>();
      env.mock.encryptGate = gate;
      final burst = notifier.triggerTickForTest();
      await pumpEventQueue();
      final firstOut = env.mock.encryptedMlsGroupIds.single;

      // The engine flags whichever circle has NOT gone out yet.
      final blocked = firstOut.first == 1 ? const [2] : const [1];
      env.mock.markCircleBlocked(blocked);
      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();

      gate.complete();
      await burst;

      expect(
        env.mock.encryptedMlsGroupIds,
        [firstOut],
        reason: 'the burst must re-read eligibility before each publish, not '
            'trust the roster it captured when the tick fired',
      );
    });

    test('which circle leads the burst varies across ticks', () async {
      // A stable "who goes first" would put the same circle's `created_at`
      // permanently ahead of its siblings' — a second-order fingerprint of the
      // same burst, which is why the burst order is a CSPRNG permutation. The
      // gaps are collapsed to milliseconds here: the subject is the ORDER.
      final firsts = <String>{};
      for (var attempt = 0; attempt < 25; attempt++) {
        final env = build(
          [
            for (final id in const [1, 2, 3])
              TestCircleFactory.createCircle(
                mlsGroupId: [id],
                nostrGroupId: [id * 10],
                members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
              ),
          ],
          stagger: PublishStagger(
            rng: Random(attempt),
            minGap: const Duration(milliseconds: 2),
            maxGap: const Duration(milliseconds: 4),
            maxSpread: const Duration(milliseconds: 20),
          ),
        );
        final notifier = await ready(env.container);
        await notifier.triggerTickForTest();
        firsts.add(_hex(env.mock.encryptedMlsGroupIds.first));
      }

      expect(
        firsts.length,
        greaterThan(1),
        reason: 'a fixed "circle 1 always goes first" makes the un-delayed '
            'circle a stable marker of the burst',
      );
    });

    test('an empty roster arms no timer at all — including the roster that '
        'BECOMES empty', () async {
      // A wake that can only discover it has nothing to publish is pure drain.
      final env = build(<Circle>[]);
      final notifier = await ready(env.container);

      expect(notifier.eligibleKeysForTest, isEmpty);
      expect(notifier.armedWakesForTest, 0);

      // The TRANSITION is the direction a roster that starts empty cannot
      // cover, and it is the one a real user reaches: leaving their last
      // circle. Without the disarm the device keeps waking every ~2 minutes
      // for the rest of the process to find nothing to publish.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final live = build([a]);
      final armed = await ready(live.container);
      expect(armed.armedWakesForTest, 1);

      // The engine flags the only circle Unrecoverable — the roster's last
      // publishable member is gone, which is the same transition as leaving
      // it.
      live.mock.markCircleBlocked(const [1]);
      live.container.invalidate(circlesProvider);
      await live.container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(armed.eligibleKeysForTest, isEmpty);
      expect(
        armed.armedWakesForTest,
        0,
        reason: 'the user left their last circle; a timer that survives that '
            'wakes the radio forever for nothing',
      );
    });

    test('a roster past kMaxCirclesPerBurst rotates: every circle publishes, '
        'and none is deferred twice in a row', () async {
      // The cap keeps a burst inside its spread budget; the ROTATION is what
      // keeps that from stranding a circle. Selection is deterministic and
      // least-recently-served-first on purpose — the CSPRNG decides the order
      // WITHIN a burst, never who gets left out, because a random choice
      // repeated is a circle that goes silent for several intervals.
      const roster = kMaxCirclesPerBurst + 2;
      final env = build([
        for (var i = 1; i <= roster; i++)
          TestCircleFactory.createCircle(
            mlsGroupId: [i],
            nostrGroupId: [i],
            members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
          ),
      ]);
      final notifier = await ready(env.container);

      expect(
        notifier.rotationForTest, hasLength(roster),
        reason: 'every eligible circle is in the queue, capped or not',
      );

      final served = <String, int>{};
      for (var burst = 0; burst < roster; burst++) {
        final before = env.mock.encryptedMlsGroupIds.length;
        await notifier.triggerTickForTest();
        final thisBurst = env.mock.encryptedMlsGroupIds
            .skip(before)
            .map(_hex)
            .toList();
        expect(
          thisBurst,
          hasLength(kMaxCirclesPerBurst),
          reason: 'a burst must spend its whole budget and no more: burst '
              '$burst published ${thisBurst.length}',
        );
        for (final key in thisBurst) {
          served[key] = (served[key] ?? 0) + 1;
        }
      }

      expect(
        served.keys, hasLength(roster),
        reason: 'a circle the rotation never reaches is a circle that stopped '
            'sharing, silently',
      );
      // Over `roster` bursts of `kMaxCirclesPerBurst` each, a fair rotation
      // gives every circle the same count within one. A CSPRNG selection
      // would not: it strands circles for runs at a time.
      final counts = served.values.toList()..sort();
      expect(
        counts.last - counts.first,
        lessThanOrEqualTo(1),
        reason: 'the rotation must be fair to within one burst; counts were '
            '$counts',
      );
    });

    test('a deferred circle waits ceil(N / kMaxCirclesPerBurst) bursts — the '
        'service-period ladder, not "two intervals" at every roster', () async {
      // The fairness test above proves no circle is STRANDED. This pins how
      // long one waits, which is the figure the retention record is sized
      // against: `_takeBurstSlice` is strict round-robin, so a circle is served
      // once every `ceil(N / kMaxCirclesPerBurst)` bursts, and the ladder
      // 12…22 → 2, 23…33 → 3, ≥ 34 → 4 that `kMaxCirclesPerBurst`'s doc and
      // INV-W-445-EXPIRATION-WINDOW's residual state in seconds is that
      // quotient read off THIS rotation. Both sides of every rung, because a
      // rung boundary is where a change to the slice size shows: at 22 circles
      // the period is still two bursts and at 23 it is three.
      //
      // One scope limit this measures inside and cannot see: the iOS background
      // coordinator can fold a second tick into a running burst (`_joinable`),
      // which publishes more than `kMaxCirclesPerBurst` in one pass. The two
      // that used to sit beside it — a pause/resume and a failed roster read
      // re-phasing the queue — are no longer limits but properties, and they
      // and the survivor merge they rest on are the three tests below.
      //
      // The sweep values are rung boundaries of the CURRENT cap, so they are
      // pinned against it: moving the cap must fail here rather than quietly
      // re-label interior points as boundaries.
      expect(
        _expectedServicePeriodBursts.keys,
        containsAll(<int>[
          for (var rung = 1; rung <= 3; rung++) ...<int>[
            rung * kMaxCirclesPerBurst,
            rung * kMaxCirclesPerBurst + 1,
          ],
        ]),
        reason: 'the table must cover both sides of every rung the cap '
            'produces, because a rung boundary is the only place a slice-size '
            'change shows: at 22 circles the period is still two bursts and at '
            '23 it is three',
      );
      for (final n in _expectedServicePeriodBursts.keys) {
        final env = build([
          for (var i = 1; i <= n; i++)
            TestCircleFactory.createCircle(
              mlsGroupId: [i],
              nostrGroupId: [i],
              members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
            ),
        ]);
        final notifier = await ready(env.container);
        final period = _expectedServicePeriodBursts[n]!;

        // Three periods plus one burst: enough that every circle's wait is
        // observed BETWEEN two of its own publishes rather than truncated by
        // the end of the sweep, which would read as a shorter period.
        final servedAt = <String, List<int>>{};
        for (var burst = 0; burst < 3 * period + 1; burst++) {
          final before = env.mock.encryptedMlsGroupIds.length;
          await notifier.triggerTickForTest();
          for (final id in env.mock.encryptedMlsGroupIds.skip(before)) {
            (servedAt[_hex(id)] ??= <int>[]).add(burst);
          }
        }
        expect(
          servedAt, hasLength(n),
          reason: 'a circle the sweep never reached cannot have a period at '
              'all, which would make the maximum below vacuous',
        );

        var worst = 0;
        for (final at in servedAt.values) {
          for (var i = 1; i < at.length; i++) {
            worst = max(worst, at[i] - at[i - 1]);
          }
        }
        expect(
          worst,
          period,
          reason: 'at $n circles a circle waits $worst bursts between '
              'publishes, not the $period this ladder is recorded as; the '
              'ladder quoted in seconds on kMaxCirclesPerBurst is that number '
              'times the cadence bounds, so a slice-size change invalidates '
              'that prose here',
        );
      }
    });

    test('a deferred circle is not deferred again by every resume', () async {
      // The ladder above is a PERIOD only if the queue outlives the app
      // lifecycle. Three of `MapShell`'s four pause branches call
      // `stopScheduling()`, and a resume that rebuilt the queue would rebuild
      // it from `getVisibleCircles()` order (`updated_at DESC`) — the same
      // head, so the same first slice, so the same tail deferred every time.
      // A phone that backgrounds between ticks is the ordinary case, and the
      // circles past the first slice would then go silent for the session
      // while every log line still showed a healthy burst per interval.
      const roster = kMaxCirclesPerBurst + 2;
      final env = build([
        for (var i = 1; i <= roster; i++)
          TestCircleFactory.createCircle(
            mlsGroupId: [i],
            nostrGroupId: [i],
            members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
          ),
      ]);
      final notifier = await ready(env.container);

      final served = <String>{};
      for (var session = 0; session < 3; session++) {
        final before = env.mock.encryptedMlsGroupIds.length;
        await notifier.triggerTickForTest();
        served.addAll(env.mock.encryptedMlsGroupIds.skip(before).map(_hex));
        notifier
          ..stopScheduling()
          ..startScheduling();
        await pumpEventQueue();
      }

      expect(
        served,
        hasLength(roster),
        reason: 'three bursts across three foreground sessions must between '
            'them reach all $roster circles; this run served ${served.length}, '
            'which is a queue that rewound to the same head on every resume',
      );
    });

    test('a transient empty roster emission does not re-phase whose turn it is',
        () async {
      // `circlesProvider` answers ANY `getVisibleCircles` failure with an EMPTY
      // list — deliberate graceful degradation, reachable from all sixteen of
      // its invalidation sites — so a transient keyring or FFI error reaches
      // this notifier as "nothing is eligible" followed by the unchanged roster
      // coming back. That is an error branch, not a roster change: if it
      // reconciled the queue, the healthy emission would rebuild it from
      // `updated_at DESC` and the deferred tail would be deferred again, inside
      // one continuous run, with nothing in the logs to show it.
      const roster = kMaxCirclesPerBurst + 2;
      final env = build([
        for (var i = 1; i <= roster; i++)
          TestCircleFactory.createCircle(
            mlsGroupId: [i],
            nostrGroupId: [i],
            members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
          ),
      ]);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest();
      final first = env.mock.encryptedMlsGroupIds.map(_hex).toSet();
      expect(first, hasLength(kMaxCirclesPerBurst));

      env.mock.failNextRead = true;
      env.container.invalidate(circlesProvider);
      expect(
        await env.container.read(circlesProvider.future),
        isEmpty,
        reason: 'anti-vacuity: the failed read must actually reach the '
            'notifier as an empty emission, which is what circlesProvider '
            'degrades a failure to',
      );
      await pumpEventQueue();
      expect(
        notifier.eligibleKeysForTest,
        isEmpty,
        reason: 'and the roster must genuinely empty — a circle cannot be sent '
            'to while the app cannot even read whether it still exists',
      );

      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();

      final before = env.mock.encryptedMlsGroupIds.length;
      await notifier.triggerTickForTest();
      final second = env.mock.encryptedMlsGroupIds
          .skip(before)
          .map(_hex)
          .toSet();

      expect(
        second,
        isNot(first),
        reason: 'the burst after a failed roster read served the same slice '
            'again — that is the REWIND shape, and only build() may do '
            'it, so a failed read must not be enough to reset whose turn '
            'it is',
      );
      expect(
        second,
        containsAll(
          {for (var i = 1; i <= roster; i++) _hex([i])}.difference(first),
        ),
        reason: 'and precisely: whatever the first burst deferred must LEAD '
            'the next one, exactly as it would have without the failure',
      );
    });

    test("a roster change keeps survivors' places in the queue", () async {
      // The ladder rests on the reconciliation being a MERGE: survivors hold
      // their slot and a newcomer joins at the BACK. A rebuild from the roster
      // order is indistinguishable at or below the cap and starves the tail
      // above it — the join would send the circles this burst just deferred to
      // the back of the queue behind a circle that has waited for nothing.
      const roster = kMaxCirclesPerBurst + 2;
      // Held by the test, because `MockCircleService` hands `getVisibleCircles`
      // the very list it was built with: appending to it IS the roster change a
      // real join makes, without a second container that would lose the queue.
      final circles = <Circle>[
        for (var i = 1; i <= roster; i++)
          TestCircleFactory.createCircle(
            mlsGroupId: [i],
            nostrGroupId: [i],
            members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
          ),
      ];
      final env = build(circles);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest();
      final firstBurst = env.mock.encryptedMlsGroupIds.map(_hex).toSet();
      final deferred = {
        for (var i = 1; i <= roster; i++) _hex([i]),
      }.difference(firstBurst);
      expect(deferred, hasLength(roster - kMaxCirclesPerBurst));

      const joiner = roster + 1;
      circles.add(
        TestCircleFactory.createCircle(
          mlsGroupId: const [joiner],
          nostrGroupId: const [joiner],
          members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
        ),
      );
      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();
      expect(notifier.eligibleKeysForTest, hasLength(roster + 1));

      final before = env.mock.encryptedMlsGroupIds.length;
      await notifier.triggerTickForTest();
      final secondBurst = env.mock.encryptedMlsGroupIds
          .skip(before)
          .map(_hex)
          .toSet();

      expect(
        secondBurst,
        containsAll(deferred),
        reason: 'the circles the first burst deferred must still lead the '
            'second one; a join that reshuffles the queue makes every join a '
            'fresh start for the tail',
      );
      expect(
        secondBurst,
        isNot(contains(_hex(const [joiner]))),
        reason: 'and the newcomer waits its turn at the back rather than '
            'overtaking $deferred, which have already waited a burst',
      );
    });

    test('a departed circle loses its place in the queue', () async {
      // The other direction of the same merge, and the one with teeth. The tick
      // reads the roster through the keys the queue hands it, so a key left
      // standing for a circle that is gone is a burst slot spent on nothing
      // every time its turn comes round — and nothing but a later emission can
      // ever take it out again.
      final circles = <Circle>[
        for (final i in const [1, 2, 3])
          TestCircleFactory.createCircle(
            mlsGroupId: [i],
            nostrGroupId: [i * 10],
            members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
          ),
      ];
      final env = build(circles);
      final notifier = await ready(env.container);
      expect(notifier.rotationForTest, hasLength(3));

      // The engine flags one of the three Unrecoverable — the same shape the
      // roster sees for a leave, a removal or a pre-cutover orphan.
      env.mock.markCircleBlocked(const [2]);
      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(
        notifier.rotationForTest,
        unorderedEquals(<String>[_hex(const [10]), _hex(const [30])]),
        reason: 'the queue must hold exactly the live roster; a departed key '
            'left in it is a slot no burst can ever fill',
      );

      await notifier.triggerTickForTest();
      expect(
        env.mock.encryptedMlsGroupIds,
        unorderedEquals(<List<int>>[const [1], const [3]]),
        reason: 'and the survivors must still publish. A burst that trips over '
            'the departed key publishes nothing at all, and not just once: '
            '`JitteredScheduler._fire` swallows what the tick throws and '
            're-arms, so the whole session goes silent with no failed publish '
            'recorded and the sharing banner healthy',
      );

      // The permanence is the point, and one burst cannot see it.
      final before = env.mock.encryptedMlsGroupIds.length;
      await notifier.triggerTickForTest();
      expect(
        env.mock.encryptedMlsGroupIds.skip(before),
        unorderedEquals(<List<int>>[const [1], const [3]]),
        reason: 'the tick after it too — the outage this covers lasts the rest '
            'of the foreground session',
      );
    });

    test('a tick with nothing publishable opens no window and cannot wedge the '
        'plane', () async {
      // Between a failed roster read and the next healthy emission the queue
      // and the roster disagree by design (the queue outlives the emptied
      // roster). A tick landing in that gap has to survive it twice over: it
      // must not dereference the missing circle — a throw is swallowed and
      // re-armed, so it costs every later tick too, not just this one — and it
      // must not open a publish window for zero circles, which is an identity
      // read, a preference read and a fix with a 30 s budget spent on nobody.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final gps = _FixedLocationService();
      final env = build([a, b], locationService: gps);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest();
      expect(
        env.mock.encryptedMlsGroupIds,
        unorderedEquals(<List<int>>[const [1], const [2]]),
      );
      expect(gps.fixes, 1, reason: 'one window for the burst, not one each');

      env.mock.failNextRead = true;
      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();
      expect(
        notifier.eligibleKeysForTest,
        isEmpty,
        reason: 'anti-vacuity: the roster must really be empty here',
      );
      expect(
        notifier.rotationForTest,
        hasLength(2),
        reason: 'and the queue must really still hold both keys — that '
            'disagreement IS the state under test',
      );

      await notifier.triggerTickForTest();

      expect(
        env.mock.encryptedMlsGroupIds,
        unorderedEquals(<List<int>>[const [1], const [2]]),
        reason: 'nothing new: a circle cannot be sent to while the app cannot '
            'even read whether it still exists',
      );
      expect(
        gps.fixes,
        1,
        reason: 'and no window may open for zero circles: the identity read, '
            'the preference read and a 30 s GPS budget spent on nobody',
      );

      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();
      final before = env.mock.encryptedMlsGroupIds.length;
      await notifier.triggerTickForTest();
      expect(
        env.mock.encryptedMlsGroupIds.skip(before),
        unorderedEquals(<List<int>>[const [1], const [2]]),
        reason: 'and the plane is intact: the healthy emission publishes both '
            'circles again',
      );
    });

    test('an unrelated roster change reuses the armed tick rather than '
        'replacing it', () async {
      // `armedWakesForTest` counts a FIELD, so it reads 1 whether the
      // scheduler was reused or replaced — and a replacement leaves the old
      // timer running, uncancelled, firing on its own phase. `_syncCircles`
      // runs on every `circlesProvider` emission, so that would make the wake
      // count grow with roster churn: the exact opposite of the claim one
      // burst per interval is making. It would also re-phase the cadence on
      // every emission, which is the second promise here.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);
      final armed = notifier.armedSchedulerForTest;
      expect(armed, isNotNull);
      final phase = armed!.lastScheduledDelay;
      expect(notifier.eligibleKeysForTest, hasLength(2));

      // One of the two stops being publishable: a roster change entirely
      // unrelated to the cadence, and one that leaves the roster non-empty.
      env.mock.markCircleBlocked(const [2]);
      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(notifier.eligibleKeysForTest, hasLength(1));
      expect(
        identical(notifier.armedSchedulerForTest, armed),
        isTrue,
        reason: 'a new scheduler per emission abandons the old timer '
            'uncancelled — the wake count then grows with roster churn',
      );
      expect(
        notifier.armedSchedulerForTest!.lastScheduledDelay,
        phase,
        reason: 'and a chatty circle list would pull the burst cadence in',
      );
    });

    test('a SLOW first fix cannot subtract itself from the next circle\'s '
        'gap — the burst takes ONE fix', () async {
      // The gap is measured from the previous publish's WINDOW START, but the
      // `created_at` is stamped AFTER the window. With a window per circle
      // the observable separation is
      // `max(gap, w_i + p_i) + w_i+1 − w_i`, so once a slow acquisition
      // outlasts the gap the gap DROPS OUT: a 2.5 s first fix followed by a
      // cache-warm second one puts both encrypts inside the same
      // whole-second stamp. One window for the whole burst makes `w ≡ 0` and
      // the separation `max(gap, p_i)` structurally.
      //
      // No existing test can see this: their location doubles answer
      // instantly for every circle, which is the one case where the two
      // shapes agree.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      const gap = Duration(seconds: 2);
      final env = build(
        [a, b],
        locationService: _SlowFirstFixLocationService(
          // Longer than the gap: that is the whole precondition for the gap
          // to cancel out.
          firstFixDelay: const Duration(milliseconds: 2500),
        ),
        stagger: PublishStagger(rng: Random(77), minGap: gap, maxGap: gap),
      );
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest();

      expect(env.mock.encryptCallTimes, hasLength(2));
      expect(
        env.mock.encryptCallTimes[1]
            .difference(env.mock.encryptCallTimes[0])
            .inMilliseconds,
        greaterThan(1000),
        reason: 'the kind-445 created_at is a whole-second u64, so two '
            'encrypts this close carry one identical stamp inside two signed '
            'events',
      );
    });

    test('a DEFERRED send routes to the health model as a deferral, never as '
        'a publish verdict', () async {
      // The engine queued the update instead of encrypting it. Nothing reached
      // a relay, so there is no publish verdict to report — recording one
      // would either claim a delivery that never happened or blame a relay
      // that was never asked. It must reach `recordDeferredSend` instead, so
      // the banner can name the real cause.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final spy = _SpyHealthNotifier();
      final env = build([a], health: spy);
      final notifier = await ready(env.container);
      env.mock.deferNextEncrypt = const LocationSendDeferred(
        unresolvedInputs: 2,
        discardedIntents: 1,
        repaired: false,
        commits: [],
        proposals: [],
      );

      await notifier.triggerTickForTest();

      expect(
        spy.deferredKeys,
        [_hex(const [10])],
        reason: 'the deferral must be recorded against the circle it happened '
            'to, keyed the same way every other health input is',
      );
      expect(
        spy.publishOutcomes,
        isEmpty,
        reason: 'a deferral is not a publish verdict — recording one would '
            'mis-attribute the outage to the relay plane',
      );
    });

    test('a SENT publish still routes to the publish verdict', () async {
      // Anti-vacuity for the test above: the same harness, without a deferral,
      // must take the ordinary path.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final spy = _SpyHealthNotifier();
      final env = build([a], health: spy);
      final notifier = await ready(env.container);

      await notifier.triggerTickForTest();

      expect(spy.deferredKeys, isEmpty);
      expect(spy.publishOutcomes.single.key, _hex(const [10]));
      expect(spy.publishOutcomes.single.acked, isTrue);
    });
  });

  group('the background burst tick sink', () {
    // While backgrounded on iOS a tick must not publish where it stands: it
    // has to open the engine's burst first, so a peer commit that arrived
    // while the process was paused is applied BEFORE the location is
    // encrypted. The scheduler stays the tick source and hands the work over.

    test('a tick hands the whole roster to the sink instead of publishing '
        'directly', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final sink = _RecordingSink();
      final notifier = await ready(env.container)..setTickSink(sink);

      await notifier.triggerTickForTest();

      expect(
        sink.ticks,
        unorderedEquals(<String>[_hex(const [10]), _hex(const [20])]),
        reason: 'every circle is handed over before the first await, so the '
            'coordinator carries them all in ONE burst instead of opening a '
            'socket per circle — the iOS-background half of the wake claim',
      );
      expect(
        env.mock.encryptedMlsGroupIds,
        isEmpty,
        reason: 'publishing before the burst opened would encrypt at a stale '
            'epoch and skip the backlog the burst exists to ingest',
      );
    });

    test('the sink is handed the scheduler own key for each circle', () async {
      // Re-deriving the key on the far side is how a sink and a scheduler
      // drift apart; the burst keys its due set with exactly this string.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10, 11],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final sink = _RecordingSink();
      final notifier = await ready(env.container)..setTickSink(sink);

      await notifier.triggerTickForTest();

      expect(sink.ticks, [_hex(const [10, 11])]);
      expect(sink.circles.single.nostrGroupId, const [10, 11]);
    });

    test('clearing the sink restores the direct publish', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final sink = _RecordingSink();
      final notifier = await ready(env.container)..setTickSink(sink);

      await notifier.triggerTickForTest();
      notifier.setTickSink(null);
      await notifier.triggerTickForTest();

      expect(sink.ticks, hasLength(1));
      expect(env.mock.encryptedMlsGroupIds, [const [1]]);
    });

    test('the tick watchdog reports a slow burst but never cancels it',
        () async {
      // `Future.timeout` does not cancel the future it wraps. If this chain
      // treated the bound as a cancellation, a burst that ran long would be
      // abandoned with the engine still live and its sockets still open — for
      // the whole gap to the next tick, on the one platform where nothing else
      // will notice. The bound may only let the CHAIN move on.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final gate = Completer<void>();
      final sink = _RecordingSink(gate: gate.future);
      final notifier = await ready(env.container)
        ..setTickSink(sink)
        ..publishLinkTimeoutForTest = const Duration(milliseconds: 20);

      unawaited(notifier.triggerTickForTest());
      final second = notifier.triggerTickForTest();

      await second.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the watchdog never released the chain'),
      );
      expect(
        sink.completed,
        isEmpty,
        reason: 'anti-vacuity: the first burst is still running, so the chain '
            'moved on because of the watchdog and nothing else',
      );

      // The abandoned burst runs on and finishes its own teardown.
      gate.complete();
      await sink.settled;
      expect(
        sink.completed,
        unorderedEquals(<String>[
          _hex(const [10]),
          _hex(const [20]),
          _hex(const [10]),
          _hex(const [20]),
        ]),
        reason: 'two ticks over two circles: every handover still completes '
            'on its own after the chain moved on — a count alone would pass a '
            'chain that handed one circle over four times and left the other '
            'silent',
      );
    });

    test('the eligible roster answers a burst asking about one circle',
        () async {
      // A burst queues a circle at tick time and publishes up to a minute
      // later, so it re-reads eligibility at fire time — and this roster is
      // where the same `filterPublishEligibleCircles` check the foreground
      // makes already lives.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final notifier = await ready(env.container);

      expect(
        notifier.eligibleCircle(_hex(const [10]))?.nostrGroupId,
        const [10],
      );
      expect(
        notifier.eligibleCircle(_hex(const [99])),
        isNull,
        reason: 'a key this scheduler never tracked is not a publish target',
      );
    });

    test('a circle blocked after its tick stops being an eligible target',
        () async {
      // The engine flags a circle Unrecoverable while it sits in a burst's due
      // set. Sending to it is the one thing `CircleService` says must never
      // happen, and nothing else would ever take it out of that set.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final notifier = await ready(env.container);
      expect(notifier.eligibleCircle(_hex(const [10])), isNotNull);

      env.mock.markCircleBlocked(const [1]);
      env.container.invalidate(circlesProvider);
      await env.container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(notifier.eligibleCircle(_hex(const [10])), isNull);
    });

    test('nothing is eligible once the scheduler has stopped', () async {
      // `stopScheduling` is how the foreground takes publishing back (and how
      // an opt-out ends it). A burst still draining its due set must publish
      // nothing after that hand-over — two writers is exactly what Rule 14
      // forbids.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a]);
      final notifier = await ready(env.container)..stopScheduling();

      expect(notifier.eligibleCircle(_hex(const [10])), isNull);
    });

    test('a burst publish shares one window across every circle it publishes',
        () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a, b]);
      final notifier = await ready(env.container);

      final fix = await notifier.openBurstPublishWindow([a, b]);
      expect(fix, isNotNull);
      await notifier.publishInBurst(a, fix!);
      await notifier.publishInBurst(b, fix);

      expect(env.mock.encryptedMlsGroupIds, [const [1], const [2]]);
    });

    test('the disclosure gate refuses a burst window too', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final env = build([a], disclosureAccepted: false);
      final notifier = await ready(env.container);

      expect(await notifier.openBurstPublishWindow([a]), isNull);
      expect(env.mock.encryptedMlsGroupIds, isEmpty);
    });

    test('a window that fails is recorded against every circle waiting on it',
        () async {
      // One fix serves the whole burst, so one dead GPS is every due circle's
      // failed publish. Without the attribution the health model would only
      // learn about it from silence, up to two publish intervals later.
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final b = TestCircleFactory.createCircle(
        mlsGroupId: const [2],
        nostrGroupId: const [20],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final spy = _SpyHealthNotifier();
      final env = build([a, b], health: spy, locationService: _DeadGps());
      final notifier = await ready(env.container);

      expect(await notifier.openBurstPublishWindow([a, b]), isNull);

      expect(
        spy.publishOutcomes.map((o) => o.key),
        [_hex(const [10]), _hex(const [20])],
      );
      expect(spy.publishOutcomes.every((o) => !o.acked), isTrue);
    });

    test('a burst publish that defers still routes to the health model as a '
        'deferral', () async {
      final a = TestCircleFactory.createCircle(
        mlsGroupId: const [1],
        nostrGroupId: const [10],
        members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
      );
      final spy = _SpyHealthNotifier();
      final env = build([a], health: spy);
      final notifier = await ready(env.container);
      env.mock.deferNextEncrypt = const LocationSendDeferred(
        unresolvedInputs: 2,
        discardedIntents: 1,
        repaired: false,
        commits: [],
        proposals: [],
      );

      final fix = await notifier.openBurstPublishWindow([a]);
      await notifier.publishInBurst(a, fix!);

      expect(spy.deferredKeys, [_hex(const [10])]);
      expect(spy.publishOutcomes, isEmpty);
    });
  });
}

/// A [MockCircleService] whose NEXT roster read fails, once.
///
/// `circlesProvider` answers any `getVisibleCircles` failure with an EMPTY list
/// — documented graceful degradation — so what a transient keyring or FFI error
/// actually delivers to a listener is one empty emission followed by a healthy
/// one. [MockCircleService.shouldThrowOnGetCircles] cannot express that: it is
/// final and fails for the container's whole life.
class _FlakyCircleService extends MockCircleService {
  _FlakyCircleService({required List<Circle> circles})
      : super(circles: circles);

  /// Set to make exactly the next [getVisibleCircles] throw. Self-clearing, so
  /// the read after it is healthy.
  bool failNextRead = false;

  @override
  Future<List<Circle>> getVisibleCircles() async {
    if (failNextRead) {
      failNextRead = false;
      throw const CircleServiceException('transient roster read failure');
    }
    return super.getVisibleCircles();
  }
}

/// A [BurstSink] that records the ticks handed to it and can hold them open.
class _RecordingSink implements BurstSink {
  _RecordingSink({this.gate});

  /// Held to keep a burst running past the chain's watchdog.
  final Future<void>? gate;

  final List<String> ticks = [];
  final List<Circle> circles = [];
  final List<String> completed = [];
  final List<Future<void>> _inFlight = [];

  /// Completes once every tick handed over so far has finished.
  Future<void> get settled => Future.wait(_inFlight);

  @override
  Future<void>? get runningBurst =>
      _inFlight.length == completed.length ? null : settled;

  @override
  Future<void> onTick({required String circleKey, required Circle circle}) {
    ticks.add(circleKey);
    circles.add(circle);
    final work = () async {
      if (gate != null) await gate;
      completed.add(circleKey);
    }();
    _inFlight.add(work);
    return work;
  }
}

/// A location service whose fix always fails — a permission revoked mid-window
/// or a provider that is off.
class _DeadGps extends _FixedLocationService {
  @override
  Future<Position> getCurrentLocation() async =>
      throw StateError('no location provider');
}

// ---------------------------------------------------------------------------
// Local mocks
// ---------------------------------------------------------------------------

class _MockIdentityService implements IdentityService {
  _MockIdentityService({required this.identity});
  final Identity? identity;

  @override
  Future<Identity?> getIdentity() async => identity;
  @override
  Future<bool> hasIdentity() async => identity != null;
  @override
  Future<Identity> createIdentity() async => throw UnimplementedError();
  @override
  Future<Identity> importFromNsec(String nsec) async =>
      throw UnimplementedError();
  @override
  Future<void> deleteIdentity() async {}
  @override
  Future<String> exportNsec() async => throw UnimplementedError();
  @override
  Future<String> sign(Uint8List messageHash) async =>
      throw UnimplementedError();
  @override
  Future<String> getPubkeyHex() async =>
      identity?.pubkeyHex ?? (throw UnimplementedError());
  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();
  @override
  Future<String?> getDisplayName() async => null;
  @override
  Future<void> setDisplayName(String? name) async {}
  @override
  Future<void> clearCache() async {}
}

/// Serves the FIRST `getCurrentLocation()` slowly and every later one
/// instantly — a cold acquisition followed by cache-warm reads, which is the
/// ordinary shape when a fix lands DURING the first circle's acquisition.
class _SlowFirstFixLocationService extends _FixedLocationService {
  _SlowFirstFixLocationService({required this.firstFixDelay});

  final Duration firstFixDelay;
  bool _served = false;

  @override
  Future<Position> getCurrentLocation() async {
    if (!_served) {
      _served = true;
      await Future<void>.delayed(firstFixDelay);
    }
    return super.getCurrentLocation();
  }
}

/// Hangs the FIRST `getCurrentLocation()` forever and serves every later one
/// normally — the shape of a backgrounded iOS permission prompt that the OS
/// defers and geolocator never resolves.
class _WedgingLocationService extends _FixedLocationService {
  final Completer<Position> _wedge = Completer<Position>();
  bool _wedged = false;

  /// Frees the abandoned link at teardown so the test isolate does not exit
  /// with a future nobody will ever complete.
  void release() {
    if (!_wedge.isCompleted) _wedge.completeError(StateError('test teardown'));
  }

  @override
  Future<Position> getCurrentLocation() {
    if (_wedged) return super.getCurrentLocation();
    _wedged = true;
    return _wedge.future;
  }
}

class _FixedLocationService implements LocationService {
  /// How many fixes have been asked of it. A burst opens ONE window whatever
  /// its size, and a tick with nothing publishable must open none.
  int fixes = 0;

  @override
  Future<Position> getCurrentLocation() async {
    fixes++;
    return Position(
      latitude: 37,
      longitude: -122,
      timestamp: DateTime.now(),
    );
  }
  @override
  Future<Position> getCurrentLocationFresh() async => getCurrentLocation();
  @override
  Stream<Position> getLocationStream() async* {
    yield await getCurrentLocation();
  }
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.always;
}

/// Records which sharing-health input each publish outcome routed to.
///
/// Subclasses the real notifier rather than faking it, so the override keeps
/// every other behaviour (and would fail to compile if the recording API it
/// pins were renamed).
class _SpyHealthNotifier extends SharingHealthNotifier {
  final List<String> deferredKeys = [];
  final List<({String key, bool acked})> publishOutcomes = [];

  @override
  void recordDeferredSend(String circleKey) {
    deferredKeys.add(circleKey);
    super.recordDeferredSend(circleKey);
  }

  @override
  void recordPublishOutcome(String circleKey, {required bool acked}) {
    publishOutcomes.add((key: circleKey, acked: acked));
    super.recordPublishOutcome(circleKey, acked: acked);
  }
}
