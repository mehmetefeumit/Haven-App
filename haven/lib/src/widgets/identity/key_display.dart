/// Key display widget for Haven.
///
/// Secure display of cryptographic keys with copy and reveal functionality.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/theme/theme.dart';

/// Displays a cryptographic key with secure handling.
///
/// Features:
/// - Truncated display by default for privacy
/// - Optional reveal toggle for full key viewing
/// - Copy to clipboard functionality
/// - Monospace font for readability
class KeyDisplay extends StatefulWidget {
  /// Creates a key display widget.
  ///
  /// The [keyValue] is the full key string to display.
  /// The [label] describes what type of key this is.
  const KeyDisplay({
    required this.keyValue,
    required this.label,
    super.key,
    this.allowReveal = true,
    this.allowCopy = true,
    this.truncateLength = 12,
  });

  /// The full key value to display.
  final String keyValue;

  /// Label describing the key type (e.g., "Public Key", "npub").
  final String label;

  /// Whether to show the reveal toggle button.
  final bool allowReveal;

  /// Whether to show the copy button.
  final bool allowCopy;

  /// Number of characters to show at start and end when truncated.
  final int truncateLength;

  @override
  State<KeyDisplay> createState() => _KeyDisplayState();
}

class _KeyDisplayState extends State<KeyDisplay> {
  bool _isRevealed = false;

  String get _displayValue {
    if (_isRevealed || widget.keyValue.length <= widget.truncateLength * 2) {
      return widget.keyValue;
    }

    final start = widget.keyValue.substring(0, widget.truncateLength);
    final end = widget.keyValue.substring(
      widget.keyValue.length - widget.truncateLength,
    );
    return '$start...$end';
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: widget.keyValue));

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.label} copied to clipboard'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _toggleReveal() {
    setState(() {
      _isRevealed = !_isRevealed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: '${widget.label}: ${_isRevealed ? widget.keyValue : 'hidden'}',
      child: Container(
        padding: const EdgeInsets.all(HavenSpacing.md),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(HavenSpacing.sm),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.key, size: 16, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: HavenSpacing.sm),
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (widget.allowReveal)
                  _ActionButton(
                    icon: _isRevealed ? Icons.visibility_off : Icons.visibility,
                    tooltip: _isRevealed ? 'Hide' : 'Reveal',
                    onPressed: _toggleReveal,
                  ),
                if (widget.allowCopy)
                  _ActionButton(
                    icon: Icons.copy,
                    tooltip: 'Copy',
                    onPressed: _copyToClipboard,
                  ),
              ],
            ),
            const SizedBox(height: HavenSpacing.sm),
            SelectableText(
              _displayValue,
              style: HavenTypography.monoStyle(context).copyWith(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(HavenSpacing.xs),
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.sm),
            child: Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact inline key display for lists.
///
/// Shows only the truncated key with a copy button on tap.
class CompactKeyDisplay extends StatelessWidget {
  /// Creates a compact key display.
  const CompactKeyDisplay({
    required this.keyValue,
    super.key,
    this.truncateLength = 8,
  });

  /// The full key value.
  final String keyValue;

  /// Characters to show at start and end.
  final int truncateLength;

  String get _truncatedValue {
    if (keyValue.length <= truncateLength * 2) {
      return keyValue;
    }

    final start = keyValue.substring(0, truncateLength);
    final end = keyValue.substring(keyValue.length - truncateLength);
    return '$start...$end';
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: keyValue));

    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Key copied to clipboard'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Tap to copy',
      child: InkWell(
        onTap: () => _copyToClipboard(context),
        borderRadius: BorderRadius.circular(HavenSpacing.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.sm,
            vertical: HavenSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _truncatedValue,
                style: HavenTypography.monoStyle(
                  context,
                ).copyWith(fontSize: 12),
              ),
              const SizedBox(width: HavenSpacing.xs),
              Icon(
                Icons.copy,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
