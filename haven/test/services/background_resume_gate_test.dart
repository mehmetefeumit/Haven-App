/// The gate on every start of the Android foreground service that Haven's UI
/// did not make — a boot or update start, a sticky restart after the process
/// was killed (owner-directed 2026-11-26, OD-R2/OD-R3).
///
/// Each case is a promise: sharing resumes without the user opening Haven only
/// with consent to the CURRENT background disclosure, a foreground location
/// grant and, on Android 11+, "Allow all the time"; otherwise the user gets the
/// resume notice instead of a silently broken service; a logged-out or
/// opted-out user gets neither a service nor a notice.
library;

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/background_resume_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';

const _channel = MethodChannel('haven.app/background_location');

/// An npub-shaped identifier planted where a careless log line would print it.
const _planted =
    'npub1qe3e5wrvnsgpggtkytxteaqfprz0rgxr8c3l34kk3a9t7e2l3acslezefe';

/// Sharing on, both disclosures accepted at the current version.
Map<String, Object> _consented({int version = kBackgroundDisclosureVersion}) =>
    {
      kBackgroundSharingKey: true,
      kLocationDisclosureAcceptedKey: true,
      kLocationDisclosureBackgroundAcceptedKey: true,
      kLocationDisclosureBackgroundVersionKey: version,
    };

/// The foreground-service engine's half of the channel, as Android 11+ with
/// every grant held unless a case says otherwise.
class _NativeSide {
  _NativeSide() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          if (throwOnNotice && call.method == 'postResumeNotice') {
            throw PlatformException(code: 'denied', message: _planted);
          }
          if (throwOnStatus && call.method == 'status') {
            throw PlatformException(code: 'unavailable', message: _planted);
          }
          return switch (call.method) {
            'status' => {
              'required': required,
              'granted': granted,
              'optionLabel': 'Allow all the time',
              'foregroundGranted': foreground,
            },
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null),
    );
  }

  bool required = true;
  bool granted = true;
  bool foreground = true;
  bool throwOnStatus = false;
  bool throwOnNotice = false;
  final List<String> calls = [];

  int get notices => calls.where((m) => m == 'postResumeNotice').length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decideSystemResume', () {
    SystemResumeDecision decide({
      bool sharingOn = true,
      bool? foregroundAccepted = true,
      bool? backgroundAccepted = true,
      int? acceptedVersion = kBackgroundDisclosureVersion,
      bool locationGranted = true,
      bool backgroundRequired = true,
      bool backgroundGranted = true,
    }) => decideSystemResume(
      sharingOn: sharingOn,
      foregroundAccepted: foregroundAccepted,
      backgroundAccepted: backgroundAccepted,
      acceptedVersion: acceptedVersion,
      locationGranted: locationGranted,
      backgroundRequired: backgroundRequired,
      backgroundGranted: backgroundGranted,
    );

    test('every condition held resumes sharing', () {
      expect(decide(), SystemResumeDecision.start);
    });

    test('sharing off stops without a notice, whatever else holds', () {
      expect(decide(sharingOn: false), SystemResumeDecision.stop);
      expect(
        decide(sharingOn: false, acceptedVersion: null),
        SystemResumeDecision.stop,
      );
    });

    test('a version-1 acceptance is not consent to resume', () {
      expect(decide(acceptedVersion: null), SystemResumeDecision.notify);
      expect(decide(acceptedVersion: 1), SystemResumeDecision.notify);
    });

    test('each disclosure flag is required, and a missing one refuses', () {
      expect(decide(foregroundAccepted: null), SystemResumeDecision.notify);
      expect(decide(backgroundAccepted: false), SystemResumeDecision.notify);
    });

    test('no foreground location grant notifies', () {
      expect(decide(locationGranted: false), SystemResumeDecision.notify);
    });

    test('Android 11+ without "Allow all the time" notifies', () {
      expect(decide(backgroundGranted: false), SystemResumeDecision.notify);
    });

    test('Android 10 needs no background grant', () {
      expect(
        decide(backgroundRequired: false, backgroundGranted: false),
        SystemResumeDecision.start,
      );
    });
  });

  group('SystemStartGate.check', () {
    late _NativeSide native;
    late int stops;
    late bool identity;
    late bool identityThrows;

    setUp(() {
      native = _NativeSide();
      stops = 0;
      identity = true;
      identityThrows = false;
    });

    SystemStartGate gate() => SystemStartGate(
      identityStored: () async {
        if (identityThrows) {
          throw PlatformException(code: 'keystore', message: _planted);
        }
        return identity;
      },
      stopService: () async => stops++,
    );

    test('a start Haven made is never judged here', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await gate().check(TaskStarter.developer), isNull);
      expect(native.calls, isEmpty);
      expect(stops, 0);
    });

    test('a system start with every condition held runs', () async {
      SharedPreferences.setMockInitialValues(_consented());
      expect(await gate().check(TaskStarter.system), isNull);
      expect(native.notices, 0);
      expect(stops, 0);
    });

    test('the first update under version 2: notice, then stop', () async {
      SharedPreferences.setMockInitialValues(_consented(version: 1));
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.notPermitted,
      );
      expect(native.notices, 1);
      expect(stops, 1);
    });

    test('Android 11-13 without "Allow all the time" (a blind sticky '
        'restart): notice, then stop', () async {
      SharedPreferences.setMockInitialValues(_consented());
      native.granted = false;
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.notPermitted,
      );
      expect(native.notices, 1);
      expect(stops, 1);
    });

    test('no foreground grant: notice, then stop', () async {
      SharedPreferences.setMockInitialValues(_consented());
      native.foreground = false;
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.notPermitted,
      );
      expect(native.notices, 1);
      expect(stops, 1);
    });

    test('Android 10 runs on the foreground grant alone', () async {
      SharedPreferences.setMockInitialValues(_consented());
      native
        ..required = false
        ..granted = false;
      expect(await gate().check(TaskStarter.system), isNull);
      expect(stops, 0);
    });

    test('sharing off: stop without a notice', () async {
      SharedPreferences.setMockInitialValues(
        _consented()..[kBackgroundSharingKey] = false,
      );
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.sharingOff,
      );
      expect(native.notices, 0);
      expect(stops, 1);
    });

    test('no stored identity: stop without a notice', () async {
      SharedPreferences.setMockInitialValues(_consented(version: 1));
      identity = false;
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.noIdentity,
      );
      expect(
        native.notices,
        0,
        reason: 'a logged-out user is not asked to resume sharing',
      );
      expect(stops, 1);
    });

    test('a channel that fails reads as every grant missing', () async {
      SharedPreferences.setMockInitialValues(_consented());
      native.throwOnStatus = true;
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.notPermitted,
      );
      expect(native.notices, 1);
      expect(stops, 1);
    });

    test('an identity read that fails refuses with the notice', () async {
      SharedPreferences.setMockInitialValues(_consented());
      identityThrows = true;
      expect(
        await gate().check(TaskStarter.system),
        SystemStartRefusal.notPermitted,
      );
      expect(native.notices, 1);
      expect(stops, 1);
    });

    // Rule 15, for every line the gate can write: each names its reason and
    // nothing else, whatever identifiers sit in the preferences or in the
    // errors it catches.
    const pubkey =
        'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
    const latitude = '52.520008';
    const geohash = 'u33dc0cpke7v';
    final planted = <String, Object>{
      'haven.test.planted_pubkey': pubkey,
      'haven.test.planted_latitude': latitude,
      'haven.test.planted_geohash': geohash,
    };
    final cases =
        <
          String,
          ({
            Map<String, Object> prefs,
            void Function() arrange,
            List<String> markers,
          })
        >{
          'not permitted': (
            prefs: _consented(version: 1),
            arrange: () {},
            markers: ['[BackgroundTask] system start refused: not permitted'],
          ),
          'sharing off': (
            prefs: _consented()..[kBackgroundSharingKey] = false,
            arrange: () {},
            markers: ['[BackgroundTask] system start refused: sharing off'],
          ),
          'no identity': (
            prefs: _consented(),
            arrange: () => identity = false,
            markers: ['[BackgroundTask] system start refused: no identity'],
          ),
          'a failed status read': (
            prefs: _consented(),
            arrange: () => native.throwOnStatus = true,
            markers: [
              '[BackgroundResume] status failed: PlatformException',
              '[BackgroundTask] system start refused: not permitted',
            ],
          ),
          'a failed notice': (
            prefs: _consented(version: 1),
            arrange: () => native.throwOnNotice = true,
            markers: [
              '[BackgroundResume] notice failed: PlatformException',
              '[BackgroundTask] system start refused: not permitted',
            ],
          ),
          'a failed identity read': (
            prefs: _consented(),
            arrange: () => identityThrows = true,
            markers: [
              '[BackgroundResume] identity read failed: PlatformException',
              '[BackgroundTask] system start refused: not permitted',
            ],
          ),
        };
    for (final MapEntry(key: name, value: c) in cases.entries) {
      test('Rule 15: $name logs its reason and no identifier', () async {
        SharedPreferences.setMockInitialValues({...c.prefs, ...planted});
        c.arrange();
        final logs = LogCapture.install();

        await gate().check(TaskStarter.system);

        c.markers.forEach(logs.assertContains);
        logs.assertNoNeedles([pubkey, latitude, geohash, _planted]);
      });
    }
  });

  group('BackgroundLocationTaskHandler.onStart', () {
    late _NativeSide native;
    late int stops;

    setUp(() {
      native = _NativeSide();
      stops = 0;
    });

    BackgroundLocationTaskHandler handler() => BackgroundLocationTaskHandler()
      ..overrideSystemStartGate = SystemStartGate(
        identityStored: () async => true,
        stopService: () async => stops++,
      );

    test('a refused system start does no work at all', () async {
      SharedPreferences.setMockInitialValues(_consented(version: 1));
      final logs = LogCapture.install();

      await handler().onStart(DateTime(2026), TaskStarter.system);

      expect(native.notices, 1);
      expect(stops, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(kBackgroundIdleKey),
        isNull,
        reason:
            'the idle flag is the first thing a running task writes; '
            'a refused start must stop before it',
      );
      expect(
        logs.joined,
        isNot(contains('onStart FAILED')),
        reason: 'a refused start must never reach the Rust bridge',
      );
    });

    test('a permitted system start goes on to the bring-up', () async {
      SharedPreferences.setMockInitialValues(_consented());
      final logs = LogCapture.install();

      await handler().onStart(DateTime(2026), TaskStarter.system);

      expect(native.notices, 0);
      expect(stops, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kBackgroundIdleKey), isFalse);
      // No Rust library on a test host: the bring-up fails at the bridge,
      // which proves the gate let the start through to it.
      logs.assertContains('[BackgroundTask] onStart FAILED');
    });
  });
}
