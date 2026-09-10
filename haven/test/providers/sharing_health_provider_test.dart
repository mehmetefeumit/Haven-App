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
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show FfiSyncStatusReason;
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';

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

/// Drives the model with an explicit clock the test moves by hand.
class _Harness {
  _Harness({Circle? circle, List<MemberLocation>? locations})
    : health = _FakeHealthService() {
    container = ProviderContainer(
      overrides: [
        sharingHealthClockProvider.overrideWithValue(() => now),
        circleHealthServiceProvider.overrideWithValue(health),
        selectedCircleProvider.overrideWithValue(circle ?? _circle()),
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
    return container.read(sharingHealthProvider);
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
      h.notifier.recordPublishOutcome('0909', acked: false);

      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        h.now.difference(_t0),
        lessThan(kPublishSilenceThreshold),
        reason: 'the slow route cannot have fired yet — otherwise this test '
            'would pass without the recorded outcome',
      );
      expect(await h.settle(), SharingHealth.publishFailing(_t0));
    });

    test('one unacked publish inside the confirmation window stays quiet',
        () async {
      // A single failed publish is a transient; only a run of them is a fault.
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('0909', acked: false);

      h.advance(kSharingFaultConfirmationWindow);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('an ack clears the failure run', () async {
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordPublishOutcome('0909', acked: false);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: h.now);
      h.notifier.recordPublishOutcome('0909', acked: true);

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
      h.notifier.recordPublishOutcome('0909', acked: false);

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
        SharingHealth.paused(SharingPausedReason.relayDisconnected, _t0),
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
        SharingHealth.paused(SharingPausedReason.relayDisconnected, _t0),
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
        SharingHealth.paused(SharingPausedReason.relayDisconnected, _t0),
      );

      h.advance(kSharingFaultConfirmationWindow * 10);
      expect(
        await h.settle(),
        SharingHealth.paused(SharingPausedReason.relayDisconnected, _t0),
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

      h.notifier.recordPublishOutcome('0909', acked: false);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect(
        await h.settle(),
        SharingHealth.healthy,
        reason: 'a paused engine derives nothing, in either direction',
      );

      status.onStatus(FfiSyncStatusReason.connected);
      expect(
        await h.settle(),
        SharingHealth.publishFailing(_t0),
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

    test('a deferred send (Unit B) is reported against its own circle',
        () async {
      final h = _Harness();
      h.notifier.recordDeferredSend('0909');
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      expect(
        await h.settle(),
        SharingHealth.paused(SharingPausedReason.sendDeferred, _t0),
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
      h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: h.now);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      expect(
        await h.settle(),
        SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          onset,
        ),
      );
    });

    test('a named cause wins over an inferred publish failure', () async {
      // Both are true; the banner must name what it actually knows, because
      // that is what Units A/B/C repair.
      final h = _Harness()..health.stored = CircleHealthTimestamps(
        lastPublishAckedAt: _t0,
      );
      h.notifier.recordDeferredSend('0909');

      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));
      expect(
        (await h.settle()).state,
        SharingHealthState.paused,
        reason: 'the inferred publishFailing verdict must not mask the '
            'engine-reported cause',
      );
    });
  });

  group('clearing semantics', () {
    test('an acknowledged publish clears a deferred send for that circle',
        () async {
      // An ACK is proof the engine encrypted and a relay kept it — exactly the
      // condition a deferred send says did not hold. Unit B's repair therefore
      // clears itself, instead of relying on a caller remembering to.
      final h = _Harness();
      h.notifier.recordDeferredSend('0909');
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      h.notifier.recordPublishOutcome('0909', acked: true);
      expect(await h.settle(), SharingHealth.healthy);
    });

    test('an UNACKED publish does not clear a deferred send', () async {
      // Anti-vacuity for the above: only the acked branch clears.
      final h = _Harness();
      h.notifier.recordDeferredSend('0909');
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      h.notifier.recordPublishOutcome('0909', acked: false);
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
        SharingHealth.publishFailing(_t0),
      );
    });
  });

  group('concurrent derivations', () {
    test('a late completion never overwrites a newer verdict', () async {
      // The verdict comes from an async storage read, so two overlapping
      // refreshes can complete out of order. Without a generation fence the
      // older answer wins simply by being slower.
      final h = _Harness()
        ..health.stored = CircleHealthTimestamps(lastPublishAckedAt: _t0);
      await h.settle();

      // Refresh A observes a stale ack (would report publishFailing) but is
      // held mid-read; refresh B then observes a fresh ack and completes first.
      h.advance(kPublishSilenceThreshold + const Duration(seconds: 1));
      h.health.gate = Completer<void>();
      final slow = h.notifier.refresh();

      h.health.gate = null;
      h.health.stored = CircleHealthTimestamps(lastPublishAckedAt: h.now);
      await h.notifier.refresh();
      expect(h.container.read(sharingHealthProvider), SharingHealth.healthy);

      h.health.releaseGate();
      await slow;

      expect(
        h.container.read(sharingHealthProvider),
        SharingHealth.healthy,
        reason: 'the stale in-flight derivation must be dropped, not published',
      );
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
}
