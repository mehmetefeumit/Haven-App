/// Tests for [IosLocationSource] — the iOS native location owner's Dart half.
///
/// Two halves, tested separately because they fail in different ways:
///
/// * The **profile controller** is the phase's only non-trivial logic and the
///   one part no Swift test can reach (nothing runs Swift unit tests in CI).
///   It is pure — every transition takes the fix's own timestamp, and the
///   deadline is a function of a passed-in `now` — so the state machine is
///   pinned on fixed [DateTime]s with no clock, no timer and no channel.
/// * The **channel half** is pinned against a fake native side, because there
///   is no macOS machine here: the wire shape these tests assert IS the
///   contract `HavenLocationStreamHandler.swift` implements.
///
/// The load-bearing promise across both is ONLY-BEST: a fix delivered under
/// the 100 m tier feeds the movement detector and the freshness bound and
/// nothing else. It must never be emitted, never be cached, and therefore
/// never reach the motion trigger (whose sole input is this stream).
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/ios_location_source.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/utils/geo_distance.dart';

/// Base instant for every controller test. Fixed, never `DateTime.now()`:
/// the controller has no clock of its own, and a wall-clock base would make
/// the dwell assertions depend on how long the test took to run.
final DateTime t0 = DateTime.utc(2026, 9, 4, 12);

/// The event channel's name and codec, needed to push envelopes at the binary
/// messenger the way the engine does.
const String kEventChannelName = 'haven.app/ios_location_stream/events';
const MethodCodec kWireCodec = StandardMethodCodec();

/// ~100.1 m north on the mean-radius sphere the haversine assumes.
const double kDegreesPer100m = 0.0009;

IosFix fixAt(
  Duration offset, {
  double latitude = 51.5,
  double longitude = -0.12,
  double accuracy = 5,
  IosLocationProfile profile = IosLocationProfile.best,
}) => IosFix(
  latitude: latitude,
  longitude: longitude,
  timestamp: t0.add(offset),
  accuracy: accuracy,
  profile: profile,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // The pure profile controller
  // ==========================================================================
  group('IosProfileController', () {
    late IosProfileController controller;

    setUp(() => controller = IosProfileController());

    /// Backgrounds the controller at [t0] and delivers one Best fix — the
    /// state every stationary test starts from: an anchor exists and the
    /// dwell is running.
    void background() {
      controller
        ..onForeground(foregrounded: false, now: t0)
        ..onFix(fixAt(Duration.zero));
    }

    /// A latitude [metres] north of every fix helper's default, on the same
    /// mean-radius sphere `haversineMeters` assumes.
    double latNorthOf(double metres) => 51.5 + kDegreesPer100m * metres / 100;

    test('a foregrounded device is always at Best', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));
      expect(controller.profile, IosLocationProfile.hundredMeters);

      controller.onForeground(
        foregrounded: true,
        now: t0.add(kStationaryDwell),
      );

      expect(controller.profile, IosLocationProfile.best);
      expect(
        controller.nextDeadline(t0.add(kStationaryDwell)),
        isNull,
        reason: 'the confirm deadline only bounds the coarse profile; leaving '
            'it armed would escalate a profile that is already Best',
      );
    });

    test('backgrounded and still for kStationaryDwell drops to HundredMeters',
        () {
      background();

      // One second short of the dwell: still Best.
      controller.onFix(fixAt(kStationaryDwell - const Duration(seconds: 1)));
      expect(controller.profile, IosLocationProfile.best);

      controller.onFix(fixAt(kStationaryDwell));
      expect(controller.profile, IosLocationProfile.hundredMeters);
      expect(
        controller.confirmedAt,
        t0.add(kStationaryDwell),
        reason: 'the fix that drops the profile is itself the first '
            'confirmation, or the deadline would fire against nothing',
      );
    });

    test('a >=100 m step inside the dwell restarts it', () {
      background();

      // 90 s in, the device moves 100 m. The dwell must restart from THERE,
      // so the original 120 s boundary passes at Best.
      controller
        ..onFix(
          fixAt(
            const Duration(seconds: 90),
            latitude: 51.5 + kDegreesPer100m,
          ),
        )
        ..onFix(fixAt(kStationaryDwell, latitude: 51.5 + kDegreesPer100m));
      expect(controller.profile, IosLocationProfile.best);

      controller.onFix(
        fixAt(
          const Duration(seconds: 90) + kStationaryDwell,
          latitude: 51.5 + kDegreesPer100m,
        ),
      );
      expect(controller.profile, IosLocationProfile.hundredMeters);
    });

    test('a sub-100 m wander never holds the session at Best', () {
      background();
      // Wi-Fi jitter: ~20 m either way, repeatedly, for the whole dwell.
      for (var s = 10; s <= kStationaryDwell.inSeconds; s += 10) {
        controller.onFix(
          fixAt(
            Duration(seconds: s),
            latitude: 51.5 + ((s ~/ 10).isEven ? 0.00018 : -0.00018),
          ),
        );
      }
      expect(
        controller.profile,
        IosLocationProfile.hundredMeters,
        reason: 'noise below the motion-trigger granularity must not hold the '
            'GPS receiver at Best all night',
      );
    });

    test('stationary: a <=100 m-accuracy fix >=100 m away switches to Best',
        () {
      background();
      controller
        ..onFix(fixAt(kStationaryDwell))
        ..onFix(
          fixAt(
            kStationaryDwell + const Duration(seconds: 30),
            latitude: 51.5 + kDegreesPer100m,
            accuracy: kStationaryConfirmMaxAccuracyMeters,
            profile: IosLocationProfile.hundredMeters,
          ),
        );

      expect(controller.profile, IosLocationProfile.best);
      expect(
        controller.anchor?.latitude,
        51.5,
        reason: 'the anchor stays the last BEST fix until a new Best fix '
            'replaces it — a 100 m-tier coordinate must never become the '
            'reference the next displacement is measured from',
      );
    });

    test('stationary: a fix inside 100 m only confirms', () {
      background();
      controller
        ..onFix(fixAt(kStationaryDwell))
        ..onFix(
          fixAt(
            kStationaryDwell + const Duration(seconds: 30),
            latitude: 51.5 + 0.0005, // ~55 m
            accuracy: 40,
            profile: IosLocationProfile.hundredMeters,
          ),
        );

      expect(controller.profile, IosLocationProfile.hundredMeters);
      expect(
        controller.confirmedAt,
        t0.add(kStationaryDwell + const Duration(seconds: 30)),
      );
    });

    test('a fix coarser than kStationaryConfirmMaxAccuracyMeters neither '
        'confirms nor moves', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));
      final confirmedAtDrop = controller.confirmedAt;

      controller
        // Coarse AND far away: it may not move the profile.
        ..onFix(
          fixAt(
            kStationaryDwell + const Duration(seconds: 10),
            latitude: 51.5 + kDegreesPer100m * 5,
            accuracy: kStationaryConfirmMaxAccuracyMeters + 1,
            profile: IosLocationProfile.hundredMeters,
          ),
        )
        // Coarse AND close: it may not confirm either.
        ..onFix(
          fixAt(
            kStationaryDwell + const Duration(seconds: 20),
            accuracy: kStationaryConfirmMaxAccuracyMeters + 1,
            profile: IosLocationProfile.hundredMeters,
          ),
        );

      expect(controller.profile, IosLocationProfile.hundredMeters);
      expect(
        controller.confirmedAt,
        confirmedAtDrop,
        reason: 'a fix that cannot resolve 100 m cannot vouch for 100 m of '
            'stillness; letting it re-arm the deadline would hold the coarse '
            'profile indefinitely on evidence that proves nothing',
      );
    });

    test('a confirmed anchor is never further from a confirming fix than '
        'kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters',
        () {
      background();
      controller.onFix(fixAt(kStationaryDwell));
      final anchor = controller.anchor!;
      var confirmations = 0;

      // Sweep the admissible confirming space: every accuracy the rule
      // accepts, at distances either side of the trigger threshold.
      for (final accuracy in <double>[
        1,
        50,
        kStationaryConfirmMaxAccuracyMeters,
      ]) {
        for (var step = 1; step <= 4; step++) {
          final fix = fixAt(
            kStationaryDwell + Duration(seconds: 10 * step),
            latitude: 51.5 + kDegreesPer100m * step * 0.4,
            accuracy: accuracy,
            profile: IosLocationProfile.hundredMeters,
          );
          final before = controller.confirmedAt;
          controller.onFix(fix);
          if (controller.confirmedAt == before) continue;
          confirmations++;
          // It confirmed, so the coordinate the publish path keeps serving is
          // the anchor. The worst case for how far the device really is from
          // it is the trigger granularity plus the fix's own error radius.
          expect(
            haversineMeters(
                  anchor.latitude,
                  anchor.longitude,
                  fix.latitude,
                  fix.longitude,
                ) +
                fix.accuracy,
            lessThan(
              kMotionTriggerDistanceMeters +
                  kStationaryConfirmMaxAccuracyMeters,
            ),
          );
        }
      }
      expect(
        confirmations,
        greaterThan(0),
        reason: 'a sweep that confirmed nothing would assert nothing',
      );
    });

    test('no admissible confirming fix can vouch for a 200 m displacement',
        () {
      // The bound `kStationaryConfirmMaxAccuracyMeters` documents, asserted in
      // BOTH directions and on the device's TRUE position rather than on the
      // one a fix reports. `horizontalAccuracy` is a ~68 % confidence radius
      // and not a limit, so the worst case is a fix biased the full radius
      // back towards the anchor: what a confirmation can hide is its reported
      // distance plus its own accuracy, and while it vouches for the anchor
      // that IS the error published to peers. The sweep above asserts the
      // bound for the confirmations it happens to produce; the direction the
      // promise needs is the other one — 200 m is never confirmable at all.
      var confirmations = 0;
      var escalations = 0;
      for (final accuracy in <double>[
        1,
        50,
        kStationaryConfirmMaxAccuracyMeters,
      ]) {
        for (var reported = 0.0; reported <= 300; reported += 5) {
          final swept = IosProfileController()
            ..onForeground(foregrounded: false, now: t0)
            ..onFix(fixAt(Duration.zero))
            ..onFix(fixAt(kStationaryDwell));
          final sweptAnchor = swept.anchor!;
          final fix = fixAt(
            kStationaryDwell + const Duration(seconds: 10),
            latitude: latNorthOf(reported),
            accuracy: accuracy,
            profile: IosLocationProfile.hundredMeters,
          );

          swept.onFix(fix);

          final hiddenDisplacement =
              haversineMeters(
                sweptAnchor.latitude,
                sweptAnchor.longitude,
                fix.latitude,
                fix.longitude,
              ) +
              fix.accuracy;
          const bound =
              kMotionTriggerDistanceMeters +
              kStationaryConfirmMaxAccuracyMeters;
          // THIS fix confirmed — not merely "the confirmation changed", which
          // is also true of the escalation branch, where it becomes null.
          if (swept.confirmedAt == fix.timestamp) {
            confirmations++;
            expect(
              hiddenDisplacement,
              lessThan(bound),
              reason: 'the anchor goes on being served while this fix vouches '
                  'for it, so what the confirmation can hide is exactly what '
                  'the publish path gets wrong',
            );
          } else {
            escalations++;
            expect(
              swept.profile,
              IosLocationProfile.best,
              reason: 'an admissible fix that did not confirm found the device '
                  'gone, and must hand the decision back to GPS',
            );
          }
          if (hiddenDisplacement >= bound) {
            expect(
              swept.profile,
              IosLocationProfile.best,
              reason: '200 m of real displacement is not confirmable however '
                  'the error radius is spent — that is the whole claim',
            );
          }
        }
      }
      expect(confirmations, greaterThan(0));
      expect(
        escalations,
        greaterThan(0),
        reason: 'a sweep in which everything confirmed would never reach the '
            'converse assertion',
      );
    });

    test('a confirmation chain cannot hold the anchor past '
        'kStationaryAnchorMaxAge', () {
      // The chain is what removes the ceiling on a published coordinate's age
      // — the wire carries the publish instant, never the fix's — so the cap
      // is the ceiling that replaces it, and it fires while confirmations are
      // still arriving, which the kStationaryConfirmMaxAge deadline never can.
      background();
      controller.onFix(fixAt(kStationaryDwell));
      final pinned = controller.anchor!;

      IosFix confirmAt(Duration anchorAge) => fixAt(
        kStationaryDwell + anchorAge,
        accuracy: kStationaryConfirmMaxAccuracyMeters,
        profile: IosLocationProfile.hundredMeters,
      );

      // One confirmation a minute: the 84 s deadline is re-armed for ever, so
      // nothing but the anchor's own age is left to escalate this session.
      for (
        var seconds = 60;
        seconds <= kStationaryAnchorMaxAge.inSeconds;
        seconds += 60
      ) {
        final age = Duration(seconds: seconds);
        controller.onFix(confirmAt(age));
        expect(
          controller.profile,
          IosLocationProfile.hundredMeters,
          reason: 'the anchor is $seconds s old, still inside the cap',
        );
        expect(controller.confirmedAt, t0.add(kStationaryDwell + age));
      }

      controller.onFix(
        confirmAt(kStationaryAnchorMaxAge + const Duration(seconds: 1)),
      );

      expect(controller.profile, IosLocationProfile.best);
      expect(
        controller.confirmedAt,
        isNull,
        reason: 'the confirmation is what extends the freshness window past '
            'the fix time, so an anchor that may no longer be served must '
            'stop carrying one',
      );
      expect(
        controller.anchor,
        same(pinned),
        reason: 'the coordinate itself stays until a Best fix replaces it; '
            'what ended is its right to be published',
      );
    });

    test('the anchor cap becomes the earlier deadline as it approaches', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));

      expect(
        controller.nextDeadline(t0.add(kStationaryDwell)),
        kStationaryConfirmMaxAge,
        reason: 'a fresh anchor has five minutes to run, so the confirm '
            'window is the binding one',
      );

      for (final seconds in <int>[240, 290]) {
        final at = t0.add(kStationaryDwell + Duration(seconds: seconds));
        controller.onFix(
          fixAt(
            kStationaryDwell + Duration(seconds: seconds),
            profile: IosLocationProfile.hundredMeters,
          ),
        );
        expect(
          controller.nextDeadline(at),
          kStationaryAnchorMaxAge - Duration(seconds: seconds),
          reason: 'the confirmation buys a fresh 84 s window, but the anchor '
              'has only ${300 - seconds} s of life left and the timer has to '
              'be armed for the EARLIER of the two',
        );
      }
    });

    test('a cap escalation keeps the dwell, so one Best fix returns the '
        'session to the coarse tier', () {
      // What the cap COSTS: one Best delivery, not one dwell. The
      // confirmations established that the device is still and only the
      // coordinate aged out, so the dwell is left running and the next Best
      // fix drops the session straight back — the difference between ~1 % and
      // ~29 % of the time at Best for a stationary device. Both duties are
      // ESTIMATED from the cycle arithmetic (see [kStationaryAnchorMaxAge]);
      // no device has measured a profile duty, and none can while there is no
      // iPhone (`docs/POWER_EFFICIENCY_PLAN.md` §2.5).
      background();
      controller.onFix(fixAt(kStationaryDwell));
      final expiry = kStationaryDwell + kStationaryAnchorMaxAge;
      controller
        ..onFix(
          fixAt(
            expiry - const Duration(seconds: 20),
            accuracy: 50,
            profile: IosLocationProfile.hundredMeters,
          ),
        )
        ..onDeadline(t0.add(expiry));

      expect(controller.profile, IosLocationProfile.best);
      expect(controller.confirmedAt, isNull);

      controller.onFix(fixAt(expiry + const Duration(seconds: 2)));

      expect(
        controller.profile,
        IosLocationProfile.hundredMeters,
        reason: 'a dwell restart here would re-learn, at Best, the stillness '
            'the confirmations had already established',
      );
      expect(
        controller.anchor!.timestamp,
        t0.add(expiry + const Duration(seconds: 2)),
      );
      expect(
        controller.confirmedAt,
        t0.add(expiry + const Duration(seconds: 2)),
      );
    });

    test('a coarse fix biased inside its own error radius pins the anchor '
        'only until the cap, and the fix that forces finds the move', () {
      // The hole the cap closes. horizontalAccuracy is a confidence radius,
      // not a limit, so a 100 m-accurate fix reported 99 m from the anchor can
      // be a device 199 m away: admissible, confirming, and wrong. Nothing in
      // the confirm rule can ever notice — the bias is inside the radius the
      // rule accepts — so before the cap that chain had no end.
      background();
      controller.onFix(fixAt(kStationaryDwell));
      final stale = controller.anchor!;
      final biased = latNorthOf(99);
      final truth = latNorthOf(199);

      for (var seconds = 60; seconds <= 300; seconds += 60) {
        controller.onFix(
          fixAt(
            kStationaryDwell + Duration(seconds: seconds),
            latitude: biased,
            accuracy: kStationaryConfirmMaxAccuracyMeters,
            profile: IosLocationProfile.hundredMeters,
          ),
        );
        expect(controller.profile, IosLocationProfile.hundredMeters);
        expect(controller.anchor, same(stale));
      }

      expect(
        controller.nextDeadline(
          t0.add(kStationaryDwell + kStationaryAnchorMaxAge),
        ),
        Duration.zero,
        reason: 'five minutes of confirmations that each re-armed the 84 s '
            'window leave the anchor cap as the only thing due',
      );
      controller.onDeadline(t0.add(kStationaryDwell + kStationaryAnchorMaxAge));
      expect(controller.profile, IosLocationProfile.best);

      // GPS truth, at last: 199 m is past the trigger, so this is a MOVE.
      final movedAt =
          kStationaryDwell +
          kStationaryAnchorMaxAge +
          const Duration(seconds: 2);
      controller.onFix(fixAt(movedAt, latitude: truth));

      expect(controller.anchor!.latitude, truth);
      expect(controller.profile, IosLocationProfile.best);
      controller.onFix(
        fixAt(
          movedAt + kStationaryDwell - const Duration(seconds: 1),
          latitude: truth,
        ),
      );
      expect(
        controller.profile,
        IosLocationProfile.best,
        reason: 'the escalation found a real displacement, so the coarse tier '
            'has to be re-earned with a full dwell — the cap escalation only '
            'skips that when GPS agrees the device never moved',
      );
    });

    test('no confirmation for kStationaryConfirmMaxAge escalates to Best and '
        'restarts the dwell', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));

      expect(
        controller.nextDeadline(t0.add(kStationaryDwell)),
        kStationaryConfirmMaxAge,
      );
      expect(
        controller.nextDeadline(
          t0.add(kStationaryDwell + const Duration(seconds: 30)),
        ),
        kStationaryConfirmMaxAge - const Duration(seconds: 30),
      );

      final deadline = t0.add(kStationaryDwell + kStationaryConfirmMaxAge);
      controller.onDeadline(deadline);

      expect(controller.profile, IosLocationProfile.best);
      expect(controller.nextDeadline(deadline), isNull);

      // The dwell restarts from the escalation: a Best fix arriving one second
      // short of a full dwell later must NOT drop the profile again, or the
      // session would flap Best/100 m every 84 s in poor signal.
      controller.onFix(
        fixAt(
          kStationaryDwell +
              kStationaryConfirmMaxAge +
              kStationaryDwell -
              const Duration(seconds: 1),
        ),
      );
      expect(controller.profile, IosLocationProfile.best);
    });

    test('a confirming fix re-arms the deadline', () {
      background();
      controller
        ..onFix(fixAt(kStationaryDwell))
        ..onFix(
          fixAt(
            kStationaryDwell + const Duration(seconds: 60),
            profile: IosLocationProfile.hundredMeters,
          ),
        );

      expect(
        controller.nextDeadline(
          t0.add(kStationaryDwell + const Duration(seconds: 60)),
        ),
        kStationaryConfirmMaxAge,
      );
    });

    test('an overdue deadline is due now, never negative', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));

      expect(
        controller.nextDeadline(
          t0.add(kStationaryDwell + kStationaryConfirmMaxAge * 2),
        ),
        Duration.zero,
      );
    });

    test('resume from stationary returns Best immediately', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));
      expect(controller.profile, IosLocationProfile.hundredMeters);

      controller.onForeground(
        foregrounded: true,
        now: t0.add(kStationaryDwell + const Duration(seconds: 1)),
      );

      expect(controller.profile, IosLocationProfile.best);
    });

    test('the anchor is only ever a Best-profile fix', () {
      background();
      final anchor = controller.anchor;
      expect(anchor?.profile, IosLocationProfile.best);

      // A 100 m-tier fix arriving while the profile is still Best (the tier
      // race: it was computed before the switch) may not become the anchor.
      controller.onFix(
        fixAt(
          const Duration(seconds: 5),
          latitude: 51.5 + kDegreesPer100m * 3,
          profile: IosLocationProfile.hundredMeters,
        ),
      );

      expect(controller.anchor, same(anchor));
      expect(controller.profile, IosLocationProfile.best);
    });

    test('a fix stamped before the switch to Best is not the anchor', () {
      // The Dart mirror of the native `bestSince` rule: the native side tags
      // such a fix `hundredMeters` precisely so ONE predicate decides on both
      // sides of the channel. Dart must honour the tag rather than re-deriving
      // the tier from the accuracy value, which would need a second clock.
      background();
      controller
        ..onFix(fixAt(kStationaryDwell))
        // A displacement moves the profile back to Best...
        ..onFix(
          fixAt(
            kStationaryDwell + const Duration(seconds: 10),
            latitude: 51.5 + kDegreesPer100m,
            profile: IosLocationProfile.hundredMeters,
          ),
        );
      expect(controller.profile, IosLocationProfile.best);
      final anchor = controller.anchor;

      // ...and the first delivery after the switch is a fix computed under the
      // OLD tier, tagged accordingly however precise it looks.
      controller.onFix(
        fixAt(
          kStationaryDwell + const Duration(seconds: 11),
          latitude: 51.5 + kDegreesPer100m * 4,
          accuracy: 3,
          profile: IosLocationProfile.hundredMeters,
        ),
      );

      expect(controller.anchor, same(anchor));
    });

    test('reset returns to the Best start state', () {
      background();
      controller
        ..onFix(fixAt(kStationaryDwell))
        ..reset();

      expect(controller.profile, IosLocationProfile.best);
      expect(controller.anchor, isNull);
      expect(controller.confirmedAt, isNull);
      expect(controller.nextDeadline(t0.add(kStationaryDwell)), isNull);
    });

    test('forgetAnchor drops the anchor and restarts the dwell at Best', () {
      background();
      controller.onFix(fixAt(kStationaryDwell));
      expect(controller.profile, IosLocationProfile.hundredMeters);
      expect(controller.anchor, isNotNull);

      controller.forgetAnchor(t0.add(kStationaryDwell));

      expect(
        controller.anchor,
        isNull,
        reason: 'the anchor is a third full-precision coordinate, and it '
            'must go wherever the native and Dart caches of the same fix go',
      );
      expect(controller.confirmedAt, isNull);
      expect(
        controller.profile,
        IosLocationProfile.best,
        reason: 'with no anchor the coarse tier can neither confirm '
            'stillness nor measure a displacement, so it decides nothing',
      );

      // The dwell RESTARTED rather than being cleared: `reset()` leaves it
      // null, and only a backgrounding transition re-arms it — which a
      // session that is already backgrounded will never see again, stranding
      // it at Best for the rest of its life.
      controller.onFix(fixAt(kStationaryDwell * 2));
      expect(controller.profile, IosLocationProfile.hundredMeters);
    });

    test('a never-backgrounded session has no dwell to expire', () {
      // `movedAt` is seeded by the backgrounding transition, so a session that
      // has only ever been foregrounded cannot drop the tier on the strength
      // of a dwell that never started.
      controller
        ..onFix(fixAt(Duration.zero))
        ..onFix(fixAt(kStationaryDwell * 3));

      expect(controller.profile, IosLocationProfile.best);
    });
  });

  // ==========================================================================
  // The channel half
  // ==========================================================================
  group('MethodChannelIosLocationSource', () {
    late MethodChannelIosLocationSource source;
    late List<MethodCall> methodCalls;
    late List<Object?> listenArguments;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// `EventChannel` sends its own `listen`/`cancel` as method calls over a
    /// channel of the same name.
    const eventControlChannel = MethodChannel(kEventChannelName);

    setUp(() {
      source = MethodChannelIosLocationSource();
      methodCalls = <MethodCall>[];
      listenArguments = <Object?>[];
    });

    tearDown(() {
      messenger
        ..setMockMethodCallHandler(
          MethodChannelIosLocationSource.methodChannel,
          null,
        )
        ..setMockMethodCallHandler(eventControlChannel, null);
    });

    /// Installs the fake native side.
    ///
    /// Hand-rolled rather than `setMockStreamHandler`: that helper owns an
    /// intermediate `StreamController` and registers `addTearDown(sub.cancel)`
    /// on it, so a handler installed inside a `fakeAsync` body leaves the
    /// teardown awaiting a future scheduled in a zone that no longer runs.
    /// Pushing envelopes straight at the binary messenger has neither problem
    /// and is exactly what the engine does.
    void installNative({Future<Object?>? Function(MethodCall)? onMethod}) {
      messenger
        ..setMockMethodCallHandler(
          MethodChannelIosLocationSource.methodChannel,
          (call) async {
            methodCalls.add(call);
            return onMethod == null ? null : await onMethod(call);
          },
        )
        ..setMockMethodCallHandler(eventControlChannel, (call) async {
          if (call.method == 'listen') listenArguments.add(call.arguments);
          return null;
        });
    }

    /// Delivers one event to the framework exactly as the engine would.
    void emit(Object? event) => unawaited(
      messenger.handlePlatformMessage(
        kEventChannelName,
        kWireCodec.encodeSuccessEnvelope(event),
        null,
      ),
    );

    void emitError(String code) => unawaited(
      messenger.handlePlatformMessage(
        kEventChannelName,
        kWireCodec.encodeErrorEnvelope(code: code),
        null,
      ),
    );

    void emitEndOfStream() => unawaited(
      messenger.handlePlatformMessage(kEventChannelName, null, null),
    );

    /// The wire map `HavenLocationStreamHandler.didUpdateLocations` builds.
    Map<Object?, Object?> wireFix({
      required DateTime timestamp,
      double latitude = 51.5,
      double longitude = -0.12,
      double accuracy = 5,
      String profile = 'best',
    }) => <Object?, Object?>{
      'lat': latitude,
      'lon': longitude,
      'tsMs': timestamp.millisecondsSinceEpoch,
      'acc': accuracy,
      'alt': 12.0,
      'speed': 0.0,
      'course': 90.0,
      'profile': profile,
    };

    List<String> profilesRequested() => methodCalls
        .where((c) => c.method == 'setProfile')
        .map((c) => c.arguments! as String)
        .toList();

    /// Runs [body] with a live session and a fake clock whose instant is what
    /// every wire fix is stamped with, so the confirm deadline the controller
    /// computes from a fix timestamp and the timer the class arms from
    /// `DateTime.now()` cannot disagree.
    void withSession(
      void Function(FakeAsync async, List<Position> emitted) body, {
      bool backgrounded = true,
    }) {
      fakeAsync((async) {
        installNative();
        final emitted = <Position>[];
        final sub = source
            .positions(allowsBackgroundLocationUpdates: true)
            .listen(emitted.add, onError: (_) {});
        async.flushMicrotasks();
        if (backgrounded) {
          source.onForeground(foregrounded: false);
          async.flushMicrotasks();
        }
        body(async, emitted);
        unawaited(sub.cancel());
        async.flushMicrotasks();
      }, initialTime: t0);
    }

    /// Pushes one fix stamped at the fake clock's current instant.
    void deliver(
      FakeAsync async, {
      double latitude = 51.5,
      double accuracy = 5,
      String profile = 'best',
    }) {
      emit(
        wireFix(
          timestamp: clock.now(),
          latitude: latitude,
          accuracy: accuracy,
          profile: profile,
        ),
      );
      async.flushMicrotasks();
    }

    /// Drives the session from a cold start to the coarse profile.
    void goStationary(FakeAsync async) {
      deliver(async);
      async.elapse(kStationaryDwell);
      deliver(async);
    }

    /// The tier the FAKE NATIVE SIDE is running at: Best until a `setProfile`
    /// moves it. CoreLocation tags a fix with the tier the MANAGER is on, not
    /// the tier Dart believes it asked for, so a desync between the two is
    /// only visible through a delivery that honours this.
    String nativeTier() {
      final requested = profilesRequested();
      return requested.isEmpty ? 'best' : requested.last;
    }

    /// Pushes one fix stamped at the fake clock's instant and tagged with the
    /// tier the native side is actually running at.
    void deliverAtNativeTier(FakeAsync async, {double latitude = 51.5}) =>
        deliver(async, latitude: latitude, profile: nativeTier());

    test('positions passes allowsBackgroundLocationUpdates as the listen '
        'argument', () {
      fakeAsync((async) {
        installNative();
        final sub = source
            .positions(allowsBackgroundLocationUpdates: true)
            .listen((_) {});
        async.flushMicrotasks();

        expect(listenArguments, [
          <String, Object?>{'allowsBackgroundLocationUpdates': true},
        ]);
        unawaited(sub.cancel());
        async.flushMicrotasks();
      }, initialTime: t0);
    });

    test('the toggle-off session asks for no background capability', () {
      fakeAsync((async) {
        installNative();
        final sub = source
            .positions(allowsBackgroundLocationUpdates: false)
            .listen((_) {});
        async.flushMicrotasks();

        expect(listenArguments, [
          <String, Object?>{'allowsBackgroundLocationUpdates': false},
        ]);
        unawaited(sub.cancel());
        async.flushMicrotasks();
      }, initialTime: t0);
    });

    test('only Best-profile fixes are emitted', () {
      withSession((async, emitted) {
        deliver(async);
        deliver(async, latitude: 52, profile: 'hundredMeters');

        expect(emitted.map((p) => p.latitude), [51.5]);
      });
    });

    test('a 100 m-tier fix that moves the device still reaches no subscriber',
        () {
      // The only-Best rule at its sharpest: this fix DOES change the profile
      // (it is >= 100 m from the anchor at an accuracy the rule accepts) and
      // it still must not be emitted — the motion trigger's sole input is this
      // stream, so an emission here would publish a coordinate the app asked
      // for at a coarsened tier.
      withSession((async, emitted) {
        goStationary(async);
        deliver(
          async,
          latitude: 51.5 + kDegreesPer100m,
          accuracy: 60,
          profile: 'hundredMeters',
        );

        expect(emitted.map((p) => p.latitude), [51.5, 51.5]);
        expect(
          profilesRequested(),
          ['hundredMeters', 'best'],
          reason: 'the displacement must still be SEEN — it is what returns '
              'the session to Best so the next Best fix can publish it',
        );
      });
    });

    test('an emitted fix carries the platform fields the publish path uses',
        () {
      withSession((async, emitted) {
        deliver(async);

        final position = emitted.single;
        expect(position.latitude, 51.5);
        expect(position.longitude, -0.12);
        expect(position.accuracy, 5);
        expect(position.altitude, 12.0);
        expect(position.speed, 0.0);
        expect(position.heading, 90.0);
        expect(
          position.timestamp.millisecondsSinceEpoch,
          clock.now().millisecondsSinceEpoch,
        );
      });
    });

    test('a malformed event is dropped without ending the session', () {
      withSession((async, emitted) {
        emit(<Object?, Object?>{'lat': 51.5});
        async.flushMicrotasks();
        deliver(async);

        expect(emitted, hasLength(1));
      });
    });

    test('a background_start_refused error pushed through the sink surfaces '
        'as a stream error', () {
      // Per the EventChannel contract an exception thrown by the platform
      // `listen` call is reported to FlutterError and NEVER added to the
      // stream, so the native refusal has to travel through the SINK. A
      // returned FlutterError would leave every subscriber waiting forever.
      fakeAsync((async) {
        installNative();
        final errors = <Object>[];
        var closed = false;
        final sub = source
            .positions(allowsBackgroundLocationUpdates: true)
            .listen((_) {}, onError: errors.add, onDone: () => closed = true);
        async.flushMicrotasks();

        // Exactly what the native refusal path emits: the error, then the end
        // of the stream.
        emitError('background_start_refused');
        async.flushMicrotasks();
        emitEndOfStream();
        async.flushMicrotasks();

        expect(errors, hasLength(1));
        expect(
          (errors.single as PlatformException).code,
          'background_start_refused',
        );
        expect(closed, isTrue);
        unawaited(sub.cancel());
        async.flushMicrotasks();
      }, initialTime: t0);
    });

    test('a native error resets the profile controller', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(source.lastConfirmedAt, isNotNull);

        emitError('denied');
        async.flushMicrotasks();

        expect(
          source.lastConfirmedAt,
          isNull,
          reason: 'a dead session may not keep vouching for the freshness of '
              'a coordinate nothing is refreshing any more',
        );
      });
    });

    test('a transient native error does not strand the session at the coarse '
        'tier', () {
      // CoreLocation reports a failure WITHOUT stopping the manager, so the
      // session survives one — at whatever tier it had reached. The reset
      // returns the CONTROLLER to Best; unless that is written through, every
      // later fix arrives tagged `hundredMeters`, the only-Best rule drops it,
      // and no transition is left to repair the desync. One
      // kCLErrorLocationUnknown indoors used to end background sharing until
      // the user reopened the app.
      withSession((async, emitted) {
        goStationary(async);
        expect(emitted, hasLength(2));
        expect(profilesRequested(), ['hundredMeters']);

        emitError('failed');
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 5));
        deliverAtNativeTier(async);
        async.elapse(const Duration(seconds: 5));
        deliverAtNativeTier(async);

        expect(
          emitted,
          hasLength(4),
          reason: 'the session kept running and kept delivering, but nothing '
              'it delivered was publishable: the manager stayed at 100 m '
              'while the controller believed it had asked for Best',
        );
      });
    });

    test('clearing the last Best fix drops the anchor too', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(profilesRequested(), ['hundredMeters']);
        expect(source.lastConfirmedAt, isNotNull);

        unawaited(source.clearLastBestFix());
        async.flushMicrotasks();

        expect(
          methodCalls.map((c) => c.method),
          contains('clearLastBestFix'),
          reason: 'the native copy of the fix must go with the Dart ones',
        );
        expect(
          source.lastConfirmedAt,
          isNull,
          reason: 'a confirmation vouches for the anchor; a dropped anchor '
              'is vouched for by nothing',
        );
        expect(
          profilesRequested(),
          ['hundredMeters', 'best'],
          reason: 'an anchorless coarse tier can neither confirm stillness '
              'nor measure a displacement, so the session must leave it',
        );

        // And the anchor itself is GONE, not merely unreported: a fix 100 m
        // from where it stood no longer reads as a displacement, so the dwell
        // that started at the clear runs all the way to the coarse tier.
        async.elapse(const Duration(seconds: 60));
        deliver(async, latitude: 51.5 + kDegreesPer100m);
        async.elapse(kStationaryDwell - const Duration(seconds: 60));
        deliver(async, latitude: 51.5 + kDegreesPer100m);

        expect(
          profilesRequested(),
          ['hundredMeters', 'best', 'hundredMeters'],
          reason: 'a surviving anchor would have read the 100 m step as '
              'motion and restarted the dwell',
        );
      });
    });

    test('the profile is requested exactly once per transition', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(profilesRequested(), ['hundredMeters']);

        // Confirmations while still: no further request.
        async.elapse(const Duration(seconds: 5));
        deliver(async, profile: 'hundredMeters');
        async.elapse(const Duration(seconds: 5));
        deliver(async, profile: 'hundredMeters');

        expect(profilesRequested(), ['hundredMeters']);
      });
    });

    test('the confirm timer escalates to Best when nothing confirms', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(profilesRequested(), ['hundredMeters']);

        async
          ..elapse(kStationaryConfirmMaxAge - const Duration(seconds: 1))
          ..flushMicrotasks();
        expect(profilesRequested(), ['hundredMeters']);

        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        expect(profilesRequested(), ['hundredMeters', 'best']);
      });
    });

    test('a confirming fix pushes the escalation out', () {
      withSession((async, emitted) {
        goStationary(async);

        async.elapse(kStationaryConfirmMaxAge - const Duration(seconds: 10));
        deliver(async, profile: 'hundredMeters');
        async
          ..elapse(kStationaryConfirmMaxAge - const Duration(seconds: 1))
          ..flushMicrotasks();

        expect(profilesRequested(), ['hundredMeters']);
      });
    });

    test('the anchor cap escalates a session confirmations would otherwise '
        'hold coarse for ever', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(profilesRequested(), ['hundredMeters']);
        final emittedAtDrop = emitted.length;

        // One confirming fix a minute re-arms the 84 s deadline every time, so
        // the timer this session ends up firing can only be the anchor cap's.
        for (var age = 60; age <= 240; age += 60) {
          async.elapse(const Duration(seconds: 60));
          deliverAtNativeTier(async);
          expect(
            profilesRequested(),
            ['hundredMeters'],
            reason: 'the anchor is $age s old and confirmed; nothing is due',
          );
        }

        async
          ..elapse(const Duration(seconds: 59))
          ..flushMicrotasks();
        expect(profilesRequested(), ['hundredMeters']);

        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        expect(
          profilesRequested(),
          ['hundredMeters', 'best'],
          reason: 'the last confirmation was 60 s ago, so the 84 s deadline '
              'is not due for another 24 s — this is the anchor cap, five '
              'minutes after the fix it escalates for',
        );

        // And the escalation costs ONE delivery: the Best fix it went to get
        // re-anchors the session and drops it straight back.
        deliverAtNativeTier(async);
        expect(profilesRequested(), ['hundredMeters', 'best', 'hundredMeters']);
        expect(
          emitted.length,
          emittedAtDrop + 1,
          reason: 'the fresh Best fix is publishable, and is the only thing '
              'this whole excursion emitted',
        );
      });
    });

    test('cancelling the session cancels the confirm timer', () {
      fakeAsync((async) {
        installNative();
        final sub = source
            .positions(allowsBackgroundLocationUpdates: true)
            .listen((_) {});
        async.flushMicrotasks();
        source.onForeground(foregrounded: false);
        async.flushMicrotasks();
        goStationary(async);

        unawaited(sub.cancel());
        async
          ..flushMicrotasks()
          ..elapse(kStationaryConfirmMaxAge * 3)
          ..flushMicrotasks();

        expect(
          profilesRequested(),
          ['hundredMeters'],
          reason: 'a timer outliving its session would write accuracy to a '
              'manager that is no longer updating, and would keep the isolate '
              'waking on a schedule nothing consumes',
        );
        expect(source.lastConfirmedAt, isNull);
      }, initialTime: t0);
    });

    test('foregrounding a stationary session asks for Best', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(profilesRequested(), ['hundredMeters']);

        source.onForeground(foregrounded: true);
        async.flushMicrotasks();

        expect(profilesRequested(), ['hundredMeters', 'best']);
      });
    });

    test('lastConfirmedAt tracks the coarse confirmations nothing emits', () {
      withSession((async, emitted) {
        goStationary(async);
        expect(
          source.lastConfirmedAt?.millisecondsSinceEpoch,
          clock.now().millisecondsSinceEpoch,
        );

        async.elapse(const Duration(seconds: 40));
        deliver(async, profile: 'hundredMeters');

        expect(
          source.lastConfirmedAt?.millisecondsSinceEpoch,
          clock.now().millisecondsSinceEpoch,
          reason: 'the freshness bound the publish path reads is the ONLY '
              'thing a coarse fix feeds; if it did not move, a stationary user '
              'would fall back to a one-shot every 168 s',
        );
        expect(emitted, hasLength(2));
      });
    });

    // The two maps below carry every key `HavenLocationStreamHandler.status()`
    // emits and nothing else, and between them give each key a value pair no
    // other key shares — so a parse that dropped a key (falling back) or read
    // a neighbour's key reddens at least one of them. Three of the six flags
    // share a `false` fallback, which one posture alone cannot separate.
    test('status parses the native map', () async {
      // Confirmed Always, background-capable, foregrounded: no bar asked for.
      installNative(
        onMethod: (call) async => <String, Object?>{
          'running': true,
          'allowsBackgroundLocationUpdates': true,
          'showsBackgroundLocationIndicator': false,
          'profile': 'hundredMeters',
          'authorization': 'authorizedAlways',
          'backgrounded': false,
        },
      );

      final status = await source.status();

      expect(status.running, isTrue);
      expect(status.allowsBackgroundLocationUpdates, isTrue);
      expect(status.showsBackgroundLocationIndicator, isFalse);
      expect(status.profile, IosLocationProfile.hundredMeters);
      expect(status.authorization, 'authorizedAlways');
      expect(status.backgrounded, isFalse);
    });

    test('status reads every key from its own key', () async {
      // When-In-Use with background sharing off: the session runs, is NOT
      // background-capable, and the handler DOES ask for the bar — the
      // inverse posture on the flags the map above could not tell apart.
      installNative(
        onMethod: (call) async => <String, Object?>{
          'running': true,
          'allowsBackgroundLocationUpdates': false,
          'showsBackgroundLocationIndicator': true,
          'profile': 'best',
          'authorization': 'authorizedWhenInUse',
          'backgrounded': false,
        },
      );

      final status = await source.status();

      expect(status.running, isTrue);
      expect(status.allowsBackgroundLocationUpdates, isFalse);
      expect(status.showsBackgroundLocationIndicator, isTrue);
      expect(status.profile, IosLocationProfile.best);
      expect(status.authorization, 'authorizedWhenInUse');
      expect(status.backgrounded, isFalse);
    });

    test('status fails closed on a missing key', () async {
      installNative(
        onMethod: (call) async =>
            <String, Object?>{'authorization': 'authorizedAlways'},
      );

      final status = await source.status();

      expect(
        status.authorization,
        'authorizedAlways',
        reason: 'the one key that IS present must still be read, or the '
            'fallbacks below would be measuring an empty map',
      );
      expect(
        status.backgrounded,
        isTrue,
        reason: 'an unreadable lifecycle must count as backgrounded, or a '
            'relaunched process would start the doomed one-shot',
      );
      expect(status.running, isFalse);
      expect(status.allowsBackgroundLocationUpdates, isFalse);
      expect(status.showsBackgroundLocationIndicator, isFalse);
    });

    test('status fails closed on a wrong-typed key', () async {
      installNative(
        onMethod: (call) async => <String, Object?>{
          'running': true,
          'backgrounded': 'false',
          'profile': 42,
          'authorization': 42,
        },
      );

      final status = await source.status();

      expect(status.backgrounded, isTrue);
      expect(status.profile, IosLocationProfile.best);
      expect(
        status.authorization,
        'unknown',
        reason: 'the tier name is read straight out of the wire; anything '
            'that is not a string has to answer as unreadable',
      );
    });

    test('status fails closed on a PlatformException', () async {
      installNative(onMethod: (call) => throw PlatformException(code: 'boom'));

      final status = await source.status();

      expect(status.backgrounded, isTrue);
      expect(status.running, isFalse);
    });

    test('status fails closed when no native handler is registered', () async {
      final status = await source.status();

      expect(status.backgrounded, isTrue);
    });

    test('lastBestFix parses the native map', () async {
      final timestamp = DateTime.utc(2026, 9, 4, 12);
      installNative(onMethod: (call) async => wireFix(timestamp: timestamp));

      final fix = await source.lastBestFix();

      expect(fix, isNotNull);
      expect(fix!.latitude, 51.5);
      expect(fix.timestamp.toUtc(), timestamp);
    });

    test('lastBestFix is null when the native side holds nothing', () async {
      installNative();
      expect(await source.lastBestFix(), isNull);
    });

    test('lastBestFix is null on a platform failure', () async {
      installNative(onMethod: (call) => throw PlatformException(code: 'boom'));
      expect(await source.lastBestFix(), isNull);
    });

    test('clearLastBestFix invokes the channel', () async {
      installNative();

      await source.clearLastBestFix();

      expect(methodCalls.map((c) => c.method), contains('clearLastBestFix'));
    });

    test('clearLastBestFix survives a missing native handler', () async {
      // The opt-out and logout paths call it; neither may throw.
      await expectLater(source.clearLastBestFix(), completes);
    });
  });

  // ==========================================================================
  // The non-iOS stand-in
  // ==========================================================================
  group('NoopIosLocationSource', () {
    const source = NoopIosLocationSource();

    test('never emits, and never ENDS the stream either', () {
      fakeAsync((async) {
        var events = 0;
        var done = false;
        final sub = source
            .positions(allowsBackgroundLocationUpdates: true)
            .listen((_) => events++, onDone: () => done = true);
        async.elapse(const Duration(hours: 1));

        expect(events, 0);
        expect(
          done,
          isFalse,
          reason: 'a completed position stream reads as an outage to every '
              'listener, including the access watchdog',
        );
        unawaited(sub.cancel());
        async.flushMicrotasks();
      }, initialTime: t0);
    });

    test('reports no fix, no confirmation and a fail-closed status', () async {
      expect(await source.lastBestFix(), isNull);
      expect(source.lastConfirmedAt, isNull);
      await expectLater(source.clearLastBestFix(), completes);
      expect((await source.status()).backgrounded, isTrue);
    });
  });
}
