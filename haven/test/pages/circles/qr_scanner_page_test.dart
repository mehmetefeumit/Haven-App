import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/qr_scanner_page.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_settings_launcher.dart';
import 'package:haven/src/services/qr_scanner_channel.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/localized_app_harness.dart';

// NIP-19's own example npub.
const _npub = 'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';

class _RecordingLauncher implements LocationSettingsLauncher {
  final List<String> opened = [];

  @override
  Future<bool> openLocationSettings() async {
    opened.add('location');
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    opened.add('app');
    return true;
  }
}

void main() {
  late List<MethodCall> calls;
  late String access;
  late _RecordingLauncher launcher;
  const channel = MethodChannel(QrScannerChannel.name);

  setUp(() {
    calls = [];
    access = 'granted';
    launcher = _RecordingLauncher();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'requestAccess' || 'checkAccess' => access,
          _ => null,
        };
      })
      // The camera view itself is native; the test only needs its creation
      // to succeed.
      ..setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async => call.method == 'create' ? 0 : null,
      );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(channel, null)
      ..setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  /// The token the visible scanner gave its camera view.
  int viewToken(WidgetTester tester) {
    final view = tester.widget<AndroidView>(find.byType(AndroidView).last);
    return (view.creationParams! as Map)['token'] as int;
  }

  /// Sends a native -> Dart scanner event from the view holding [token] (the
  /// visible scanner's when omitted), as the platform would.
  Future<void> nativeSends(
    WidgetTester tester,
    String method, {
    Map<String, Object> fields = const {},
    int? token,
  }) async {
    final args = {'token': token ?? viewToken(tester), ...fields};
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      QrScannerChannel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await tester.pump();
  }

  Iterable<Object?> stopsSent() =>
      calls.where((c) => c.method == 'stop').map((c) => c.arguments);

  /// Pumps an empty home page; [push] then opens a scanner over it and
  /// records what the scanner popped with in the returned list.
  Future<(List<String?>, Future<void> Function())> pumpHome(
    WidgetTester tester,
  ) async {
    final popped = <String?>[];
    late BuildContext home;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) {
          home = context;
          return const SizedBox.shrink();
        },
      ),
      overrides: [locationSettingsLauncherProvider.overrideWithValue(launcher)],
    );
    Future<void> push() async {
      unawaited(
        Navigator.push<String>(
          home,
          MaterialPageRoute(builder: (_) => const QrScannerPage()),
        ).then(popped.add),
      );
      await tester.pumpAndSettle();
    }

    return (popped, push);
  }

  /// Opens one scanner and returns what it popped with.
  Future<List<String?>> openScanner(WidgetTester tester) async {
    final (popped, push) = await pumpHome(tester);
    await push();
    return popped;
  }

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(QrScannerPage)));

  int count(String method) => calls.where((c) => c.method == method).length;

  group('camera access granted', () {
    testWidgets('shows the camera view with the frame, torch and switch', (
      tester,
    ) async {
      await openScanner(tester);

      expect(count('requestAccess'), 1);
      final view = tester.widget<AndroidView>(find.byType(AndroidView));
      expect(view.viewType, QrScannerChannel.viewType);
      expect(find.text(l10n(tester).qrScannerInstruction), findsOneWidget);
      expect(find.byTooltip(l10n(tester).qrScannerToggleFlash), findsOneWidget);
      expect(
        find.byTooltip(l10n(tester).qrScannerSwitchCamera),
        findsOneWidget,
      );
    });

    testWidgets('returns the npub of the first valid code, once', (
      tester,
    ) async {
      final popped = await openScanner(tester);

      await nativeSends(tester, 'detected', fields: {'text': 'nostr:$_npub'});
      await nativeSends(tester, 'detected', fields: {'text': _npub});
      await tester.pumpAndSettle();

      expect(popped, [_npub]);
      expect(find.byType(QrScannerPage), findsNothing);
    });

    testWidgets('ignores a code that holds no npub and keeps scanning', (
      tester,
    ) async {
      final popped = await openScanner(tester);

      await nativeSends(
        tester,
        'detected',
        fields: {'text': 'https://example.com'},
      );
      await tester.pumpAndSettle();
      expect(popped, isEmpty);
      expect(find.byType(QrScannerPage), findsOneWidget);

      await nativeSends(tester, 'detected', fields: {'text': _npub});
      await tester.pumpAndSettle();
      expect(popped, [_npub]);
    });

    testWidgets('the torch button asks for the opposite of what the camera '
        'reports, and its icon follows the camera', (tester) async {
      await openScanner(tester);
      final token = viewToken(tester);
      final toggle = find.byTooltip(l10n(tester).qrScannerToggleFlash);
      expect(find.byIcon(LucideIcons.zapOff), findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();
      expect(
        calls.last,
        isMethodCall('setTorch', arguments: {'token': token, 'on': true}),
      );
      // The icon shows what the camera did, not what was asked.
      expect(find.byIcon(LucideIcons.zapOff), findsOneWidget);

      await nativeSends(tester, 'torch', fields: {'on': true});
      expect(find.byIcon(LucideIcons.zap), findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();
      expect(
        calls.last,
        isMethodCall('setTorch', arguments: {'token': token, 'on': false}),
      );
    });

    testWidgets('the switch button switches this page’s camera', (
      tester,
    ) async {
      await openScanner(tester);

      await tester.tap(find.byTooltip(l10n(tester).qrScannerSwitchCamera));
      await tester.pump();

      expect(
        calls.last,
        isMethodCall('switchCamera', arguments: {'token': viewToken(tester)}),
      );
    });

    testWidgets('a camera that fails to start shows the unavailable message', (
      tester,
    ) async {
      await openScanner(tester);

      await nativeSends(tester, 'unavailable');

      expect(find.byType(AndroidView), findsNothing);
      expect(
        find.text(l10n(tester).qrScannerCameraUnavailable),
        findsOneWidget,
      );
      expect(find.byTooltip(l10n(tester).qrScannerToggleFlash), findsNothing);
    });

    testWidgets('closing the page releases its camera and stops listening', (
      tester,
    ) async {
      final popped = await openScanner(tester);
      final token = viewToken(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(stopsSent(), [
        {'token': token},
      ]);

      // An event after the page is gone reaches nothing.
      await nativeSends(
        tester,
        'detected',
        fields: {'text': _npub},
        token: token,
      );
      expect(popped, [null]);
    });
  });

  testWidgets('a scanner opened while the last one is still closing keeps '
      'its camera and its events', (tester) async {
    final (popped, push) = await pumpHome(tester);
    await push();
    final first = viewToken(tester);

    // The first scan pops its page; the next opens before that page's exit
    // animation has ended, so the first page is disposed while the second
    // is already scanning.
    await nativeSends(tester, 'detected', fields: {'text': _npub});
    await push();
    final second = viewToken(tester);
    expect(second, isNot(first));
    expect(stopsSent(), [
      {'token': first},
    ]);

    // The first page's camera may still report; the second ignores it.
    await nativeSends(
      tester,
      'detected',
      fields: {'text': _npub},
      token: first,
    );
    expect(popped, [_npub]);
    expect(find.byType(QrScannerPage), findsOneWidget);

    await nativeSends(tester, 'detected', fields: {'text': _npub});
    await tester.pumpAndSettle();
    expect(popped, [_npub, _npub]);
    expect(find.byType(QrScannerPage), findsNothing);
  });

  group('camera access denied', () {
    testWidgets('explains, offers Settings, and shows no camera or controls', (
      tester,
    ) async {
      access = 'denied';
      await openScanner(tester);

      expect(find.byType(AndroidView), findsNothing);
      expect(find.text(l10n(tester).qrScannerCameraDenied), findsOneWidget);
      expect(find.byTooltip(l10n(tester).qrScannerToggleFlash), findsNothing);
      expect(find.byTooltip(l10n(tester).qrScannerSwitchCamera), findsNothing);

      await tester.tap(find.text(l10n(tester).commonOpenSettings));
      await tester.pump();
      expect(launcher.opened, ['app']);
    });

    testWidgets('returning with the camera allowed starts scanning without '
        'asking again', (tester) async {
      access = 'denied';
      await openScanner(tester);

      access = 'granted';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(count('checkAccess'), 1);
      expect(count('requestAccess'), 1);
      expect(find.byType(AndroidView), findsOneWidget);
    });

    testWidgets('returning still denied keeps the explanation', (tester) async {
      access = 'denied';
      await openScanner(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text(l10n(tester).qrScannerCameraDenied), findsOneWidget);
      expect(find.byType(AndroidView), findsNothing);
    });
  });

  testWidgets('a camera that was busy is tried again on return', (
    tester,
  ) async {
    await openScanner(tester);
    await nativeSends(tester, 'unavailable');
    expect(find.byType(AndroidView), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(count('checkAccess'), 1);
    expect(find.byType(AndroidView), findsOneWidget);
  });

  testWidgets('a device without a camera says so and offers nothing to tap', (
    tester,
  ) async {
    access = 'unavailable';
    await openScanner(tester);

    expect(find.text(l10n(tester).qrScannerCameraUnavailable), findsOneWidget);
    expect(find.text(l10n(tester).commonOpenSettings), findsNothing);
    expect(find.byType(AndroidView), findsNothing);
  });

  testWidgets('a channel failure is treated as no camera, never a crash', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'boom');
        });
    await openScanner(tester);

    expect(find.text(l10n(tester).qrScannerCameraUnavailable), findsOneWidget);
  });
}
