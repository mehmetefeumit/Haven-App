/// Privacy settings page for Haven.
///
/// Controls location precision and sharing preferences.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/location_precision_provider.dart';
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

          const SizedBox(height: HavenSpacing.lg),
        ],
      ),
    );
  }
}
