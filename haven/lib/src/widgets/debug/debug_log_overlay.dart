/// Debug log overlay widget for Haven.
///
/// Displays captured log output in a semi-transparent panel covering the
/// bottom half of the screen. Only functional in debug builds; gated
/// behind [kDebugMode] as defense-in-depth.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/debug_log_provider.dart';
import 'package:haven/src/theme/theme.dart';

/// Colors for each [LogLevel] in the overlay.
const _levelColors = {
  LogLevel.debug: Colors.white70,
  LogLevel.info: Colors.greenAccent,
  LogLevel.warning: Colors.orangeAccent,
  LogLevel.error: Colors.redAccent,
};

/// Short labels for each [LogLevel].
const _levelLabels = {
  LogLevel.debug: 'DBG',
  LogLevel.info: 'INF',
  LogLevel.warning: 'WRN',
  LogLevel.error: 'ERR',
};

/// A semi-transparent overlay showing debug log output.
///
/// Positioned at the bottom half of the screen with auto-scroll behavior.
/// Only renders content when [kDebugMode] is true.
class DebugLogOverlay extends ConsumerStatefulWidget {
  /// Creates the debug log overlay.
  const DebugLogOverlay({super.key});

  @override
  ConsumerState<DebugLogOverlay> createState() => _DebugLogOverlayState();
}

class _DebugLogOverlayState extends ConsumerState<DebugLogOverlay> {
  final ScrollController _scrollController = ScrollController();
  bool _isAtBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final atBottom =
        _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 20;
    if (atBottom != _isAtBottom) {
      _isAtBottom = atBottom;
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients && _isAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Defense-in-depth: never render in release builds.
    if (!kDebugMode) return const SizedBox.shrink();

    final logState = ref.watch(debugLogProvider);
    if (!logState.isVisible) return const SizedBox.shrink();
    final entries = logState.entries;

    // Auto-scroll when new entries arrive and user is at bottom.
    _scrollToBottom();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: MediaQuery.of(context).size.height * 0.5,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(HavenSpacing.md),
          ),
        ),
        child: Column(
          children: [
            _buildHeader(context, entries.length),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs yet',
                        style: TextStyle(
                          color: Colors.white38,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: HavenSpacing.sm,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) =>
                          _buildLogEntry(entries[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.md,
        vertical: HavenSpacing.sm,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white24)),
      ),
      child: Row(
        children: [
          const Text(
            'Debug Log',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: HavenSpacing.sm),
          Text(
            '($count)',
            style: const TextStyle(
              color: Colors.white54,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          const Spacer(),
          _HeaderButton(
            icon: Icons.delete_outline,
            tooltip: 'Clear logs',
            onPressed: () => ref.read(debugLogProvider.notifier).clearLogs(),
          ),
          _HeaderButton(
            icon: Icons.close,
            tooltip: 'Close overlay',
            onPressed: () =>
                ref.read(debugLogProvider.notifier).toggleOverlay(),
          ),
        ],
      ),
    );
  }

  Widget _buildLogEntry(LogEntry entry) {
    final color = _levelColors[entry.level] ?? Colors.white70;
    final label = _levelLabels[entry.level] ?? 'DBG';
    final time =
        '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
        '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
        '${entry.timestamp.second.toString().padLeft(2, '0')}.'
        '${entry.timestamp.millisecond.toString().padLeft(3, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text.rich(
        TextSpan(
          style: HavenTypography.monoSmall.copyWith(color: Colors.white70),
          children: [
            TextSpan(
              text: '$time ',
              style: const TextStyle(color: Colors.white38),
            ),
            TextSpan(
              text: '$label ',
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
            TextSpan(text: entry.message),
          ],
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon, size: 18, color: Colors.white70),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
      ),
    );
  }
}
