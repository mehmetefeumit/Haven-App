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
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'requestAccess' || 'checkAccess' => access,
        _ => null,
      };
    });
    // The camera view itself is native; the test only needs its creation to
    // succeed.
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async => call.method == 'create' ? 0 : null,
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger
      ..setMockMethodCallHandler(channel, null)
      ..setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  /// Sends a native -> Dart scanner event, as the platform would.
  Future<void> nativeSends(
    WidgetTester tester,
    String method, [
    Object? argument,
  ]) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      QrScannerChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, argument),
      ),
      (_) {},
    );
    await tester.pump();
  }

  /// Opens the scanner from a home page and returns what it popped with.
  Future<List<String?>> openScanner(WidgetTester tester) async {
    final popped = <String?>[];
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            popped.add(
              await Navigator.push<String>(
                context,
                MaterialPageRoute(builder: (_) => const QrScannerPage()),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
      overrides: [locationSettingsLauncherProvider.overrideWithValue(launcher)],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
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

      await nativeSends(tester, 'detected', 'nostr:$_npub');
      await nativeSends(tester, 'detected', _npub);
      await tester.pumpAndSettle();

      expect(popped, [_npub]);
      expect(find.byType(QrScannerPage), findsNothing);
    });

    testWidgets('ignores a code that holds no npub and keeps scanning', (
      tester,
    ) async {
      final popped = await openScanner(tester);

      await nativeSends(tester, 'detected', 'https://example.com');
      await tester.pumpAndSettle();
      expect(popped, isEmpty);
      expect(find.byType(QrScannerPage), findsOneWidget);

      await nativeSends(tester, 'detected', _npub);
      await tester.pumpAndSettle();
      expect(popped, [_npub]);
    });

    testWidgets('the torch button asks for the opposite of what the camera '
        'reports, and its icon follows the camera', (tester) async {
      await openScanner(tester);
      final toggle = find.byTooltip(l10n(tester).qrScannerToggleFlash);
      expect(find.byIcon(LucideIcons.zapOff), findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();
      expect(calls.last, isMethodCall('setTorch', arguments: true));
      // The icon shows what the camera did, not what was asked.
      expect(find.byIcon(LucideIcons.zapOff), findsOneWidget);

      await nativeSends(tester, 'torch', true);
      expect(find.byIcon(LucideIcons.zap), findsOneWidget);

      await tester.tap(toggle);
      await tester.pump();
      expect(calls.last, isMethodCall('setTorch', arguments: false));
    });

    testWidgets('the switch button switches the camera', (tester) async {
      await openScanner(tester);

      await tester.tap(find.byTooltip(l10n(tester).qrScannerSwitchCamera));
      await tester.pump();

      expect(count('switchCamera'), 1);
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

    testWidgets('closing the page releases the camera and stops listening', (
      tester,
    ) async {
      final popped = await openScanner(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(count('stop'), 1);

      // An event after the page is gone reaches nothing.
      await nativeSends(tester, 'detected', _npub);
      expect(popped, [null]);
    });
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
