/// Debug log provider for Haven.
///
/// Provides in-memory log capture and overlay state for on-device debugging.
/// All state is session-only (not persisted) for privacy. Fully gated behind
/// [kDebugMode] so it is tree-shaken from release builds.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Severity level for a log entry.
enum LogLevel {
  /// Verbose debug output.
  debug,

  /// Informational messages.
  info,

  /// Potential problems.
  warning,

  /// Failures and errors.
  error,
}

/// A single captured log entry.
@immutable
class LogEntry {
  /// Creates a log entry.
  const LogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });

  /// When the log was captured.
  final DateTime timestamp;

  /// The log message text.
  final String message;

  /// Inferred severity level.
  final LogLevel level;
}

/// Immutable state for the debug log overlay.
@immutable
class DebugLogState {
  /// Creates the debug log state.
  const DebugLogState({this.entries = const [], this.isVisible = false});

  /// Captured log entries (newest last).
  final List<LogEntry> entries;

  /// Whether the overlay is currently visible.
  final bool isVisible;

  /// Maximum number of entries to retain (circular buffer).
  static const int maxEntries = 500;

  /// Returns a copy with the given fields replaced.
  DebugLogState copyWith({List<LogEntry>? entries, bool? isVisible}) {
    return DebugLogState(
      entries: entries ?? this.entries,
      isVisible: isVisible ?? this.isVisible,
    );
  }
}

/// Infers [LogLevel] from message content keywords.
LogLevel _inferLevel(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('error') || lower.contains('failed')) {
    return LogLevel.error;
  }
  if (lower.contains('warning') || lower.contains('warn')) {
    return LogLevel.warning;
  }
  if (lower.contains('info')) {
    return LogLevel.info;
  }
  return LogLevel.debug;
}

/// Notifier that manages debug log state.
///
/// Provides methods to append logs, toggle overlay visibility, and clear
/// the log buffer. Entries are capped at [DebugLogState.maxEntries].
class DebugLogNotifier extends StateNotifier<DebugLogState> {
  /// Creates the debug log notifier with empty initial state.
  DebugLogNotifier() : super(const DebugLogState());

  /// Appends a log entry, trimming to [DebugLogState.maxEntries].
  void addLog(String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: message,
      level: _inferLevel(message),
    );
    final updated = [...state.entries, entry];
    if (updated.length > DebugLogState.maxEntries) {
      updated.removeRange(0, updated.length - DebugLogState.maxEntries);
    }
    state = state.copyWith(entries: updated);
  }

  /// Toggles the overlay visibility.
  void toggleOverlay() {
    state = state.copyWith(isVisible: !state.isVisible);
  }

  /// Clears all captured log entries.
  void clearLogs() {
    state = state.copyWith(entries: []);
  }
}

/// Provider for debug log state.
///
/// Only meaningful in debug mode. In release builds, the notifier exists
/// but is never fed log data (zone interception is skipped).
final debugLogProvider = StateNotifierProvider<DebugLogNotifier, DebugLogState>(
  (ref) {
    return DebugLogNotifier();
  },
);
