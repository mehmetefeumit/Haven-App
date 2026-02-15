/// Tests for debug log provider.
///
/// Verifies that:
/// - Initial state has empty entries and isVisible=false
/// - addLog appends entries correctly
/// - Circular buffer trims to maxEntries (500)
/// - Level inference works for error/warning/info/debug keywords
/// - toggleOverlay flips isVisible
/// - clearLogs empties entries list
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/debug_log_provider.dart';

void main() {
  group('DebugLogNotifier', () {
    test('has empty entries and isVisible=false initially', () {
      final notifier = DebugLogNotifier();

      expect(notifier.state.entries, isEmpty);
      expect(notifier.state.isVisible, false);
    });

    test('addLog appends entry to entries list', () {
      final notifier = DebugLogNotifier();

      notifier.addLog('First log message');

      expect(notifier.state.entries, hasLength(1));
      expect(notifier.state.entries.first.message, 'First log message');
    });

    test('addLog appends multiple entries in order', () {
      final notifier = DebugLogNotifier();

      notifier
        ..addLog('First')
        ..addLog('Second')
        ..addLog('Third');

      expect(notifier.state.entries, hasLength(3));
      expect(notifier.state.entries[0].message, 'First');
      expect(notifier.state.entries[1].message, 'Second');
      expect(notifier.state.entries[2].message, 'Third');
    });

    test('addLog captures timestamp for each entry', () {
      final notifier = DebugLogNotifier();
      final before = DateTime.now();

      notifier.addLog('Timestamped message');

      final after = DateTime.now();
      final timestamp = notifier.state.entries.first.timestamp;

      expect(
        timestamp.isAfter(before) || timestamp.isAtSameMomentAs(before),
        true,
      );
      expect(
        timestamp.isBefore(after) || timestamp.isAtSameMomentAs(after),
        true,
      );
    });

    test('circular buffer trims to maxEntries when exceeded', () {
      final notifier = DebugLogNotifier();

      // Add maxEntries + 10 entries
      for (var i = 0; i < DebugLogState.maxEntries + 10; i++) {
        notifier.addLog('Message $i');
      }

      expect(notifier.state.entries.length, DebugLogState.maxEntries);
      // Oldest entries should be trimmed, newest retained
      expect(
        notifier.state.entries.first.message,
        'Message 10',
        reason: 'First 10 entries should be trimmed',
      );
      expect(
        notifier.state.entries.last.message,
        'Message ${DebugLogState.maxEntries + 9}',
      );
    });

    test('circular buffer trims correctly at exactly maxEntries', () {
      final notifier = DebugLogNotifier();

      // Add exactly maxEntries entries
      for (var i = 0; i < DebugLogState.maxEntries; i++) {
        notifier.addLog('Message $i');
      }

      expect(notifier.state.entries.length, DebugLogState.maxEntries);

      // Add one more - should trigger trim
      notifier.addLog('Message ${DebugLogState.maxEntries}');

      expect(notifier.state.entries.length, DebugLogState.maxEntries);
      expect(
        notifier.state.entries.first.message,
        'Message 1',
        reason: 'Message 0 should be trimmed',
      );
      expect(
        notifier.state.entries.last.message,
        'Message ${DebugLogState.maxEntries}',
      );
    });

    group('level inference', () {
      test('infers error level from "error" keyword', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('An error occurred');

        expect(notifier.state.entries.first.level, LogLevel.error);
      });

      test('infers error level from "Error" keyword (case insensitive)', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Error: connection failed');

        expect(notifier.state.entries.first.level, LogLevel.error);
      });

      test('infers error level from "ERROR" keyword (case insensitive)', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('CRITICAL ERROR');

        expect(notifier.state.entries.first.level, LogLevel.error);
      });

      test('infers error level from "failed" keyword', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Operation failed');

        expect(notifier.state.entries.first.level, LogLevel.error);
      });

      test('infers error level from "Failed" keyword (case insensitive)', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Request Failed: timeout');

        expect(notifier.state.entries.first.level, LogLevel.error);
      });

      test('infers warning level from "warning" keyword', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('This is a warning');

        expect(notifier.state.entries.first.level, LogLevel.warning);
      });

      test(
        'infers warning level from "Warning" keyword (case insensitive)',
        () {
          final notifier = DebugLogNotifier();

          notifier.addLog('Warning: low battery');

          expect(notifier.state.entries.first.level, LogLevel.warning);
        },
      );

      test('infers warning level from "warn" keyword', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Warn: deprecated API');

        expect(notifier.state.entries.first.level, LogLevel.warning);
      });

      test('infers info level from "info" keyword', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Info: user logged in');

        expect(notifier.state.entries.first.level, LogLevel.info);
      });

      test('infers info level from "INFO" keyword (case insensitive)', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('INFO - session started');

        expect(notifier.state.entries.first.level, LogLevel.info);
      });

      test('defaults to debug level for generic messages', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Just a regular message');

        expect(notifier.state.entries.first.level, LogLevel.debug);
      });

      test('defaults to debug level for empty string', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('');

        expect(notifier.state.entries.first.level, LogLevel.debug);
      });

      test('prioritizes error over warning when both keywords present', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Warning: error occurred');

        expect(
          notifier.state.entries.first.level,
          LogLevel.error,
          reason: 'Error should take precedence',
        );
      });

      test('prioritizes error over info when both keywords present', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Info: operation failed');

        expect(
          notifier.state.entries.first.level,
          LogLevel.error,
          reason: 'Error should take precedence',
        );
      });

      test('prioritizes warning over info when both keywords present', () {
        final notifier = DebugLogNotifier();

        notifier.addLog('Info: warning - high latency');

        expect(
          notifier.state.entries.first.level,
          LogLevel.warning,
          reason: 'Warning should take precedence',
        );
      });
    });

    group('toggleOverlay', () {
      test('flips isVisible from false to true', () {
        final notifier = DebugLogNotifier();

        expect(notifier.state.isVisible, false);

        notifier.toggleOverlay();

        expect(notifier.state.isVisible, true);
      });

      test('flips isVisible from true to false', () {
        final notifier = DebugLogNotifier();

        notifier.toggleOverlay(); // false -> true

        expect(notifier.state.isVisible, true);

        notifier.toggleOverlay(); // true -> false

        expect(notifier.state.isVisible, false);
      });

      test('toggles multiple times correctly', () {
        final notifier = DebugLogNotifier();

        for (var i = 0; i < 5; i++) {
          notifier.toggleOverlay();
          // After i+1 toggles, visibility should match (i+1).isOdd
          final expectedVisibility = (i + 1).isOdd;
          expect(notifier.state.isVisible, expectedVisibility);
        }
      });

      test('does not affect entries when toggling', () {
        final notifier = DebugLogNotifier();

        notifier
          ..addLog('Entry 1')
          ..addLog('Entry 2');

        final entriesBeforeToggle = notifier.state.entries;

        notifier.toggleOverlay();

        expect(notifier.state.entries, entriesBeforeToggle);
        expect(notifier.state.entries.length, 2);
      });
    });

    group('clearLogs', () {
      test('empties entries list', () {
        final notifier = DebugLogNotifier();

        notifier
          ..addLog('Entry 1')
          ..addLog('Entry 2')
          ..addLog('Entry 3');

        expect(notifier.state.entries.length, 3);

        notifier.clearLogs();

        expect(notifier.state.entries, isEmpty);
      });

      test('does not affect isVisible when clearing', () {
        final notifier = DebugLogNotifier();

        notifier
          ..addLog('Entry 1')
          ..toggleOverlay(); // Make visible

        expect(notifier.state.isVisible, true);

        notifier.clearLogs();

        expect(notifier.state.entries, isEmpty);
        expect(notifier.state.isVisible, true);
      });

      test('can clear empty entries list without error', () {
        final notifier = DebugLogNotifier();

        expect(notifier.state.entries, isEmpty);

        notifier.clearLogs();

        expect(notifier.state.entries, isEmpty);
      });

      test('can add entries after clearing', () {
        final notifier = DebugLogNotifier();

        notifier
          ..addLog('Entry 1')
          ..clearLogs()
          ..addLog('Entry 2');

        expect(notifier.state.entries.length, 1);
        expect(notifier.state.entries.first.message, 'Entry 2');
      });
    });

    group('LogEntry', () {
      test('is immutable', () {
        final now = DateTime.now();
        final entry = LogEntry(
          timestamp: now,
          message: 'Test',
          level: LogLevel.info,
        );

        expect(entry.timestamp, now);
        expect(entry.message, 'Test');
        expect(entry.level, LogLevel.info);
      });
    });

    group('DebugLogState', () {
      test('has correct default values', () {
        const state = DebugLogState();

        expect(state.entries, isEmpty);
        expect(state.isVisible, false);
      });

      test('maxEntries is 500', () {
        expect(DebugLogState.maxEntries, 500);
      });

      test('copyWith preserves unspecified fields', () {
        const original = DebugLogState(
          entries: [
            LogEntry(
              timestamp: const FakeDateTime(),
              message: 'Test',
              level: LogLevel.info,
            ),
          ],
          isVisible: true,
        );

        final copied = original.copyWith();

        expect(copied.entries, original.entries);
        expect(copied.isVisible, original.isVisible);
      });

      test('copyWith replaces specified fields', () {
        const original = DebugLogState(
          entries: [
            LogEntry(
              timestamp: const FakeDateTime(),
              message: 'Test',
              level: LogLevel.info,
            ),
          ],
          isVisible: true,
        );

        final copied = original.copyWith(entries: [], isVisible: false);

        expect(copied.entries, isEmpty);
        expect(copied.isVisible, false);
      });
    });
  });
}

/// Fake DateTime for testing immutable LogEntry construction.
class FakeDateTime implements DateTime {
  const FakeDateTime();

  @override
  bool get isUtc => true;

  @override
  DateTime add(Duration duration) => this;

  @override
  int compareTo(DateTime other) => 0;

  @override
  int get day => 1;

  @override
  DateTime subtract(Duration duration) => this;

  @override
  Duration difference(DateTime other) => Duration.zero;

  @override
  int get hour => 0;

  @override
  bool isAfter(DateTime other) => false;

  @override
  bool isAtSameMomentAs(DateTime other) => true;

  @override
  bool isBefore(DateTime other) => false;

  @override
  int get microsecond => 0;

  @override
  int get microsecondsSinceEpoch => 0;

  @override
  int get millisecond => 0;

  @override
  int get millisecondsSinceEpoch => 0;

  @override
  int get minute => 0;

  @override
  int get month => 1;

  @override
  int get second => 0;

  @override
  String get timeZoneName => 'UTC';

  @override
  Duration get timeZoneOffset => Duration.zero;

  @override
  DateTime toLocal() => this;

  @override
  String toIso8601String() => '2024-01-01T00:00:00.000Z';

  @override
  DateTime toUtc() => this;

  @override
  int get weekday => 1;

  @override
  int get year => 2024;

  @override
  String toString() => toIso8601String();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
