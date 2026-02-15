/// Settings floating button widget for Haven.
///
/// A floating circular button that provides access to the settings page
/// from the map view. In debug mode, long-press toggles the debug log overlay.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/settings/settings_page.dart';
import 'package:haven/src/providers/debug_log_provider.dart';

/// A floating button that navigates to the settings page.
///
/// Designed to be positioned in the top-right corner of the map view,
/// respecting safe area insets. Styled consistently with other floating
/// controls like [MapControls].
///
/// In debug builds, a long-press toggles the debug log overlay without
/// navigating to settings.
class SettingsFloatingButton extends ConsumerWidget {
  /// Creates a settings floating button.
  const SettingsFloatingButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onLongPress: kDebugMode
          ? () => ref.read(debugLogProvider.notifier).toggleOverlay()
          : null,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: IconButton(
          icon: const Icon(Icons.settings),
          color: colorScheme.onSurface,
          tooltip: 'Settings',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) => const SettingsPage(),
              ),
            );
          },
        ),
      ),
    );
  }
}
