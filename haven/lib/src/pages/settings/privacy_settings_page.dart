/// Privacy settings page for Haven.
///
/// Controls location precision and sharing preferences.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page for configuring privacy settings.
class PrivacySettingsPage extends StatefulWidget {
  /// Creates a privacy settings page.
  const PrivacySettingsPage({super.key});

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  // Default to neighborhood for privacy-first approach
  PrivacyLevel _defaultPrecision = PrivacyLevel.neighborhood;
  bool _stealthMode = false;

  void _onPrecisionChanged(PrivacyLevel level) {
    setState(() {
      _defaultPrecision = level;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Default precision set to ${level.label}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onStealthModeChanged(bool value) {
    setState(() {
      _stealthMode = value;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value ? 'Stealth mode enabled' : 'Stealth mode disabled'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

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

          // Stealth mode toggle
          Card(
            child: SwitchListTile(
              title: const Text('Stealth Mode'),
              subtitle: const Text(
                'Temporarily hide your location from all circles',
              ),
              secondary: Icon(
                _stealthMode ? Icons.visibility_off : Icons.visibility,
                color: _stealthMode
                    ? HavenPrivacyColors.hidden
                    : colorScheme.onSurfaceVariant,
              ),
              value: _stealthMode,
              onChanged: _onStealthModeChanged,
            ),
          ),

          if (_stealthMode) ...[
            const SizedBox(height: HavenSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.sm),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: HavenPrivacyColors.hidden,
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  Expanded(
                    child: Text(
                      'Your location is hidden from all circles while '
                      'stealth mode is active.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: HavenPrivacyColors.hidden,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: HavenSpacing.lg),

          // Default precision section
          Text(
            'Default Precision',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: HavenSpacing.sm),
          Text(
            'Choose how precisely your location is shared by default. '
            'You can override this for individual circles.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: HavenSpacing.base),

          // Precision selector
          PrecisionSelector(
            selected: _defaultPrecision,
            onChanged: _onPrecisionChanged,
          ),

          const SizedBox(height: HavenSpacing.lg),
        ],
      ),
    );
  }
}
