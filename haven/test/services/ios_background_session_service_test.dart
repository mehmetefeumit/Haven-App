import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/ios_background_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelIosBackgroundSessionService channel', () {
    const service = MethodChannelIosBackgroundSessionService();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final log = <String>[];

    tearDown(() {
      messenger.setMockMethodCallHandler(
        MethodChannelIosBackgroundSessionService.channel,
        null,
      );
      log.clear();
    });

    void mock(Future<Object?>? Function(MethodCall) handler) {
      messenger.setMockMethodCallHandler(
        MethodChannelIosBackgroundSessionService.channel,
        (call) async {
          log.add(call.method);
          return handler(call);
        },
      );
    }

    test('arm and disarm invoke their native methods', () async {
      mock((_) async => null);
      await service.arm();
      await service.disarm();
      expect(log, ['arm', 'disarm']);
    });

    test('arm survives a PlatformException without throwing', () async {
      mock((_) => throw PlatformException(code: 'boom'));
      await expectLater(service.arm(), completes);
    });

    test('disarm survives a missing native handler without throwing — '
        'an opt-out must never crash on a platform channel', () async {
      // No mock handler installed → MissingPluginException path.
      await expectLater(service.disarm(), completes);
    });

    test('status parses the native map', () async {
      mock(
        (_) async => <String, bool>{
          'supported': true,
          'backgroundActivitySessionHeld': true,
          'serviceSessionHeld': false,
        },
      );
      final status = await service.status();
      expect(status.supported, isTrue);
      expect(status.backgroundActivitySessionHeld, isTrue);
      expect(status.serviceSessionHeld, isFalse);
    });

    test('status treats missing keys as not held (fail-closed)', () async {
      mock((_) async => <String, bool>{});
      final status = await service.status();
      expect(status.supported, isFalse);
      expect(status.backgroundActivitySessionHeld, isFalse);
      expect(status.serviceSessionHeld, isFalse);
    });

    test('status reports nothing held on a PlatformException', () async {
      mock((_) => throw PlatformException(code: 'boom'));
      final status = await service.status();
      expect(status.supported, isFalse);
      expect(status.backgroundActivitySessionHeld, isFalse);
      expect(status.serviceSessionHeld, isFalse);
    });

    test('status reports nothing held when no native handler exists', () async {
      final status = await service.status();
      expect(status.supported, isFalse);
      expect(status.backgroundActivitySessionHeld, isFalse);
      expect(status.serviceSessionHeld, isFalse);
    });
  });

  group('NoopIosBackgroundSessionService', () {
    const service = NoopIosBackgroundSessionService();

    test('arm and disarm complete without platform access', () async {
      await expectLater(service.arm(), completes);
      await expectLater(service.disarm(), completes);
    });

    test('status reports nothing supported or held', () async {
      final status = await service.status();
      expect(status.supported, isFalse);
      expect(status.backgroundActivitySessionHeld, isFalse);
      expect(status.serviceSessionHeld, isFalse);
    });
  });
}
