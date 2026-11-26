// The Dart half of the `haven.app/background_location` contract: what the
// Kotlin side answers, and what Haven makes of an answer it cannot read.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/services/android_background_location.dart';

import '../helpers/log_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    MethodChannelAndroidBackgroundLocation.channelName,
  );
  const api = MethodChannelAndroidBackgroundLocation();
  late List<String> calls;

  void answer(Object? Function(MethodCall call) reply) {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return reply(call);
        });
  }

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('the channel name is the one the Kotlin side registers', () {
    expect(
      MethodChannelAndroidBackgroundLocation.channelName,
      'haven.app/background_location',
    );
  });

  group('status', () {
    test('reads required, granted and the OS label', () async {
      answer(
        (_) => <String, Object?>{
          'required': true,
          'granted': false,
          'optionLabel': 'Allow all the time',
        },
      );
      final status = await api.status();
      expect(status.required, isTrue);
      expect(status.granted, isFalse);
      expect(status.optionLabel, 'Allow all the time');
      expect(status.missing, isTrue);
      expect(calls, ['status']);
    });

    test('Android 10 and below: nothing is missing', () async {
      answer((_) => <String, Object?>{'required': false, 'granted': false});
      final status = await api.status();
      expect(status.missing, isFalse);
      expect(status.granted, isTrue);
    });

    // Fail closed: an over-warning, never a false "you're fine" to a user
    // whose sharing cannot start again by itself after a reboot.
    for (final (label, reply) in <(String, Object? Function(MethodCall))>[
      ('a platform error', (_) => throw PlatformException(code: 'boom')),
      ('no reply', (_) => null),
      ('a mistyped reply', (_) => <String, Object?>{'required': 'yes'}),
      ('a missing key', (_) => <String, Object?>{'required': true}),
    ]) {
      test('$label reads as missing', () async {
        answer(reply);
        final status = await api.status();
        expect(status.required, isTrue);
        expect(status.granted, isFalse);
      });
    }

    test('no native handler reads as missing', () async {
      final status = await const MethodChannelAndroidBackgroundLocation(
        channel: MethodChannel('haven.test/unregistered'),
      ).status();
      expect(status.missing, isTrue);
    });

    test('an empty label is no label', () async {
      answer(
        (_) => <String, Object?>{
          'required': true,
          'granted': false,
          'optionLabel': '',
        },
      );
      expect((await api.status()).optionLabel, isNull);
    });
  });

  group('request', () {
    test('answers whether the OS showed anything', () async {
      answer((call) => call.method == 'request' ? false : null);
      expect(await api.request(), isFalse);
      answer((call) => call.method == 'request' ? true : null);
      expect(await api.request(), isTrue);
    });

    test('a failed request showed nothing', () async {
      answer((_) => throw PlatformException(code: 'boom'));
      expect(await api.request(), isFalse);
    });
  });

  group('requestBackgroundLocation', () {
    test(
      're-reads the permission after the request rather than trusting it',
      () async {
        var granted = false;
        answer((call) {
          if (call.method == 'request') {
            granted = true;
            return true;
          }
          return <String, Object?>{'required': true, 'granted': granted};
        });
        final after = await requestBackgroundLocation(api);
        expect(after.granted, isTrue);
        expect(calls, ['request', 'status']);
      },
    );

    test('when Android showed nothing and it is still missing, opens app '
        'settings: its page will not appear again', () async {
      answer(
        (call) => call.method == 'request'
            ? false
            : <String, Object?>{'required': true, 'granted': false},
      );
      await requestBackgroundLocation(api);
      expect(calls, ['request', 'status', 'openAppSettings']);
    });

    test('a page the user declined is not followed by app settings', () async {
      answer(
        (call) => call.method == 'request'
            ? true
            : <String, Object?>{'required': true, 'granted': false},
      );
      await requestBackgroundLocation(api);
      expect(calls, ['request', 'status']);
    });
  });

  group('providers', () {
    test('off Android: nothing is required and no channel is called', () async {
      answer((_) => fail('the channel was called off Android'));
      final container = ProviderContainer(
        overrides: [platformIsAndroidProvider.overrideWithValue(false)],
      );
      addTearDown(container.dispose);
      final status = await container.read(
        backgroundLocationStatusProvider.future,
      );
      expect(status.required, isFalse);
      expect(status.missing, isFalse);
      expect(calls, isEmpty);
    });

    test('on Android the status comes from the channel', () async {
      answer((_) => <String, Object?>{'required': true, 'granted': true});
      final container = ProviderContainer(
        overrides: [platformIsAndroidProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);
      final status = await container.read(
        backgroundLocationStatusProvider.future,
      );
      expect(status.granted, isTrue);
      expect(calls, ['status']);
    });
  });

  // Rule 15: a failure is logged by its code alone, never by the platform's
  // message or details, which a native layer may fill with anything.
  test('a failed call logs its code and nothing the platform said', () async {
    final logs = LogCapture.install();
    answer(
      (_) => throw PlatformException(
        code: 'boom',
        message: 'npub1plantedmessage0000000000000000000000000000000',
        details: 'wss://planted.relay.example',
      ),
    );
    await api.status();
    await api.request();
    await api.openAppSettings();
    logs
      ..assertContains('[BackgroundLocation] status failed: boom')
      ..assertNoNeedles([
        'npub1plantedmessage0000000000000000000000000000000',
        'wss://planted.relay.example',
      ]);
  });
}
