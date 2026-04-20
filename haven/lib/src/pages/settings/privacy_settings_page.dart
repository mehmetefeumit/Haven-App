/// Privacy settings page for Haven.
///
/// Controls location precision and sharing preferences.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_precision_provider.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page for configuring privacy settings.
class PrivacySettingsPage extends ConsumerStatefulWidget {
  /// Creates a privacy settings page.
  const PrivacySettingsPage({super.key});

  @override
  ConsumerState<PrivacySettingsPage> createState() =>
      _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends ConsumerState<PrivacySettingsPage> {
  void _onPrecisionChanged(PrivacyLevel level) {
    ref.read(locationPrecisionProvider.notifier).setPrecision(level);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          level == PrivacyLevel.hidden
              ? 'Location sharing disabled'
              : 'Precision set to ${level.label}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentPrecision = ref.watch(locationPrecisionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Settings'),
        actions: const [
          EncryptionBadge(size: EncryptionBadgeSize.small),
          SizedBox(width: HavenSpacing.base),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(HavenSpacing.base),
        children: [
          // Info card
          Card(
            color: colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(HavenSpacing.base),
              child: Row(
                children: [
                  Icon(Icons.shield, color: colorScheme.onPrimaryContainer),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: Text(
                      'Your location is always encrypted and only visible '
                      'to circle members. These settings control how '
                      'precisely your location is shared.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: HavenSpacing.lg),

          // Hidden-mode warning — shown when location sharing is off.
          if (currentPrecision == PrivacyLevel.hidden) ...[
            Card(
              color: HavenPrivacyColors.hidden.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(HavenSpacing.base),
                child: Row(
                  children: [
                    const Icon(
                      Icons.visibility_off,
                      color: HavenPrivacyColors.hidden,
                    ),
                    const SizedBox(width: HavenSpacing.md),
                    Expanded(
                      child: Text(
                        'Location sharing is disabled. Your position is '
                        'not sent to any circle.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: HavenPrivacyColors.hidden,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
          ],

          // Precision section
          Text(
            'Location Precision',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: HavenSpacing.sm),
          Text(
            'Choose how precisely your location is shared. '
            'Select "Hidden" to stop sharing entirely.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: HavenSpacing.base),

          // Precision selector
          PrecisionSelector(
            selected: currentPrecision,
            onChanged: _onPrecisionChanged,
          ),

          const SizedBox(height: HavenSpacing.xl),

          // Background sharing section
          Text(
            'Background Sharing',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: HavenSpacing.sm),
          Text(
            'Continue sharing your encrypted location when the app '
            'is in the background.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.base),
          _BackgroundSharingTile(),
        ],
      ),
    );
  }
}

class _BackgroundSharingTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(backgroundSharingProvider);
    final colorScheme = Theme.of(context).colorScheme;

    // Platform-appropriate subtitle (always visible under the toggle).
    final description = Platform.isIOS
        ? "Requires 'Always' location permission. "
              'A blue indicator appears in the status bar while sharing.'
        : 'A notification will appear while sharing is active. '
              'Disable battery optimization for reliable updates. '
              "On Android 11+, set Haven's location permission to "
              "'Allow all the time' in system settings. "
              "On Samsung, also disable 'Sleeping apps' for Haven. "
              "On Xiaomi, enable 'Autostart' and set battery saver to "
              "'No restrictions'.";

    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Share in background'),
            subtitle: Text(description),
            value: enabled,
            onChanged: (value) async {
              final result = await ref
                  .read(backgroundSharingProvider.notifier)
                  .setEnabled(enabled: value);
              if (!context.mounted) return;

              // Determine feedback based on permission result.
              if (result is EnsurePermissionsNotificationDenied) {
                // Toggle reverted to OFF — show error with guidance.
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text(
                      'Notification permission required. Background sharing '
                      'will not work without it. Open system settings to '
                      'grant the permission. Then return here and turn the '
                      'switch back on.',
                    ),
                    duration: const Duration(seconds: 5),
                    action: SnackBarAction(
                      label: 'Open settings',
                      onPressed: () => Geolocator.openAppSettings(),
                    ),
                  ),
                );
                return;
              }

              if (result is EnsurePermissionsBatteryOptDenied) {
                // Toggle stays ON — soft advisory.
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Battery optimization is enabled. Background sharing '
                      'may be unreliable. Disable it in settings for the '
                      'best experience.',
                    ),
                    duration: Duration(seconds: 5),
                  ),
                );
                return;
              }

              // EnsurePermissionsGranted or disabling — silent success /
              // simple confirmation.
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    value
                        ? 'Background sharing enabled'
                        : 'Background sharing disabled',
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          if (enabled) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(HavenSpacing.base),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  Text(
                    'Your location remains end-to-end encrypted',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
