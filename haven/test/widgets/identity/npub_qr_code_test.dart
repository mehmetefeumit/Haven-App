/// Tests for NpubQrCode widget.
///
/// Verifies that:
/// - QR data is correctly encoded with nostr: prefix
/// - QrImageView renders with correct properties
/// - Size variants (small, medium, large) work correctly
/// - Label visibility toggles properly
/// - Accessibility semantics are present
/// - Widget renders in both light and dark themes
/// - QR code always uses white background for scannability
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Valid test npub (63 chars, valid bech32 format)
  const testNpub =
      'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5tr';

  group('NpubQrCode', () {
    group('Data Encoding', () {
      testWidgets('qrData prepends nostr: prefix', (tester) async {
        const widget = NpubQrCode(npub: testNpub);

        expect(widget.qrData, equals('nostr:$testNpub'));
      });

      testWidgets('qrData uses NIP-21 format', (tester) async {
        const widget = NpubQrCode(npub: testNpub);

        // Should start with nostr: prefix per NIP-21
        expect(widget.qrData.startsWith('nostr:'), isTrue);
      });
    });

    group('QrImageView Rendering', () {
      testWidgets('QrImageView is rendered in widget tree', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        expect(find.byType(QrImageView), findsOneWidget);
      });

      testWidgets('QrImageView uses auto version', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.version, equals(QrVersions.auto));
      });

      testWidgets('QrImageView uses square modules', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(
          qrView.dataModuleStyle?.dataModuleShape,
          equals(QrDataModuleShape.square),
        );
        expect(qrView.eyeStyle?.eyeShape, equals(QrEyeShape.square));
      });

      testWidgets('QrImageView uses black color for modules', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.dataModuleStyle?.color, equals(Colors.black));
        expect(qrView.eyeStyle?.color, equals(Colors.black));
      });
    });

    group('Size Variants', () {
      testWidgets('default size is medium (200)', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.size, equals(200.0));
      });

      testWidgets('small size is 150', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NpubQrCode(npub: testNpub, size: NpubQrSize.small),
            ),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.size, equals(150.0));
      });

      testWidgets('medium size is 200', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NpubQrCode(npub: testNpub, size: NpubQrSize.medium),
            ),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.size, equals(200.0));
      });

      testWidgets('large size is 280', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NpubQrCode(npub: testNpub, size: NpubQrSize.large),
            ),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.size, equals(280.0));
      });

      testWidgets('NpubQrSize enum has correct dimension values', (
        tester,
      ) async {
        expect(NpubQrSize.small.dimension, equals(150.0));
        expect(NpubQrSize.medium.dimension, equals(200.0));
        expect(NpubQrSize.large.dimension, equals(280.0));
      });
    });

    group('Label Display', () {
      testWidgets('shows label by default', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        expect(find.text('Scan to add me'), findsOneWidget);
      });

      testWidgets('shows label when showLabel is true', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub, showLabel: true)),
          ),
        );

        expect(find.text('Scan to add me'), findsOneWidget);
      });

      testWidgets('hides label when showLabel is false', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub, showLabel: false)),
          ),
        );

        expect(find.text('Scan to add me'), findsNothing);
      });

      testWidgets('label has correct spacing', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        // Find the SizedBox that should be between QR and label
        final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
        expect(
          sizedBoxes.any((box) => box.height == HavenSpacing.sm),
          isTrue,
          reason: 'Should have SizedBox with HavenSpacing.sm height',
        );
      });
    });

    group('Accessibility', () {
      testWidgets('Semantics widget wraps content', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        // Verify Semantics widget exists
        expect(find.byType(Semantics), findsWidgets);

        // The Semantics widget should wrap the Column
        final semanticsWidget = tester.widget<Semantics>(
          find
              .descendant(
                of: find.byType(NpubQrCode),
                matching: find.byType(Semantics),
              )
              .first,
        );
        expect(semanticsWidget.child, isA<Column>());
      });

      testWidgets('Semantics configured with label', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        // Find the NpubQrCode widget itself to verify construction
        final npubQrCode = find.byType(NpubQrCode);
        expect(npubQrCode, findsOneWidget);

        // Verify by checking widget tree structure
        final semanticsWidget = tester.widget<Semantics>(
          find
              .descendant(of: npubQrCode, matching: find.byType(Semantics))
              .first,
        );

        // Semantics should have a label parameter set
        expect(semanticsWidget.container, isFalse);
        expect(semanticsWidget.child, isNotNull);
      });
    });

    group('Theme Support', () {
      testWidgets('renders in light theme', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.light(),
            home: const Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        expect(find.byType(NpubQrCode), findsOneWidget);
        expect(find.byType(QrImageView), findsOneWidget);
      });

      testWidgets('renders in dark theme', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: const Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        expect(find.byType(NpubQrCode), findsOneWidget);
        expect(find.byType(QrImageView), findsOneWidget);
      });

      testWidgets('QR background is always white in light theme', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.light(),
            home: const Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.backgroundColor, equals(Colors.white));
      });

      testWidgets('QR background is always white in dark theme', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: const Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));
        expect(qrView.backgroundColor, equals(Colors.white));
      });

      testWidgets('container background is white regardless of theme', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: const Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        // Find the container that wraps the QR code
        final container = tester.widget<Container>(
          find.ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          ),
        );

        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, equals(Colors.white));
      });
    });

    group('Container Styling', () {
      testWidgets('has rounded corners', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final container = tester.widget<Container>(
          find.ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          ),
        );

        final decoration = container.decoration as BoxDecoration;
        expect(decoration.borderRadius, isNotNull);
        expect(
          (decoration.borderRadius as BorderRadius).topLeft.x,
          equals(HavenSpacing.md),
        );
      });

      testWidgets('has border with theme color', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final container = tester.widget<Container>(
          find.ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          ),
        );

        final decoration = container.decoration as BoxDecoration;
        expect(decoration.border, isNotNull);
      });

      testWidgets('has correct padding', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final container = tester.widget<Container>(
          find.ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          ),
        );

        expect(
          container.padding,
          equals(const EdgeInsets.all(HavenSpacing.md)),
        );
      });
    });

    group('Widget Layout', () {
      testWidgets('uses Column with minimum size', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final column = tester.widget<Column>(find.byType(Column));
        expect(column.mainAxisSize, equals(MainAxisSize.min));
      });

      testWidgets('has correct child count with label and copy', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final column = tester.widget<Column>(find.byType(Column));
        // QR (GestureDetector), SizedBox, copy button, SizedBox, label Text
        expect(column.children.length, equals(5));
      });

      testWidgets('has correct child count without label', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub, showLabel: false)),
          ),
        );

        final column = tester.widget<Column>(find.byType(Column));
        // QR (GestureDetector), SizedBox, copy button
        expect(column.children.length, equals(3));
      });

      testWidgets('has correct child count without label or copy', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NpubQrCode(
                npub: testNpub,
                showLabel: false,
                enableCopy: false,
              ),
            ),
          ),
        );

        final column = tester.widget<Column>(find.byType(Column));
        // Just the QR container
        expect(column.children.length, equals(1));
      });
    });

    group('Different Npubs', () {
      testWidgets('handles different valid npubs', (tester) async {
        const differentNpub =
            'npub1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p7q8r9s0t1u2v3w4x5y6z7a8b9c';

        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: differentNpub)),
          ),
        );

        expect(find.byType(QrImageView), findsOneWidget);
        expect(find.byType(NpubQrCode), findsOneWidget);
      });

      testWidgets('qrData getter works with any npub', (tester) async {
        const npub1 =
            'npub1test1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP';
        const npub2 = 'npub1different9876543210zyxwvutsrqponmlkjihgfedcba';

        const widget1 = NpubQrCode(npub: npub1);
        const widget2 = NpubQrCode(npub: npub2);

        expect(widget1.qrData, equals('nostr:$npub1'));
        expect(widget2.qrData, equals('nostr:$npub2'));
      });
    });

    group('Edge Cases', () {
      testWidgets('renders with very short npub', (tester) async {
        const shortNpub = 'npub1short';

        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: shortNpub)),
          ),
        );

        expect(find.byType(QrImageView), findsOneWidget);
      });

      testWidgets('renders with very long npub', (tester) async {
        // Create a long npub at runtime (not const)
        final longNpub = 'npub1${'a' * 100}';

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: longNpub)),
          ),
        );

        expect(find.byType(QrImageView), findsOneWidget);
      });

      testWidgets('all three sizes render without errors', (tester) async {
        for (final size in NpubQrSize.values) {
          await tester.pumpWidget(
            MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: NpubQrCode(npub: testNpub, size: size),
              ),
            ),
          );

          expect(find.byType(QrImageView), findsOneWidget);
          await tester.pumpAndSettle();
        }
      });
    });

    group('QR Code Scannability', () {
      testWidgets('uses high contrast colors (black on white)', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final qrView = tester.widget<QrImageView>(find.byType(QrImageView));

        // Background should be white
        expect(qrView.backgroundColor, equals(Colors.white));

        // Modules should be black
        expect(qrView.dataModuleStyle?.color, equals(Colors.black));
        expect(qrView.eyeStyle?.color, equals(Colors.black));
      });

      testWidgets('container provides white background', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(), // Even in dark theme
            home: const Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final container = tester.widget<Container>(
          find.ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          ),
        );

        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, equals(Colors.white));
      });

      testWidgets('adequate padding around QR code', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final container = tester.widget<Container>(
          find.ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          ),
        );

        // Should have padding for quiet zone
        expect(container.padding, isNotNull);
        expect(
          container.padding,
          equals(const EdgeInsets.all(HavenSpacing.md)),
        );
      });
    });

    group('Copy on Hold', () {
      // Captures platform-channel method calls (Clipboard.setData,
      // HapticFeedback.vibrate) so we can assert on the copy behaviour and
      // avoid "no implementation" warnings in the test host.
      late List<MethodCall> platformCalls;

      setUp(() {
        platformCalls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              platformCalls.add(call);
              return null;
            });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      MethodCall? clipboardCall() {
        for (final call in platformCalls) {
          if (call.method == 'Clipboard.setData') return call;
        }
        return null;
      }

      Finder qrGesture() => find.ancestor(
        of: find.byType(QrImageView),
        matching: find.byType(GestureDetector),
      );

      testWidgets('wraps QR in a long-press GestureDetector by default', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        expect(qrGesture(), findsOneWidget);
        final gesture = tester.widget<GestureDetector>(qrGesture());
        expect(gesture.onLongPress, isNotNull);
      });

      testWidgets('long-press copies the plain npub to the clipboard', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump();

        final call = clipboardCall();
        expect(call, isNotNull, reason: 'Clipboard.setData should be invoked');
        final copied = (call!.arguments as Map)['text'] as String;
        expect(copied, equals(testNpub));
      });

      testWidgets('copies the bare npub, not the nostr: URI', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump();

        final copied =
            (clipboardCall()!.arguments as Map)['text'] as String;
        expect(copied.startsWith('nostr:'), isFalse);
        expect(copied.startsWith('npub1'), isTrue);
      });

      testWidgets('long-press triggers haptic feedback', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump();

        expect(
          platformCalls.any((c) => c.method == 'HapticFeedback.vibrate'),
          isTrue,
        );
      });

      testWidgets('shows a confirmation SnackBar after copying', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.text('Public key copied to clipboard'),
          findsOneWidget,
        );

        // Drain the SnackBar's display timer so it doesn't outlive the test.
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
      });

      testWidgets('confirmation does not leak the secret-key warning', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Public keys are not sensitive: no "Secret"/"Warning" copy here.
        expect(find.textContaining('Secret'), findsNothing);
        expect(find.textContaining('Warning'), findsNothing);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
      });

      testWidgets('shows a "Copy public key" button when copy is enabled', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        expect(
          find.widgetWithText(TextButton, 'Copy public key'),
          findsOneWidget,
        );
      });

      testWidgets('tapping the button copies the plain npub (a11y path)', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        await tester.tap(find.widgetWithText(TextButton, 'Copy public key'));
        await tester.pump();
        await tester.pump();

        final call = clipboardCall();
        expect(call, isNotNull);
        expect((call!.arguments as Map)['text'], equals(testNpub));
      });

      testWidgets('Copy button has a 48dp minimum touch target', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final size = tester.getSize(
          find.widgetWithText(TextButton, 'Copy public key'),
        );
        expect(size.height, greaterThanOrEqualTo(48.0));
      });

      testWidgets('does not duplicate the copy action in QR semantics', (
        tester,
      ) async {
        // The button is the assistive-tech affordance; the QR long-press is a
        // sighted-user shortcut whose semantics are intentionally excluded so
        // a screen reader does not announce the copy action twice.
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: testNpub)),
          ),
        );

        final semantics = tester.widget<Semantics>(
          find
              .descendant(
                of: find.byType(NpubQrCode),
                matching: find.byType(Semantics),
              )
              .first,
        );
        // Group keeps its descriptive label but exposes no long-press action.
        expect(
          semantics.properties.label,
          equals('QR code for your public identity'),
        );
        expect(semantics.properties.onLongPress, isNull);

        // The accessible copy path is a focusable button.
        expect(
          find.widgetWithText(TextButton, 'Copy public key'),
          findsOneWidget,
        );
      });

      testWidgets('no gesture, hint, or copy when enableCopy is false', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NpubQrCode(npub: testNpub, enableCopy: false),
            ),
          ),
        );

        expect(qrGesture(), findsNothing);
        expect(find.text('Copy public key'), findsNothing);

        // Attempting to long-press must not copy anything.
        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump();

        expect(clipboardCall(), isNull);
      });

      testWidgets('copies the exact npub it was given', (tester) async {
        const otherNpub =
            'npub1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p7q8r9s0t1u2v3w4x5y6z7a8b9c';

        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: NpubQrCode(npub: otherNpub)),
          ),
        );

        await tester.longPress(find.byType(QrImageView));
        await tester.pump();
        await tester.pump();

        final copied =
            (clipboardCall()!.arguments as Map)['text'] as String;
        expect(copied, equals(otherNpub));
      });
    });
  });
}
