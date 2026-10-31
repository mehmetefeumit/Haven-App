/// The sharing-health model: every state transition, on an injected clock.
///
/// The promise under test is the one the field incident broke — that a pipeline
/// which has stopped delivering says so, and that a pipeline which has merely
/// gone quiet does NOT. Both halves matter: a banner that never fires is the
/// defect being fixed, and a banner that fires on ordinary quiet trains the
/// user to ignore it, which is the same defect with extra steps.
///
/// Time is injected end to end (`sharingHealthClockProvider` plus an explicit
/// `refresh()`), so no assertion here depends on a wall clock, a sleep, or the
/// periodic tick firing at a lucky moment.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/clock_skew_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi, FfiSyncStatusReason;
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/subscription_service.dart'
    show LiveSyncStopOutcome;

import '../helpers/fake_change_notices.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final _identity = Identity(
  pubkeyHex: _selfPubkey,
  npub: 'npub1self',
  createdAt: DateTime(2025),
);

/// Fixed reference instant; every timestamp in a test is expressed relative to
/// it, so a reader can see the age being asserted without arithmetic.
final _t0 = DateTime.utc(2026, 8, 28, 12);

Circle _circle({List<CircleMember>? members}) =>
    TestCircleFactory.createCircle(
      mlsGroupId: const [1, 2, 3],
      nostrGroupId: const [9, 9],
      members:
          members ??
          [
            TestCircleFactory.createMember(pubkey: _selfPubkey),
            TestCircleFactory.createMember(pubkey: _peerPubkey),
          ],
    );

/// In-memory [CircleHealthService]: the persisted half of the evidence.
class _FakeHealthService implements CircleHealthService {
  CircleHealthTimestamps stored = CircleHealthTimestamps.none;
  final List<DateTime> ackedAt = [];
  final List<DateTime> peerAt = [];

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {
    ackedAt.add(at);
    stored = CircleHealthTimestamps(
      lastPublishAckedAt: at,
      lastPeerEventAt: stored.lastPeerEventAt,
    );
  }

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {
    peerAt.add(at);
    stored = CircleHealthTimestamps(
      lastPublishAckedAt: stored.lastPublishAckedAt,
      lastPeerEventAt: at,
    );
  }

  /// When set, `read` blocks on it — lets a test hold one derivation open
  /// while a later one overtakes it.
  Completer<void>? gate;
  Completer<void>? _held;

  void releaseGate() => _held?.complete();

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async {
    // Snapshot BEFORE awaiting, exactly as a real storage read does: it sees
    // the database as it was when the query ran, not as it is when the future
    // finally completes. Reading `stored` after the await made every held call
    // return the NEWEST value, so the stale answer the generation fence exists
    // to discard never existed and the fence was untestable.
    final snapshot = stored;
    final held = gate;
    if (held != null) {
      _held = held;
      await held.future;
    }
    return snapshot;
  }
}

/// A circle service whose recovery read answers as the core does for the
/// engine states the circle list carries, unless a test sets a cause.
class _CoreRecovery extends MockCircleService {
  _CoreRecovery({super.circles});

  @override
  Future<CircleRecoveryCause?> circleRecovery(Circle circle) async {
    final read = await super.circleRecovery(circle);
    return read ??
        switch (circle.engineState) {
          CircleEngineState.live => null,
          CircleEngineState.quarantined => CircleRecoveryCause.quarantined,
          CircleEngineState.disbanded => CircleRecoveryCause.disbanded,
          CircleEngineState.unrecoverable => CircleRecoveryCause.unrecoverable,
        };
  }
}

/// Records every verdict the model publishes.
class _VerdictRecorder extends ProviderObserver {
  final List<Object?> verdicts = [];

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (provider == sharingHealthProvider) verdicts.add(newValue);
  }
}

/// Drives the model with an explicit clock the test moves by hand.
class _Harness {
  _Harness({
    Circle? circle,
    List<MemberLocation>? locations,
    List<ProviderObserver> observers = const [],
  }) : health = _FakeHealthService(),
       service = _CoreRecovery(circles: [circle ?? _circle()]) {
    final selected = circle ?? _circle();
    container = ProviderContainer(
      observers: observers,
      overrides: [
        sharingHealthClockProvider.overrideWithValue(() => now),
        circleHealthServiceProvider.overrideWithValue(health),
        circleServiceProvider.overrideWithValue(service),
        changeNoticesProvider.overrideWithValue(fakeChangeNotices(notices)),
        // The model listens to the circle list as well as the selection.
        circlesProvider.overrideWith((ref) async => [selected]),
        selectedCircleProvider.overrideWithValue(selected),
        identityProvider.overrideWith((ref) async => _identity),
        // The model must NOT consult this (a peer's own clock cannot be
        // allowed to suppress the banner), so it is stocked with deliberately
        // FRESH rows: any test that starts passing because of them is a
        // regression, not a pass.
        memberLocationsProvider.overrideWith(
          (ref) async => locations ?? const <MemberLocation>[],
        ),
        // Plain notifier, not the real `AppLifecycleListener`: these tests
        // build no widget binding.
        sharingHealthForegroundProvider.overrideWithValue(foreground),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);
  }

  final _FakeHealthService health;
  final _CoreRecovery service;
  final FakeNoticeManager notices = FakeNoticeManager();
  final ValueNotifier<bool> foreground = ValueNotifier<bool>(true);
  late final ProviderContainer container;
  DateTime now = _t0;

  SharingHealthNotifier get notifier =>
      container.read(sharingHealthProvider.notifier);

  /// Resolves the async overrides the model reads synchronously, then derives.
  Future<SharingHealth> settle() async {
    await container.read(identityProvider.future);
    await container.read(memberLocationsProvider.future);
    await notifier.refresh();
    // Which circle the verdict is about is held by its own test; the
    // assertions here are about the verdict itself.
    return container.read(sharingHealthProvider).about(null);
  }

  void advance(Duration by) => now = now.add(by);
}

void main() {
  group('healthy — the model refuses to report what it cannot distinguish', () {
    test('a circle that has never published or received says nothing',
        () async {
      // Anti-vacuity for every "is reported" assertion below, and the honest
      // core of the model: no evidence is not evidence of failure.
      final h = _Harness();
      expect(await h.settle(), SharingHealth.healthy);

      h.advance(kReceiveSilenceThreshold * 10);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('a solo circle never reports receive silence', () async {
      // Nothing to receive: the quiet is the roster, not the pipeline.
      final h = _Harness(
        circle: _circle(
          members: [TestCircleFactory.createMember(pubkey: _selfPubkey)],
        ),
      );
      h.health.stored = CircleHealthTimestamps(lastPeerEventAt: _t0);

      h.advance(kReceiveSilenceThreshold * 2);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('a peer who has never shared is not a fault', () async {
      // The circle has a peer and a healthy send plane, but nothing has ever
      // arrived. That is indistinguishable from a peer who simply is not
      // sharing, so it must not be reported as breakage.
      final h = _Harness();
      h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: _t0);

      h.advance(kReceiveSilenceThreshold * 2);
      expect(
        (await h.settle()).state,
        isNot(SharingHealthState.receiveSilent),
      );
    });
  });

  group('publishFailing', () {
    test('fires once no relay has kept a publish for two cadences', () async {
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );

      h.advance(kPublishSilenceThreshold);
      expect(
        (await h.settle()).state,
        SharingHealthState.healthy,
        reason: 'exactly at the threshold is not yet past it',
      );

      h.advance(const Duration(seconds: 1));
      expect(await h.settle(), SharingHealth.publishFailing(_t0));
    });

    test('a recorded unacked publish reports sooner than the ack '
        'staleness alone would', () async {
      // The fast route: this isolate WATCHED a publish come back with an empty
      // `acceptedBy`. Before this model that verdict ended in a debugPrint.
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('010203', acked: false);

      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        h.now.difference(_t0),
        lessThan(kPublishSilenceThreshold),
        reason: 'the slow route cannot have fired yet — otherwise this test '
            'would pass without the recorded outcome',
      );
      expect(await h.settle(), SharingHealth.publishFailing(_t0));
    });

    test('a publish failing with no stored ack has no provable age',
        () async {
      // Relays that never ack, or a collided circle whose health the core
      // answers with no instants: the onset is this process's own.
      final h = _Harness();
      h.notifier.recordPublishOutcome('010203', acked: false);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      expect(
        await h.settle(),
        SharingHealth.publishFailing(_t0, ageProvable: false),
      );
    });

    test('one unacked publish inside the confirmation window stays quiet',
        () async {
      // A single failed publish is a transient; only a run of them is a fault.
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('010203', acked: false);

      h.advance(kSharingFaultConfirmationWindow);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('an ack clears the failure run', () async {
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('010203', acked: false);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: h.now);
      h.notifier.recordPublishOutcome('010203', acked: true);

      expect(await h.settle(), SharingHealth.healthy);
    });

    test("an ack recorded by the OTHER isolate clears this isolate's "
        'failure run', () async {
      // The Android foreground service has no Riverpod container: a whole
      // backgrounded session of successful publishes reaches this model ONLY
      // as the persisted ack. Without this reconciliation, a foreground
      // failure recorded before the pause would outlive it and show a banner
      // over a pipeline that had been working the entire time.
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('010203', acked: false);

      h.advance(const Duration(minutes: 30));
      h.health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: h.now.subtract(const Duration(seconds: 10)),
      );

      expect(await h.settle(), SharingHealth.healthy);
    });

    test("another circle's failure does not condemn this one", () async {
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('deadbeef', acked: false);

      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(await h.settle(), SharingHealth.healthy);
    });
  });

  group('receiveSilent', () {
    test('fires once a circle that WAS receiving goes quiet', () async {
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPeerEventAt: _t0,
      );

      h.advance(kReceiveSilenceThreshold);
      expect(
        (await h.settle()).state,
        SharingHealthState.healthy,
        reason: 'exactly at the threshold is not yet past it',
      );

      h.advance(const Duration(seconds: 1));
      expect(await h.settle(), SharingHealth.receiveSilent(_t0));
    });

    test("a peer's own clock cannot suppress the verdict", () async {
      // The mutation guard for the sender-clock floor that used to sit in
      // `_latestPeerEvidence`. `MemberLocation.timestamp` is the SENDER's
      // reading — `LocationSharingService` records a LOCAL receipt time
      // precisely because a peer running fast would otherwise keep the circle
      // looking live long after it went silent. Re-introducing a max over it
      // makes this test fail: the fresh row below is far newer than the
      // persisted stamp.
      final fabricated = _t0.add(const Duration(days: 365));
      final h = _Harness(
        locations: [
          MemberLocation(
            pubkey: _peerPubkey,
            latitude: 1,
            longitude: 2,
            geohash: 'u4pruy',
            timestamp: fabricated,
            expiresAt: fabricated.add(const Duration(minutes: 4)),
            receivedAt: null,
          ),
        ],
      )..health.stored = CircleHealthTimestamps(lastPeerEventAt: _t0);

      h.advance(kReceiveSilenceThreshold + const Duration(seconds: 1));
      expect(await h.settle(), SharingHealth.receiveSilent(_t0));
    });

    test('the persisted receipt stamp is the only evidence consulted',
        () async {
      // The other direction of the same rule: a stamp written by EITHER
      // isolate keeps the banner away, with no cached row involved at all.
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(
          lastPeerEventAt: _t0.add(kReceiveSilenceThreshold),
        );

      h.advance(kReceiveSilenceThreshold + const Duration(seconds: 1));
      expect(await h.settle(), SharingHealth.healthy);
    });
  });

  group('paused — a named cause outranks an inferred one', () {
    // Where no delivery instant is stored, the onset proves no age: those
    // verdicts say so (`ageProvable: false`), and the banner shows none.
    test('a relay disconnect that persists past the confirmation window',
        () async {
      final h = _Harness();
      await h.settle();

      h.container.read(syncStatusProvider.notifier).onStatus(
        FfiSyncStatusReason.disconnected,
      );
      expect(
        await h.settle(),
        SharingHealth.healthy,
        reason: 'a momentary drop is ordinary mobile behaviour',
      );

      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.relayDisconnected,
          _t0,
          ageProvable: false,
        ),
      );
    });

    test('a background pause never becomes a relayDisconnected verdict',
        () async {
      // A burst closes its sockets on purpose and the gap to the next burst
      // can exceed the confirmation window many times over. Background sharing
      // working exactly as designed must never tell the user it had stopped —
      // a deliberate, user-visible suppression, so it needs a test that fails
      // when it goes.
      final h = _Harness();
      await h.settle();
      final status = h.container.read(syncStatusProvider.notifier)
        ..onStatus(FfiSyncStatusReason.disconnected)
        // Paused before the window could confirm anything.
        ..onStatus(FfiSyncStatusReason.paused);

      h.advance(kSharingFaultConfirmationWindow * 10);
      expect(await h.settle(), SharingHealth.healthy);

      // Anti-vacuity, and the other half of the promise: the next burst opens
      // and the relay is still gone. The disconnect stamp SURVIVED the pause,
      // so the outage is dated from when the relay actually went — not from
      // the un-pause, which would report a long outage as brand new and start
      // the confirmation window over.
      status.onStatus(FfiSyncStatusReason.disconnected);
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.relayDisconnected,
          _t0,
          ageProvable: false,
        ),
      );
    });

    test('a pause never clears a fault the user is already being shown',
        () async {
      // The banner speaks every stopped → healthy edge as "sharing resumed"
      // (`sharing_health_banner.dart`), so a verdict that clears itself on a
      // pause tells a screen-reader user the outage is over. Nothing
      // recovered: the app stopped looking. One relay of the pool can be down
      // for hours while the others keep acking publishes, which is exactly the
      // state that reaches here with the banner already up.
      final h = _Harness();
      await h.settle();
      final status = h.container.read(syncStatusProvider.notifier)
        ..onStatus(FfiSyncStatusReason.disconnected);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.relayDisconnected,
        reason: 'anti-vacuity: the verdict must be reachable first',
      );

      status.onStatus(FfiSyncStatusReason.paused);
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.relayDisconnected,
          _t0,
          ageProvable: false,
        ),
      );

      h.advance(kSharingFaultConfirmationWindow * 10);
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.relayDisconnected,
          _t0,
          ageProvable: false,
        ),
        reason: 'no length of pause is evidence that anything recovered',
      );
    });

    test('a pause defers evidence rather than discarding it', () async {
      // The freeze must not become a hole: a publish that came back unacked
      // during a burst is real evidence, and it has to reach the user once the
      // engine is looking again. Recorded while paused, reported on un-pause.
      final h = _Harness();
      await h.settle();
      final status = h.container.read(syncStatusProvider.notifier)
        ..onStatus(FfiSyncStatusReason.paused);

      h.notifier.recordPublishOutcome('010203', acked: false);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        await h.settle(),
        SharingHealth.healthy,
        reason: 'a paused engine derives nothing, in either direction',
      );

      status.onStatus(FfiSyncStatusReason.connected);
      expect(
        await h.settle(),
        SharingHealth.publishFailing(_t0, ageProvable: false),
        reason: 'the evidence was held, not dropped',
      );
    });

    test('un-pausing into a healthy engine reports the recovery', () async {
      // The freeze is not a latch. A burst that reconnects is real evidence,
      // and the recovery the banner announces on this edge is then a true one.
      final h = _Harness();
      await h.settle();
      final status = h.container.read(syncStatusProvider.notifier)
        ..onStatus(FfiSyncStatusReason.disconnected);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      status
        ..onStatus(FfiSyncStatusReason.paused)
        ..onStatus(FfiSyncStatusReason.connected);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('reconnecting clears the disconnect', () async {
      final h = _Harness();
      await h.settle();
      final status = h.container.read(syncStatusProvider.notifier)
        ..onStatus(FfiSyncStatusReason.disconnected);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      status.onStatus(FfiSyncStatusReason.connected);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('a quarantined circle is reported at once, before any other cause',
        () async {
      // Known the moment the circle list is read and never transient, so no
      // confirmation window applies; and it outranks a named cause, because
      // repairing that cause cannot help a circle whose state never loaded.
      final h = _Harness(
        circle: TestCircleFactory.createCircle(
          mlsGroupId: const [1, 2, 3],
          nostrGroupId: const [9, 9],
          engineState: CircleEngineState.quarantined,
        ),
      );
      h.notifier.recordDeferredSend('010203');

      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.circleQuarantined,
          _t0,
          ageProvable: false,
        ),
      );
    });

    test('a disbanded circle is reported at once, with no age, before any '
        'other cause', () async {
      final h = _Harness(
        circle: TestCircleFactory.createCircle(
          mlsGroupId: const [1, 2, 3],
          nostrGroupId: const [9, 9],
          engineState: CircleEngineState.disbanded,
        ),
      );
      h.notifier.recordDeferredSend('010203');

      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.circleDisbanded,
          _t0,
          ageProvable: false,
        ),
      );
    });

    group('another circle selected is re-derived at once, with no tick', () {
      final disbanded = TestCircleFactory.createCircle(
        mlsGroupId: const [1, 2, 3],
        nostrGroupId: const [9, 9],
        engineState: CircleEngineState.disbanded,
      );
      final live = TestCircleFactory.createCircle(
        mlsGroupId: const [4, 5, 6],
        nostrGroupId: const [8, 8],
      );

      ({ProviderContainer container}) build(Circle first) {
        final list = StateProvider<List<Circle>>((ref) => [disbanded, live]);
        final foreground = ValueNotifier<bool>(true);
        final container = ProviderContainer(
          overrides: [
            sharingHealthClockProvider.overrideWithValue(() => _t0),
            circleHealthServiceProvider.overrideWithValue(_FakeHealthService()),
            circleServiceProvider.overrideWithValue(_CoreRecovery()),
            changeNoticesProvider.overrideWithValue(
              fakeChangeNotices(FakeNoticeManager()),
            ),
            // The real selection, over a list the test refreshes.
            circlesProvider.overrideWith((ref) async => ref.watch(list)),
            identityProvider.overrideWith((ref) async => _identity),
            memberLocationsProvider.overrideWith(
              (ref) async => const <MemberLocation>[],
            ),
            sharingHealthForegroundProvider.overrideWithValue(foreground),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(foreground.dispose);
        container.read(selectedCircleIdProvider.notifier).state =
            first.mlsGroupId;
        // Kept alive, as the banner keeps it: built now, derived from here on.
        container.listen(sharingHealthProvider, (_, _) {});
        return (container: container);
      }

      Future<SharingHealth> settled(ProviderContainer container) async {
        await container.read(identityProvider.future);
        await container.read(circlesProvider.future);
        await pumpEventQueue();
        // Which circle the verdict is about is held by its own test; the
    // assertions here are about the verdict itself.
    return container.read(sharingHealthProvider).about(null);
      }

      test('from a disbanded circle to a live one: no "ended" banner over '
          'the live circle', () async {
        final t = build(disbanded);
        expect(
          (await settled(t.container)).pausedReason,
          SharingPausedReason.circleDisbanded,
          reason: 'premise',
        );

        t.container.read(selectedCircleIdProvider.notifier).state =
            live.mlsGroupId;

        expect(
          await settled(t.container),
          SharingHealth.healthy,
          reason: 'a live circle shown as ended, with "leave it" as the '
              'remedy, until the next tick',
        );
      });

      test('a selection made as the circle list is re-read is derived for '
          'the new circle', () async {
        // With nothing selected the selection does not read the list, so the
        // list's re-read is first run from inside the selection's rebuild and
        // notifies the model while the selection is still building.
        final t = build(disbanded);
        t.container.read(selectedCircleIdProvider.notifier).state = null;
        expect(await settled(t.container), SharingHealth.healthy);

        t.container.read(selectedCircleIdProvider.notifier).state =
            live.mlsGroupId;
        t.container.invalidate(circlesProvider);
        // The frame's refresh, not a read from here, rebuilds the selection.
        await t.container.pump();
        await settled(t.container);

        expect(
          t.container.read(sharingHealthProvider),
          SharingHealth.healthy.about(sharingCircleKey(live)),
        );
      });

      test('a disbanded circle left (nothing selected) leaves no banner',
          () async {
        final t = build(disbanded);
        expect(
          (await settled(t.container)).pausedReason,
          SharingPausedReason.circleDisbanded,
          reason: 'premise',
        );

        t.container.read(selectedCircleIdProvider.notifier).state = null;

        expect(await settled(t.container), SharingHealth.healthy);
      });
    });

    test('the quarantine retry reloads the selected circle and re-reads the '
        'circle list', () async {
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [1, 2, 3],
        nostrGroupId: const [9, 9],
        engineState: CircleEngineState.quarantined,
      );
      final service = MockCircleService(circles: [circle]);
      final foreground = ValueNotifier<bool>(true);
      addTearDown(foreground.dispose);
      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(service),
          selectedCircleProvider.overrideWithValue(circle),
          sharingHealthClockProvider.overrideWithValue(() => _t0),
          circleHealthServiceProvider.overrideWithValue(_FakeHealthService()),
          identityProvider.overrideWith((ref) async => _identity),
          sharingHealthForegroundProvider.overrideWithValue(foreground),
        ],
      );
      addTearDown(container.dispose);

      await container.read(sharingQuarantineRetryProvider)();

      expect(service.methodCalls, contains('retryQuarantinedCircle'));
      expect(
        service.methodCalls.indexOf('getVisibleCircles'),
        greaterThan(service.methodCalls.indexOf('retryQuarantinedCircle')),
        reason: 'the verdict must follow what the engine holds after the retry',
      );
    });

    test("a held send's core cause shows once the window has passed, dated "
        'from the first held send', () async {
      // Before: Dart named every held send `sendDeferred` and dated it. Now
      // the core names the cause; a held send only dates it, so a transient
      // cause the core reads is not shown inside the window that ordinary
      // work clears it in.
      final h = _Harness();
      h.service.recoveryCause = CircleRecoveryCause.awaitingRelays;
      h.notifier.recordDeferredSend('010203');
      expect(
        await h.settle(),
        SharingHealth.healthy,
        reason: 'inside the window a pending change is ordinary work',
      );

      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.awaitingRelays,
          _t0,
          ageProvable: false,
        ),
      );
    });

    test('a circle whose sends the core holds reads as held, never as a '
        'publish or receive silence', () async {
      final h = _Harness();
      h.service.recoveryCause = CircleRecoveryCause.awaitingRelays;
      h.notifier.recordDeferredSend('010203');
      h.advance(kPublishSilenceThreshold + kReceiveSilenceThreshold);
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.awaitingRelays,
          _t0,
          ageProvable: false,
        ),
      );

      // The held state outranks the silences even where both are evidenced,
      // and a cause that holds both directions is dated by the older one.
      final delivered = _t0.subtract(const Duration(hours: 1));
      h.health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: delivered,
        lastPeerEventAt: delivered,
      );
      expect(
        await h.settle(),
        SharingHealth.paused(SharingPausedReason.awaitingRelays, delivered),
      );
    });

    test('a held send outlives a routing rotation of its circle', () async {
      // Recorded under the circle as it was; read under the id it moved to.
      final rotated = TestCircleFactory.createCircle(
        mlsGroupId: const [1, 2, 3],
        nostrGroupId: const [7, 7],
        members: [
          TestCircleFactory.createMember(pubkey: _selfPubkey),
          TestCircleFactory.createMember(pubkey: _peerPubkey),
        ],
      );
      final h = _Harness(circle: rotated);
      h.service
        ..recoveryCause = CircleRecoveryCause.departureDue
        // The read at the hold fails, so the first read naming the cause
        // comes 30 s later: the older hold must date the onset.
        ..recoveryError = StateError('store busy');
      h.notifier.recordDeferredSend(sharingCircleKey(_circle()));
      await h.settle();
      h.advance(const Duration(seconds: 30));
      h.service.recoveryError = null;
      expect(await h.settle(), SharingHealth.healthy, reason: 'window');
      h.advance(kSharingFaultConfirmationWindow - const Duration(seconds: 29));

      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.departureDue,
          _t0,
          ageProvable: false,
        ),
      );
    });

    test('a lost relay subscription (Unit C) is reported and can be cleared',
        () async {
      final h = _Harness();
      h.notifier.recordRelaySubscriptionLost();
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          _t0,
          ageProvable: false,
        ),
      );

      h.notifier.recordRelaySubscriptionRestored();
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('the reported age is anchored to the last DELIVERY, not the fault '
        'onset', () async {
      // Found by an independent l10n reviewer reading the copy against the
      // model: a subscription drop noticed moments ago on a circle that has
      // been silent for half an hour used to be dated from the DROP, telling
      // the user their map was nearly fresh. The banner exists to stop the app
      // looking healthier than it is; it must never round that way.
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(lastPeerEventAt: _t0);

      h.advance(const Duration(minutes: 30));
      h.notifier.recordRelaySubscriptionLost();
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          _t0,
        ),
        reason: 'the last proven delivery predates the drop by 30 minutes, so '
            'it — not the drop — is what the age must be measured from',
      );
    });

    test('but the fault onset wins when it is the older of the two', () async {
      // The other direction: a delivery AFTER the onset cannot be used to
      // shorten the reported outage, or a single late arrival would reset it.
      final h = _Harness();
      h.notifier.recordRelaySubscriptionLost();
      final onset = h.now;
      h.advance(const Duration(minutes: 5));
      h.health.stored = CircleHealthTimestamps(lastPeerEventAt: h.now);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          onset,
        ),
      );
    });

    group('a paused verdict is dated by the direction that failed', () {
      // Peers' locations arriving say nothing about this device's going out,
      // nor its acks about what arrives: the other direction's newer instant
      // is planted in each, and must not be used.
      final older = _t0.subtract(const Duration(hours: 1));
      final newer = _t0.subtract(const Duration(minutes: 1));

      test('a held send, by the publish ack only', () async {
        final h = _Harness()
          ..health.stored = CircleHealthTimestamps(
            lastPublishAckedAt: older,
            lastPeerEventAt: newer,
          );
        h.service.recoveryCause = CircleRecoveryCause.storedInput;
        h.notifier.recordDeferredSend('010203');
        h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
        expect(
          await h.settle(),
          SharingHealth.paused(SharingPausedReason.storedInput, older),
        );

        h.health.stored = CircleHealthTimestamps(lastPeerEventAt: newer);
        expect(
          await h.settle(),
          SharingHealth.paused(
            SharingPausedReason.storedInput,
            _t0,
            ageProvable: false,
          ),
        );
      });

      test('a lost subscription, by the peer instant only', () async {
        final h = _Harness()
          ..health.stored = CircleHealthTimestamps(
            lastPublishAckedAt: newer,
            lastPeerEventAt: older,
          );
        h.notifier.recordRelaySubscriptionLost();
        h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
        expect(
          await h.settle(),
          SharingHealth.paused(
            SharingPausedReason.receiveSubscriptionLost,
            older,
          ),
        );

        h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: newer);
        expect(
          await h.settle(),
          SharingHealth.paused(
            SharingPausedReason.receiveSubscriptionLost,
            _t0,
            ageProvable: false,
          ),
        );
      });

      test('a dropped connection, by the older of the two, and only when both '
          'exist', () async {
        final h = _Harness()
          ..health.stored = CircleHealthTimestamps(
            lastPublishAckedAt: newer,
            lastPeerEventAt: older,
          );
        await h.settle();
        h.container.read(syncStatusProvider.notifier).onStatus(
          FfiSyncStatusReason.disconnected,
        );
        h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
        expect(
          await h.settle(),
          SharingHealth.paused(SharingPausedReason.relayDisconnected, older),
        );

        h.health.stored = CircleHealthTimestamps(
          lastPublishAckedAt: older,
          lastPeerEventAt: newer,
        );
        expect(
          await h.settle(),
          SharingHealth.paused(SharingPausedReason.relayDisconnected, older),
        );

        h.health.stored = CircleHealthTimestamps(lastPeerEventAt: newer);
        expect(
          await h.settle(),
          SharingHealth.paused(
            SharingPausedReason.relayDisconnected,
            _t0,
            ageProvable: false,
          ),
        );
      });
    });

    test('a named cause wins over an inferred publish failure', () async {
      // Both are true; the banner must name what it actually knows, because
      // that is what Units A/B/C repair.
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.service.recoveryCause = CircleRecoveryCause.storedInput;
      h.notifier.recordDeferredSend('010203');

      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));
      expect(
        (await h.settle()).state,
        SharingHealthState.paused,
        reason: 'the inferred publishFailing verdict must not mask the '
            'engine-reported cause',
      );
    });
  });

  group("the core's causes: read, ranked first, never re-derived", () {
    test('a core cause outranks every inferred verdict; a failed read falls '
        'back to the engine state, then to inference', () async {
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(lastPublishAckedAt: _t0);
      h.notifier.recordRelaySubscriptionLost();
      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));
      h.service.recoveryCause = CircleRecoveryCause.removalUnmade;
      h.notices.notes = const [ChangeNoteFfi.queuedRemovalDropped];
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.removalUnmade,
        reason: 'publish silence and a lost subscription both stand, and the '
            "core's cause still wins",
      );

      h.service.recoveryError = StateError('store down');
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
        reason: 'a live circle whose read failed falls back to inference',
      );
    });

    test('a failed read of a circle the list reads as halted says halted',
        () async {
      final h = _Harness(
        circle: TestCircleFactory.createCircle(
          mlsGroupId: const [1, 2, 3],
          nostrGroupId: const [9, 9],
          engineState: CircleEngineState.unrecoverable,
        ),
      )..service.recoveryError = StateError('store down');
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.circleUnrecoverable,
      );
    });

    test('durable causes show at once, transient ones after the window, and '
        "a transient one the user's own action made at once", () async {
      for (final cause in const [
        CircleRecoveryCause.leaving,
        CircleRecoveryCause.stalled,
        CircleRecoveryCause.unrecoverable,
      ]) {
        final h = _Harness()..service.recoveryCause = cause;
        expect(
          (await h.settle()).pausedReason,
          pausedReasonOf(cause),
          reason: '$cause stands until the circle itself changes',
        );
      }

      final transient = _Harness()
        ..service.recoveryCause = CircleRecoveryCause.awaitingRelays;
      expect(
        await transient.settle(),
        SharingHealth.healthy,
        reason: 'a pending change inside the window is ordinary work',
      );
      transient.advance(
        kSharingFaultConfirmationWindow + const Duration(seconds: 1),
      );
      expect(
        (await transient.settle()).pausedReason,
        SharingPausedReason.awaitingRelays,
      );

      final byUser = _Harness()
        ..service.recoveryCause = CircleRecoveryCause.awaitingRelays;
      byUser.notifier.recordDeferredSend('010203', byUser: true);
      expect(
        (await byUser.settle()).pausedReason,
        SharingPausedReason.awaitingRelays,
        reason: 'the user just asked for this change: its wait shows now',
      );
    });

    test('a collision with no recorded note reads routingUnchecked, never '
        'the destructive reading', () async {
      final h = _Harness()
        ..service.recoveryCause = CircleRecoveryCause.routingCollision;
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.routingUnchecked,
        reason: 'a store that cannot answer reads as collided, unpersisted',
      );

      h.notices.notes = const [ChangeNoteFfi.routingCollision];
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.routingCollision,
      );

      final capture = LogCapture.install();
      h.notices.error = StateError(
        'group 010203 at wss://planted.example npub1planted',
      );
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.routingUnchecked,
        reason: 'an unreadable notice is not the recorded note',
      );
      capture
        ..assertContains('[SharingHealth] notice read failed: StateError')
        ..assertNoNeedles(['010203', 'wss://planted.example', 'npub1planted']);
    });

    test('a dropped removal with no notice saying so points to the member '
        'list', () async {
      final h = _Harness()
        ..service.recoveryCause = CircleRecoveryCause.removalUnmade;
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.removalUnmadeUntold,
      );
      h.notices.notes = const [ChangeNoteFfi.queuedRemovalDropped];
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.removalUnmade,
      );
    });

    test("the both-way causes date by the older instant: the collision's "
        '"last known good"', () async {
      final older = _t0.subtract(const Duration(hours: 2));
      final newer = _t0.subtract(const Duration(minutes: 1));
      final h = _Harness()
        ..service.recoveryCause = CircleRecoveryCause.routingCollision
        ..health.stored = CircleHealthTimestamps(
          lastPublishAckedAt: newer,
          lastPeerEventAt: older,
        );
      h.notices.notes = const [ChangeNoteFfi.routingCollision];
      expect(
        await h.settle(),
        SharingHealth.paused(SharingPausedReason.routingCollision, older),
        reason: 'a collision stops receiving too: the newer ack must not '
            'shorten the outage',
      );
    });

    test('a circle that ended, halted or is being left carries no age',
        () async {
      for (final cause in const [
        CircleRecoveryCause.disbanded,
        CircleRecoveryCause.unrecoverable,
        CircleRecoveryCause.leaving,
      ]) {
        final h = _Harness()
          ..service.recoveryCause = cause
          ..health.stored = CircleHealthTimestamps(
            lastPublishAckedAt: _t0.subtract(const Duration(hours: 1)),
            lastPeerEventAt: _t0.subtract(const Duration(hours: 1)),
          );
        expect((await h.settle()).ageProvable, isFalse, reason: '$cause');
      }
    });

    test('every verdict names the circle it was derived for', () async {
      final h = _Harness()
        ..service.recoveryCause = CircleRecoveryCause.stalled;
      await h.settle();
      expect(
        h.container.read(sharingHealthProvider).circleKey,
        sharingCircleKey(_circle()),
      );
    });

    test('a burst of refreshes during a read costs at most one more read',
        () async {
      final h = _Harness();
      await h.settle();
      final before = h.service.recoveryReads.length;
      h.health.gate = Completer<void>();
      final first = h.notifier.refresh();
      await pumpEventQueue();
      final joined = [for (var i = 0; i < 5; i++) h.notifier.refresh()];
      h.health.gate = null;
      h.health.releaseGate();
      await Future.wait([first, ...joined]);
      expect(
        h.service.recoveryReads.length - before,
        2,
        reason: 'one read in flight and one after it, not one per publish',
      );
    });
  });

  group('a selected circle disbanded in place', () {
    test('re-derives without a tick when the circle list changes', () async {
      final live = TestCircleFactory.createCircle(
        mlsGroupId: const [1, 2, 3],
        nostrGroupId: const [9, 9],
      );
      final list = StateProvider<List<Circle>>((ref) => [live]);
      final service = _CoreRecovery();
      final foreground = ValueNotifier<bool>(true);
      addTearDown(foreground.dispose);
      final container = ProviderContainer(
        overrides: [
          sharingHealthClockProvider.overrideWithValue(() => _t0),
          circleHealthServiceProvider.overrideWithValue(_FakeHealthService()),
          circleServiceProvider.overrideWithValue(service),
          changeNoticesProvider.overrideWithValue(
            fakeChangeNotices(FakeNoticeManager()),
          ),
          circlesProvider.overrideWith((ref) async => ref.watch(list)),
          identityProvider.overrideWith((ref) async => _identity),
          memberLocationsProvider.overrideWith(
            (ref) async => const <MemberLocation>[],
          ),
          sharingHealthForegroundProvider.overrideWithValue(foreground),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedCircleIdProvider.notifier).state =
          live.mlsGroupId;
      container.listen(sharingHealthProvider, (_, _) {});
      await container.read(circlesProvider.future);
      await pumpEventQueue();
      expect(
        container.read(sharingHealthProvider),
        SharingHealth.healthy.about(sharingCircleKey(live)),
      );

      // A group update re-reads the list: the same circle (equal by id, so
      // the selection does not notify), now disbanded.
      container.read(list.notifier).state = [
        TestCircleFactory.createCircle(
          mlsGroupId: const [1, 2, 3],
          nostrGroupId: const [9, 9],
          engineState: CircleEngineState.disbanded,
        ),
      ];
      await container.read(circlesProvider.future);
      await pumpEventQueue();

      expect(
        container.read(sharingHealthProvider).pausedReason,
        SharingPausedReason.circleDisbanded,
        reason: 'no tick ran: the list change alone re-derived the verdict',
      );
    });
  });

  group('sharingHealthShownProvider', () {
    ProviderContainer shown({
      required SharingHealth health,
      LocationAccessStatus access = LocationAccessStatus.available,
      ClockSkewStatus clock = ClockSkewStatus.healthy,
    }) {
      final container = ProviderContainer(
        overrides: [
          sharingHealthProvider.overrideWith(() => _FixedHealth(health)),
          locationAccessProvider.overrideWith(() => _FixedAccess(access)),
          clockSkewProvider.overrideWithValue(clock),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('inferred verdicts read suppressed under a device banner; core '
        'causes never do', () {
      const skewed = ClockSkewStatus(
        signal: ClockSkewSignal.relayRejectedTimestamp,
      );
      for (final inferred in [
        SharingHealth.publishFailing(_t0),
        SharingHealth.receiveSilent(_t0),
        SharingHealth.paused(SharingPausedReason.relayDisconnected, _t0),
        SharingHealth.paused(SharingPausedReason.receiveSubscriptionLost, _t0),
        SharingHealth.healthy,
      ]) {
        final blocked = shown(
          health: inferred,
          access: LocationAccessStatus.serviceDisabled,
        ).read(sharingHealthShownProvider);
        expect(blocked.suppressed, isTrue, reason: '$inferred, access');
        expect(blocked.isStopped, isFalse);
        expect(blocked.isRecovered, isFalse, reason: 'never a recovery');
        expect(
          shown(health: inferred, clock: skewed)
              .read(sharingHealthShownProvider)
              .suppressed,
          isTrue,
          reason: '$inferred, clock',
        );
      }
      for (final reason in SharingPausedReason.values.where(
        (r) =>
            r != SharingPausedReason.relayDisconnected &&
            r != SharingPausedReason.receiveSubscriptionLost,
      )) {
        final verdict = shown(
          health: SharingHealth.paused(reason, _t0),
          access: LocationAccessStatus.serviceDisabled,
          clock: skewed,
        ).read(sharingHealthShownProvider);
        expect(verdict.suppressed, isFalse, reason: '$reason');
        expect(verdict.isStopped, isTrue);
      }
    });
  });

  group('a live-sync session still held', () {
    test('a stop that left the guard held is said after the window; a stop '
        'or a start that released it clears it', () async {
      final h = _Harness();
      h.notifier.recordStopOutcome(LiveSyncStopOutcome.stillHolding);
      expect(await h.settle(), SharingHealth.healthy, reason: 'window');
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        (await h.settle()).pausedReason,
        SharingPausedReason.sessionStillHeld,
      );

      h.notifier.recordStopOutcome(LiveSyncStopOutcome.stopped);
      expect(await h.settle(), SharingHealth.healthy);
    });
  });

  group('clearing semantics', () {
    test('an acknowledged publish clears a held send for that circle',
        () async {
      // An ACK is proof nothing held the circle's sends, so a held send clears
      // itself instead of relying on a caller remembering to: the cause the
      // core still reads is dated afresh, and waits out the window again.
      final h = _Harness();
      h.service.recoveryCause = CircleRecoveryCause.departureDue;
      h.notifier.recordDeferredSend('010203');
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      h.notifier.recordPublishOutcome('010203', acked: true);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('an UNACKED publish does not clear a held send', () async {
      // Anti-vacuity for the above: only the acked branch clears.
      final h = _Harness();
      h.service.recoveryCause = CircleRecoveryCause.departureDue;
      h.notifier.recordDeferredSend('010203');
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      h.notifier.recordPublishOutcome('010203', acked: false);
      expect(
        (await h.settle()).state,
        SharingHealthState.paused,
        reason: 'a failed publish is not evidence the defer was resolved',
      );
    });

    test('a peer event does NOT clear a lost relay subscription', () async {
      // Locations reach this device over any relay in the pool, so one
      // arriving proves nothing about the subscription that was dropped. Only
      // Unit C, which re-issues the REQ, may clear it.
      final h = _Harness();
      h.notifier.recordRelaySubscriptionLost();
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      h.health.stored = CircleHealthTimestamps(lastPeerEventAt: h.now);

      expect(
        (await h.settle()).state,
        SharingHealthState.paused,
        reason: 'only recordRelaySubscriptionRestored clears this',
      );
    });
  });

  group('the re-derivation tick', () {
    test('is suspended while the app is not in the foreground', () async {
      // It exists to keep a BANNER honest, and a backgrounded app has no
      // banner on screen. At 72 s it would also fire about twice as often as
      // the app's own background wake cadence.
      final h = _Harness();
      await h.settle();
      expect(h.notifier.isTickingForTest, isTrue, reason: 'anti-vacuity');

      h.foreground.value = false;
      expect(h.notifier.isTickingForTest, isFalse);
    });

    test('re-arms AND re-derives immediately on return to the foreground',
        () async {
      // A returning user must see a fresh verdict, not the one that was true
      // when they left.
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(lastPublishAckedAt: _t0);
      await h.settle();
      h.foreground.value = false;

      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));
      h.foreground.value = true;
      expect(h.notifier.isTickingForTest, isTrue);

      // The re-derivation the resume kicked off is async; let it land.
      await Future<void>.delayed(Duration.zero);
      expect(
        h.container.read(sharingHealthProvider),
        SharingHealth.publishFailing(_t0).about(sharingCircleKey(_circle())),
      );
    });
  });

  group('concurrent derivations', () {
    test('a late completion never overwrites a newer verdict', () async {
      // The verdict comes from async reads, so a refresh asked while another
      // is in flight must not end on the older answer. It joins the one in
      // flight and one more derivation runs after it, so the newest read is
      // the last one published.
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(lastPublishAckedAt: _t0);
      await h.settle();
      final published = <SharingHealth>[];
      h.container.listen(sharingHealthProvider, (_, next) {
        published.add(next);
      });

      // Refresh A observes a stale ack (would report publishFailing) but is
      // held mid-read; refresh B is asked once a fresh ack is stored.
      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));
      h.health.gate = Completer<void>();
      final slow = h.notifier.refresh();
      await pumpEventQueue();

      h.health.gate = null;
      h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: h.now);
      final newer = h.notifier.refresh();
      h.health.releaseGate();
      await Future.wait([slow, newer]);

      expect(
        h.container.read(sharingHealthProvider),
        SharingHealth.healthy.about(sharingCircleKey(_circle())),
        reason: 'the newest read is the verdict',
      );
      expect(
        published.where((v) => v.state == SharingHealthState.publishFailing),
        isEmpty,
        reason: 'the stale in-flight derivation must be dropped, not published',
      );
    });

    test('a container disposed while a derivation reads raises nothing and '
        'sets no verdict', () async {
      final recorder = _VerdictRecorder();
      final h = _Harness(observers: [recorder])
        ..health.stored = CircleHealthTimestamps(lastPeerEventAt: _t0);
      expect(await h.settle(), SharingHealth.healthy, reason: 'premise');

      // Held mid-read on evidence that, landed, would say receiveSilent.
      h
        ..advance(kReceiveSilenceThreshold + const Duration(seconds: 1))
        ..health.gate = Completer<void>();
      final held = h.notifier.refresh();
      await pumpEventQueue();
      recorder.verdicts.clear();

      h.container.dispose();
      h.health.releaseGate();

      await expectLater(held, completes);
      expect(recorder.verdicts, isEmpty);
    });
  });

  group('an identity change (the model invalidated)', () {
    // Riverpod keeps the notifier instance across an invalidation, so what
    // the last lifecycle latched survives into the next build unless reset.
    test('derives again: a verdict lands after the rebuild', () async {
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(lastPublishAckedAt: _t0);
      expect(await h.settle(), SharingHealth.healthy, reason: 'premise');

      h.container.invalidate(sharingHealthProvider);
      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));

      expect(await h.settle(), SharingHealth.publishFailing(_t0));
    });

    test("carries none of the last identity's evidence", () async {
      final h = _Harness();
      await h.settle();
      h.notifier
        ..recordRelaySubscriptionLost()
        ..recordStopOutcome(LiveSyncStopOutcome.stillHolding)
        ..recordPublishOutcome(sharingCircleKey(_circle()), acked: false);

      h.container.invalidate(sharingHealthProvider);
      h.advance(kSharingFaultConfirmationWindow * 2);

      expect(await h.settle(), SharingHealth.healthy);
    });
  });

  group('scope', () {
    test('a circle the user has not accepted is not judged', () async {
      final h = _Harness(
        circle: TestCircleFactory.createCircle(
          nostrGroupId: const [9, 9],
          membershipStatus: MembershipStatus.pending,
          members: [TestCircleFactory.createMember(pubkey: _peerPubkey)],
        ),
      )..health.stored = CircleHealthTimestamps(lastPeerEventAt: _t0);

      h.advance(kReceiveSilenceThreshold * 2);
      expect(await h.settle(), SharingHealth.healthy);
    });
  });

  group('AppForegroundNotifier — the real one', () {
    // Every other test in this file overrides `sharingHealthForegroundProvider`
    // with a plain `ValueNotifier`, so the production class had no coverage at
    // all. It previously used `AppLifecycleListener`, which ASSERTS on
    // transitions it judges illegal — `paused` → `resumed` among them — before
    // it ever calls `onStateChange`. That is an ordinary Android resume, the
    // E2E lanes run debug builds, and this app already has one recorded
    // incident of a mid-sequence assert taking down startup.
    testWidgets('survives paused → resumed, the transition that used to assert',
        (tester) async {
      final notifier = AppForegroundNotifier();
      addTearDown(notifier.dispose);
      expect(notifier.value, isTrue, reason: 'foreground until told otherwise');

      final binding = WidgetsBinding.instance
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(notifier.value, isFalse);

      // The load-bearing line: under `AppLifecycleListener` this throws
      // "Invalid state transition from AppLifecycleState.paused to
      // AppLifecycleState.resumed" and the test fails right here.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(notifier.value, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tracks every other state as not-foreground', (tester) async {
      final notifier = AppForegroundNotifier();
      addTearDown(notifier.dispose);
      final binding = WidgetsBinding.instance;

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        expect(notifier.value, isFalse, reason: 'ted as background: $state');
      }
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(notifier.value, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stops observing on dispose', (tester) async {
      // A disposed `ChangeNotifier` THROWS when written to, so an observer left
      // registered turns the next lifecycle callback into a crash.
      final notifier = AppForegroundNotifier();
      notifier.dispose();

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('thresholds are derived from the publish cadence', () {
    // Two halves, because neither alone is honest. The RELATIONS below hold
    // just as well against a hand-typed `Duration(seconds: 336)` — both sides
    // read the same compiled constants — so the derivation itself is pinned by
    // a source scan in `test/lints/sharing_health_recording_sites_test.dart`.
    // The numbers below then pin what those relations currently evaluate to,
    // so a cadence change is a deliberate, visible edit rather than a silent
    // shift in when the user is warned.
    test('each threshold is the stated multiple of the cadence', () {
      expect(kLocationMessageRetention.inSeconds,
          kLocationPublishMaxInterval.inSeconds + 2 * kTtlNetworkBufferSeconds);
      expect(kSharingFaultConfirmationWindow, kLocationPublishMaxInterval);
      expect(kPublishSilenceThreshold, kLocationPublishMaxInterval * 2);
      expect(
        kReceiveSilenceThreshold,
        kLocationPublishMaxInterval * 2 + kLocationMessageRetention,
      );
      expect(kSharingHealthTick, kLocationPublishMinInterval);
    });

    test('and those relations currently evaluate to these windows', () {
      expect(kLocationMessageRetention, const Duration(seconds: 228));
      expect(kPublishSilenceThreshold, const Duration(seconds: 336));
      expect(kReceiveSilenceThreshold, const Duration(seconds: 564));
      expect(kSharingFaultConfirmationWindow, const Duration(seconds: 168));
      expect(kSharingHealthTick, const Duration(seconds: 72));
    });
  });

  group('rendering', () {
    test('a verdict states how long ago the fault began, never when', () {
      // The fault's start is an instant on the publish/receive plane, so it
      // reaches a log as an offset only (Rule 15).
      final since = DateTime.now().subtract(const Duration(seconds: 90));
      final rendered = SharingHealth.publishFailing(since).toString();

      expect(rendered, isNot(contains(since.toIso8601String())));
      expect(rendered, isNot(contains(since.year.toString())));
      expect(rendered, matches(RegExp(r'since: t-\d+s')));
      expect(rendered, contains('publishFailing'));
    });

    test('a healthy verdict has no start to state', () {
      expect(SharingHealth.healthy.toString(), contains('since: -'));
    });
  });
}

/// A model whose verdict is fixed.
class _FixedHealth extends SharingHealthNotifier {
  _FixedHealth(this._health);

  final SharingHealth _health;

  @override
  SharingHealth build() => _health;
}

/// A location-access state that never probes.
class _FixedAccess extends LocationAccessNotifier {
  _FixedAccess(this._status);

  final LocationAccessStatus _status;

  @override
  LocationAccessStatus build() => _status;
}
