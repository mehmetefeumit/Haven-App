/// Tests for DebugLogOverlay widget.
///
/// Verifies that:
/// - Renders nothing when overlay is not visible
/// - Shows overlay with entries when visible
/// - Displays log entries with correct text and colors
/// - Clear button clears logs
/// - Close button toggles overlay visibility
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/widgets/debug/debug_log_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Creates a test notifier with optional pre-populated entries.
  DebugLogNotifier createNotifier({
    List<LogEntry>? entries,
    bool isVisible = false,
  }) {
    final notifier = DebugLogNotifier();
    if (entries != null || isVisible) {
      notifier.state = DebugLogState(
        entries: entries ?? [],
        isVisible: isVisible,
      );
    }
    return notifier;
  }

  /// Wraps the overlay in required parent widgets for testing.
  Widget wrapOverlay(DebugLogNotifier notifier) {
    return ProviderScope(
      overrides: [debugLogProvider.overrideWith((ref) => notifier)],
      child: const MaterialApp(
        home: Scaffold(body: Stack(children: [DebugLogOverlay()])),
      ),
    );
  }

  group('DebugLogOverlay', () {
    testWidgets('renders nothing when isVisible is false', (tester) async {
      final notifier = createNotifier();

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Should render SizedBox.shrink (no Positioned widget content)
      expect(find.text('Debug Log'), findsNothing);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('renders overlay when isVisible is true', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Test message',
            level: LogLevel.info,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Should show the overlay header
      expect(find.text('Debug Log'), findsOneWidget);
      expect(find.text('(1)'), findsOneWidget);
    });

    testWidgets('displays log entries with correct text', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'First message',
            level: LogLevel.info,
          ),
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 46, 456),
            message: 'Second message',
            level: LogLevel.error,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Should show both messages
      expect(find.textContaining('First message'), findsOneWidget);
      expect(find.textContaining('Second message'), findsOneWidget);

      // Should show correct count
      expect(find.text('(2)'), findsOneWidget);
    });

    testWidgets('shows correct color for debug level', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Debug message',
            level: LogLevel.debug,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Find the text widget containing the level label
      final richText = tester.widget<Text>(find.textContaining('DBG'));

      // Extract the TextSpan and verify color
      final textSpan = richText.textSpan! as TextSpan;
      final levelSpan = textSpan.children![1] as TextSpan;
      expect(levelSpan.text, 'DBG ');
      expect(levelSpan.style?.color, Colors.white70);
    });

    testWidgets('shows correct color for info level', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Info message',
            level: LogLevel.info,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Find the text widget containing the level label
      final richText = tester.widget<Text>(find.textContaining('INF'));

      // Extract the TextSpan and verify color
      final textSpan = richText.textSpan! as TextSpan;
      final levelSpan = textSpan.children![1] as TextSpan;
      expect(levelSpan.text, 'INF ');
      expect(levelSpan.style?.color, Colors.greenAccent);
    });

    testWidgets('shows correct color for warning level', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Warning message',
            level: LogLevel.warning,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Find the text widget containing the level label
      final richText = tester.widget<Text>(find.textContaining('WRN'));

      // Extract the TextSpan and verify color
      final textSpan = richText.textSpan! as TextSpan;
      final levelSpan = textSpan.children![1] as TextSpan;
      expect(levelSpan.text, 'WRN ');
      expect(levelSpan.style?.color, Colors.orangeAccent);
    });

    testWidgets('shows correct color for error level', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Error message',
            level: LogLevel.error,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Find the text widget containing the level label
      final richText = tester.widget<Text>(find.textContaining('ERR'));

      // Extract the TextSpan and verify color
      final textSpan = richText.textSpan! as TextSpan;
      final levelSpan = textSpan.children![1] as TextSpan;
      expect(levelSpan.text, 'ERR ');
      expect(levelSpan.style?.color, Colors.redAccent);
    });

    testWidgets('clear button calls clearLogs', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Test message',
            level: LogLevel.info,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Verify entry exists
      expect(find.textContaining('Test message'), findsOneWidget);
      expect(find.text('(1)'), findsOneWidget);

      // Tap the clear button (delete icon)
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      // Entries should be cleared
      expect(notifier.state.entries, isEmpty);
      expect(find.text('(0)'), findsOneWidget);
      expect(find.text('No logs yet'), findsOneWidget);
    });

    testWidgets('close button calls toggleOverlay', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'Test message',
            level: LogLevel.info,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Verify overlay is visible
      expect(notifier.state.isVisible, isTrue);
      expect(find.text('Debug Log'), findsOneWidget);

      // Tap the close button
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // Overlay should be hidden
      expect(notifier.state.isVisible, isFalse);
    });

    testWidgets('shows "No logs yet" when entries list is empty', (
      tester,
    ) async {
      final notifier = createNotifier(isVisible: true, entries: []);

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Should show empty state message
      expect(find.text('No logs yet'), findsOneWidget);
      expect(find.text('(0)'), findsOneWidget);
    });

    testWidgets('formats timestamp correctly', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 9, 5, 7, 8),
            message: 'Test message',
            level: LogLevel.info,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Should show formatted timestamp with padding
      expect(find.textContaining('09:05:07.008'), findsOneWidget);
    });

    testWidgets('displays multiple entries in order', (tester) async {
      final notifier = createNotifier(
        isVisible: true,
        entries: [
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 45, 123),
            message: 'First',
            level: LogLevel.debug,
          ),
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 46, 456),
            message: 'Second',
            level: LogLevel.info,
          ),
          LogEntry(
            timestamp: DateTime(2026, 2, 15, 10, 30, 47, 789),
            message: 'Third',
            level: LogLevel.error,
          ),
        ],
      );

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // All entries should be present
      expect(find.textContaining('First'), findsOneWidget);
      expect(find.textContaining('Second'), findsOneWidget);
      expect(find.textContaining('Third'), findsOneWidget);
      expect(find.text('(3)'), findsOneWidget);

      // Verify they're in a ListView
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('header buttons have correct tooltips', (tester) async {
      final notifier = createNotifier(isVisible: true);

      await tester.pumpWidget(wrapOverlay(notifier));
      await tester.pumpAndSettle();

      // Find buttons by icon and verify tooltips
      final clearButton = find.ancestor(
        of: find.byIcon(Icons.delete_outline),
        matching: find.byType(IconButton),
      );
      final closeButton = find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(IconButton),
      );

      expect(tester.widget<IconButton>(clearButton).tooltip, 'Clear logs');
      expect(tester.widget<IconButton>(closeButton).tooltip, 'Close overlay');
    });
  });
}
