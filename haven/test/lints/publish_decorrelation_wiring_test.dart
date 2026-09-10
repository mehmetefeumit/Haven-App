// The cross-circle `created_at` decorrelation, on both publish planes.
//
// ## What one burst per tick does and does not promise
//
// A tick publishes EVERY eligible circle, so the device wakes its radio ~30
// times an hour whatever its circle count. Per-circle schedules are gone: they
// never stopped a shared relay from linking a device's circles (the multiplexed
// `#h` subscription already names the circles one socket watches, and every
// publish leaves over one publish socket), and circles on DISJOINT relay sets
// now emit the same inter-burst rhythm — so anyone holding two of your circles'
// archives can tell they belong to the same phone.
//
// What survives is the [PublishStagger] BETWEEN consecutive encrypts, and it
// answers a different observer: the engine binds the outer kind-445
// `created_at` to the inner app event's WHOLE-SECOND timestamp, so two circles
// encrypted inside one second carry a byte-identical `created_at` inside the
// SIGNED event — readable from an archive by someone who never saw the socket.
// The first three tests here are that promise, executed: one tick reaches every
// circle, consecutive encrypts land 2-9 s apart, and the burst's spread stays
// inside the budget the freshness constants allow.
//
// ## What is pinned by grep, and why
//
// The rest of the decorrelation runs where `flutter test` cannot reach it:
//
//   * the foreground burst's own timing, with the production constants:
//     `test/providers/location_publish_decorrelation_test.dart`;
//   * the background pacing rule and its shared seed:
//     `test/services/per_circle_due_tracker_test.dart` drives
//     `nextBackgroundPublishSlot` directly, including the slow-publish case;
//   * the stagger's own bounds: `test/services/publish_stagger_test.dart`;
//   * the background CYCLE that calls those pieces, over
//     `test/mocks/background_task_fakes.dart`
//     (`test/services/background_location_task_publish_cycle_test.dart` drives
//     two due circles through a real stagger).
//
// A behavioural run proves the gap held for the circles it scheduled; it cannot
// see a later rewrite that bypasses the stagger for some other path. So this
// file also pins WIRING: that the background cycle still routes through the
// decorrelating helpers instead of the shapes it used to have. It matches
// identifiers, never prose, so a comment rewrite cannot satisfy or break it.

import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
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

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins a privacy invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//` line comments and `///` doc comments so an assertion can never
/// be satisfied — or broken — by a comment that merely mentions an identifier.
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

Circle _circle(int id) => TestCircleFactory.createCircle(
  mlsGroupId: [id],
  nostrGroupId: [id],
  members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Gaps between consecutive `encryptLocation` entries, in milliseconds.
List<int> _separationsMs(MockCircleService mock) => <int>[
  for (var i = 1; i < mock.encryptCallTimes.length; i++)
    mock.encryptCallTimes[i]
        .difference(mock.encryptCallTimes[i - 1])
        .inMilliseconds,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({ProviderContainer container, MockCircleService mock}) build(
    List<Circle> circles,
    PublishStagger stagger,
  ) {
    SharedPreferences.setMockInitialValues({
      kLocationDisclosureAcceptedKey: true,
    });
    final mock = MockCircleService(circles: circles);
    final container = ProviderContainer(
      overrides: [
        identityServiceProvider.overrideWithValue(_StubIdentityService()),
        locationServiceProvider.overrideWithValue(_StubLocationService()),
        circleServiceProvider.overrideWithValue(mock),
        locationSharingServiceProvider.overrideWithValue(
          LocationSharingService(
            circleService: mock,
            relayService: MockRelayService(),
          ),
        ),
        locationPublishJitterSamplerProvider.overrideWithValue((_) => 120),
        locationPublishStaggerProvider.overrideWithValue(stagger),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, mock: mock);
  }

  /// Reads the notifier and lets its `circlesProvider` listen resolve, so the
  /// roster is populated and the tick is armed.
  Future<LocationPublishSchedulerNotifier> ready(
    ProviderContainer container,
  ) async {
    final notifier = container.read(
      locationPublishSchedulerProvider.notifier,
    );
    await container.read(circlesProvider.future);
    await pumpEventQueue();
    return notifier;
  }

  group('one jittered burst per interval', () {
    test('every circle is published in one burst per tick', () async {
      // Two halves of one promise, and the first is the battery half: on THIS
      // plane five circles arm ONE wake, not five. Per-circle schedulers made
      // the wake count the circle count, on every plane, for a decorrelation
      // that a shared relay could see through anyway.
      //
      // "One wake" is this plane's timer count and not a claim about the
      // device: the Android foreground service has no timer of its own — it
      // publishes on platform location deliveries, and its cadence is proved
      // separately in `background_fix_request_test.dart`.
      final env = build(
        [for (var i = 1; i <= 5; i++) _circle(i)],
        PublishStagger.none(),
      );
      final notifier = await ready(env.container);

      expect(
        notifier.armedWakesForTest,
        1,
        reason: 'the wake count must not scale with the circle count',
      );

      await notifier.triggerTickForTest();

      expect(
        env.mock.encryptedMlsGroupIds.map(_hex).toSet(),
        {for (var i = 1; i <= 5; i++) _hex([i])},
        reason: 'one wake is only allowed to replace five if it reaches every '
            'circle those five would have published',
      );
      expect(
        env.mock.encryptedMlsGroupIds,
        hasLength(5),
        reason: 'exactly once each — a burst that published a circle twice '
            'would spend the cadence it saved',
      );
    });

    test(
      'consecutive encrypts are ≥ 2 s and ≤ 9 s apart (gap sampled per pair)',
      () async {
        // The production bounds, on the real chain, under a seeded CSPRNG so
        // the wall clock of this test is a fact rather than a draw. Four
        // circles is three gaps: enough for "sampled per pair" to be visible.
        final env = build(
          [for (var i = 1; i <= 4; i++) _circle(i)],
          PublishStagger(rng: Random(246)),
        );
        final notifier = await ready(env.container);

        await notifier.triggerTickForTest();

        expect(env.mock.encryptCallTimes, hasLength(4));
        final separations = _separationsMs(env.mock);
        for (final ms in separations) {
          expect(
            ms,
            greaterThanOrEqualTo(kPublishStaggerMinGap.inMilliseconds),
            reason: 'the kind-445 created_at is a whole-second u64, so a pair '
                'closer than the floor can share one stamp — which is the '
                'leak, not a hint of it',
          );
          expect(
            ms,
            // Measured around an encrypt, so the scheduled ceiling plus
            // measurement slack; the ceiling itself is pinned by
            // publish_stagger_test.
            lessThanOrEqualTo(kPublishStaggerMaxGap.inMilliseconds + 1500),
            reason: 'a burst that outruns the per-gap ceiling publishes the '
                'last circle from a fix the app itself would call stale',
          );
        }
        expect(
          separations.map((ms) => ms ~/ 500).toSet(),
          hasLength(3),
          reason: 'one draw reused for the whole burst would put a CONSTANT '
              'delta between every pair — a fingerprint of its own, and the '
              'thing a per-pair sample exists to avoid',
        );
      },
    );

    test(
      'a sampled burst never overruns its predicted spread, for every burst '
      'size the app admits',
      () {
        final stagger = PublishStagger(rng: Random(17));
        for (var n = 2; n <= kMaxCirclesPerBurst; n++) {
          for (var trial = 0; trial < 200; trial++) {
            final spread = stagger
                .sampleGaps(n)
                .fold(Duration.zero, (a, b) => a + b);
            expect(
              spread,
              lessThanOrEqualTo(stagger.maxSpreadFor(n)),
              reason: 'a burst of $n circles overran its own predicted spread, '
                  'which is what every freshness and no-gap bound is computed '
                  'from',
            );
            expect(
              spread,
              lessThanOrEqualTo(kPublishStaggerMaxSpread),
              reason: 'and the whole point of the cap is that the predicted '
                  'spread never leaves the budget: at $n circles it did',
            );
          }
        }
        // The cap must actually BIND, or it is decoration. With a per-gap
        // ceiling near the `minGap + 1 s` floor the spread grows linearly and
        // never reaches the budget, so this is the assertion that a 2-2.5 s
        // stagger fails: it would leave the spread at 2.5 x (n-1), bounded by
        // nothing here.
        expect(
          stagger.maxSpreadFor(kMaxCirclesPerBurst),
          kPublishStaggerMaxSpread,
          reason: 'the 30 s cap never engages, so nothing in this range is '
              'actually bounded by it',
        );
        // The no-gap invariant itself — swept over the same range, and with
        // the propagation margin the retention reserves left intact — is
        // pinned in `publish_stagger_test.dart`. What matters here is that
        // the range this file exercises is the range the app admits: one more
        // circle than the cap is DEFERRED, never published into a wider
        // spread.
        expect(
          kLocationPublishMaxInterval +
              stagger.maxSpreadFor(kMaxCirclesPerBurst),
          lessThanOrEqualTo(const Duration(seconds: 198)),
          reason: 'a circle that moves from the front of one burst to the '
              'back of the next waits the cadence ceiling PLUS the spread, '
              'and a relay must still hold a non-expired event across it — '
              'with the 30 s of the 228 s retention that is reserved for '
              'propagation and clock skew still unspent',
        );
      },
    );
  });

  group('background publish cycle wiring', () {
    late String code;

    setUp(() {
      code = _codeOnly(_read('lib/src/services/background_location_task.dart'));
    });

    test('seeds every circle of a handoff at ONE instant', () {
      // `pruneToKeys({})` empties the tracker on every cycle the foreground
      // owns publishing, so this seed re-runs on every foreground→background
      // handoff — which makes it the shape that decides whether a handoff
      // hands the roster to one burst or to a wake apiece. This exact string
      // used to be FORBIDDEN here; coalescing reverses that, and the pacing
      // below is what still keeps the circles out of one second.
      expect(
        code,
        contains('seedIfAbsent(key, timestamp)'),
        reason: 'a per-circle seed re-scatters the roster on every handoff',
      );
    });

    test('paces each publish through the running-gap slot rule', () {
      expect(
        code,
        contains('nextBackgroundPublishSlot('),
        reason: 'without this the cycle publishes its due circles back to '
            'back; one burst makes every circle due at once, so the slot rule '
            'is the only thing spacing them',
      );
    });

    test('the burst budget is anchored at the first PUBLISH, not at the '
        'cycle start', () {
      // The fix is delivered `kBackgroundFixLeadTime` BEFORE the due it was
      // taken for, so the cycle's first publish waits. A deadline measured
      // from the cycle start therefore hands the burst only `30 s − lead` of
      // its own spread budget, and rosters that fit are split across two
      // cycles — one wake per interval becoming two, on the plane whose wake
      // count is the entire claim. Measured at 2.2 circles per cycle at
      // n = 4 before this anchor, 4.0 after.
      //
      // Pinned by wiring rather than behaviourally: reproducing the split
      // needs a burst that genuinely spends most of `kPublishStaggerMaxSpread`
      // in real waits, i.e. a ~30 s unit test. The arithmetic itself is swept
      // in `background_fix_request_test.dart`, which reimplements the cycle's
      // ordering and so cannot see this call site.
      expect(
        code,
        contains('deadline: (firstPlannedSlot ?? planStart).add('),
        reason: 'the planning pass must price the burst from its first slot',
      );
      expect(
        code,
        contains('deadline: (firstPublishStartedAt ?? publishPhaseStart).add('),
        reason: 'and the publish loop from its first actual publish',
      );
      expect(
        code,
        isNot(contains('deadline: planStart.add(')),
        reason: 'a cycle-start deadline spends the lead time out of the '
            'decorrelation budget',
      );
      expect(
        code,
        isNot(contains('deadline: publishPhaseStart.add(')),
        reason: 'same defect, in the loop that actually publishes',
      );
    });

    test('the decorrelation wait is the cancellable one', () {
      expect(code, contains('_sleepUnlessShuttingDown('));
      expect(
        code,
        isNot(contains('await Future<void>.delayed(wait)')),
        reason: 'an uncancellable wait would spend the service-stop window '
            'sleeping between circles',
      );
    });

    test('shutdown is signalled BEFORE onDestroy awaits the in-flight cycle',
        () {
      final signal = code.indexOf('_shutdownSignal.complete()');
      final awaitInFlight = code.indexOf('await _inFlightPublish');
      expect(signal, isNot(-1));
      expect(awaitInFlight, isNot(-1));
      expect(
        signal,
        lessThan(awaitInFlight),
        reason: 'signalling after the await releases nothing — the await is '
            'what the wait is blocking',
      );
    });
  });

  group('foreground pause cancels an in-flight burst', () {
    // `MapShell` cannot be widget-tested without the Rust bridge (CLAUDE.md),
    // which is why its `detached` handling is pinned the same way in
    // `test/pages/map_shell_detached_release_test.dart`. The BEHAVIOUR of the
    // guard being tripped — a disposed burst stops mid-flight — is executed in
    // `location_publish_decorrelation_test.dart`; what is pinned here is only
    // that pause actually trips it.
    late String pausedBody;

    setUpAll(() {
      final source = _read('lib/src/pages/map_shell.dart');
      final start = source.indexOf('Future<void> _onPaused() async {');
      expect(
        start,
        isNonNegative,
        reason: '_onPaused must exist; if it was renamed, update this guard '
            'rather than deleting it',
      );
      // Bounded by the next member, so the assertion below cannot be satisfied
      // by an invalidate somewhere else in a 1500-line file.
      final end = source.indexOf('\n  /// ', start);
      expect(end, greaterThan(start));
      pausedBody = source.substring(start, end);
    });

    test('pause invalidates the burst publisher', () {
      expect(
        pausedBody,
        contains('invalidate(locationPublisherProvider)'),
        reason: 'a paced burst runs for tens of seconds, so without this it '
            'keeps publishing after pause has already told the background '
            'isolate the foreground is finished',
      );
    });
  });

  group('stagger randomness source', () {
    test('the production stagger draws from a CSPRNG', () {
      // This is a privacy control: a predictable delay stream lets an observer
      // subtract the stagger and recover the co-timing it was added to hide.
      // `Random()` is seeded from a low-entropy source and is explicitly not
      // acceptable here.
      bool drawsFromCsprng(String source) =>
          _codeOnly(source).contains('rng ?? Random.secure()');

      // Fixtures first, in both directions: a check that cannot fail is not
      // evidence that the tree is healthy.
      expect(drawsFromCsprng('_rng = rng ?? Random.secure(),'), isTrue);
      expect(
        drawsFromCsprng('_rng = rng ?? Random(),'),
        isFalse,
        reason: 'the check would accept a low-entropy source',
      );
      expect(
        drawsFromCsprng('/// _rng = rng ?? Random.secure()'),
        isFalse,
        reason: 'a doc comment naming the CSPRNG would satisfy the check '
            'while the code drew from anything at all',
      );

      expect(
        drawsFromCsprng(_read('lib/src/services/publish_stagger.dart')),
        isTrue,
        reason: 'the default randomness source is no longer a CSPRNG',
      );
    });

    test('production never constructs the zero-gap sampler', () {
      // `PublishStagger.none()` collapses every gap to zero — the identical
      // `created_at` linkage the stagger exists to prevent — and its own doc
      // reserves it for tests. The handler takes its sampler by constructor,
      // so building this in `lib/` is the one way to lose the CSPRNG.
      final lib = Directory('lib').existsSync()
          ? Directory('lib')
          : Directory('haven/lib');
      final offenders = lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          // The declaration itself lives here; every other match is a call.
          .where((f) => !f.path.endsWith('publish_stagger.dart'))
          .where(
            (f) => _codeOnly(f.readAsStringSync())
                .contains('PublishStagger.none('),
          )
          .map((f) => f.path)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'a zero-gap stagger reached production code',
      );
    });
  });
}

/// The identity the burst publishes under. [Fake] on purpose: a burst reads
/// exactly one thing from this service, and spelling out the rest would be a
/// second place to keep the interface in sync.
class _StubIdentityService extends Fake implements IdentityService {
  @override
  Future<Identity?> getIdentity() async => Identity(
    pubkeyHex: _selfPubkey,
    npub: 'npub1self',
    createdAt: DateTime(2025),
  );
}

class _StubLocationService extends Fake implements LocationService {
  @override
  Future<Position> getCurrentLocation() async =>
      Position(latitude: 37, longitude: -122, timestamp: DateTime.now());
}
