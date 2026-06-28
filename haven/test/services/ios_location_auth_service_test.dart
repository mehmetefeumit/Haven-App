import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/ios_location_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelIosLocationAuthService.statusFromString', () {
    test('maps every known native status string', () {
      expect(
        MethodChannelIosLocationAuthService.statusFromString('notDetermined'),
        IosAuthStatus.notDetermined,
      );
      expect(
        MethodChannelIosLocationAuthService.statusFromString('restricted'),
        IosAuthStatus.restricted,
      );
      expect(
        MethodChannelIosLocationAuthService.statusFromString('denied'),
        IosAuthStatus.denied,
      );
      expect(
        MethodChannelIosLocationAuthService.statusFromString('whenInUse'),
        IosAuthStatus.whenInUse,
      );
      expect(
        MethodChannelIosLocationAuthService.statusFromString('always'),
        IosAuthStatus.always,
      );
    });

    test('maps null and unrecognised values to unknown', () {
      expect(
        MethodChannelIosLocationAuthService.statusFromString(null),
        IosAuthStatus.unknown,
      );
      expect(
        MethodChannelIosLocationAuthService.statusFromString('garbage'),
        IosAuthStatus.unknown,
      );
      expect(
        MethodChannelIosLocationAuthService.statusFromString(''),
        IosAuthStatus.unknown,
      );
    });
  });

  group('MethodChannelIosLocationAuthService channel', () {
    const service = MethodChannelIosLocationAuthService();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final log = <String>[];

    tearDown(() {
      messenger.setMockMethodCallHandler(
        MethodChannelIosLocationAuthService.channel,
        null,
      );
      log.clear();
    });

    void mock(Future<Object?>? Function(MethodCall) handler) {
      messenger.setMockMethodCallHandler(
        MethodChannelIosLocationAuthService.channel,
        (call) async {
          log.add(call.method);
          return handler(call);
        },
      );
    }

    test('checkStatus invokes checkAlwaysStatus and maps the reply', () async {
      mock((_) async => 'always');
      expect(await service.checkStatus(), IosAuthStatus.always);
      expect(log, ['checkAlwaysStatus']);
    });

    test('requestAlways invokes requestAlwaysAuthorization and maps', () async {
      mock((_) async => 'whenInUse');
      expect(await service.requestAlways(), IosAuthStatus.whenInUse);
      expect(log, ['requestAlwaysAuthorization']);
    });

    test('a PlatformException resolves to unknown (never throws)', () async {
      mock((_) async => throw PlatformException(code: 'boom'));
      expect(await service.checkStatus(), IosAuthStatus.unknown);
      expect(await service.requestAlways(), IosAuthStatus.unknown);
    });

    test('a missing native handler resolves to unknown', () async {
      // No mock handler registered → MissingPluginException is caught. Cover
      // BOTH methods: requestAlways is the variant invoked during background
      // enable, and it shares the same _invoke() catch path.
      expect(await service.checkStatus(), IosAuthStatus.unknown);
      expect(await service.requestAlways(), IosAuthStatus.unknown);
    });

    test('an unexpected null reply maps to unknown', () async {
      mock((_) async => null);
      expect(await service.requestAlways(), IosAuthStatus.unknown);
    });
  });

  group('NoopIosLocationAuthService', () {
    test(
      'reports always for both calls (non-iOS default = not limited)',
      () async {
        const service = NoopIosLocationAuthService();
        expect(await service.checkStatus(), IosAuthStatus.always);
        expect(await service.requestAlways(), IosAuthStatus.always);
      },
    );
  });
}
