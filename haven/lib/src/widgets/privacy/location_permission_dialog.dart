/// Location permission education dialog for Haven.
///
/// Explains why location is needed and how it's protected
/// before requesting system permission.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Full-screen modal explaining location permission.
///
/// Shows before the system permission dialog to educate users
/// about Haven's privacy-first approach to location sharing.
class LocationPermissionDialog extends StatelessWidget {
  /// Creates a location permission education dialog.
  const LocationPermissionDialog({
    required this.onContinue,
    required this.onCancel,
    super.key,
  });

  /// Callback when user agrees to continue with permission request.
  final VoidCallback onContinue;

  /// Callback when user cancels the permission request.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.lg),
          child: Column(
            children: [
              const Spacer(),
              Icon(Icons.location_on, size: 80, color: colorScheme.primary),
              const SizedBox(height: HavenSpacing.lg),
              Text(
                'Share Your Location Securely',
                style: textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: HavenSpacing.base),
              Text(
                'Haven needs location access to share where you are '
                'with your trusted circles.',
                style: textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: HavenSpacing.xl),
              const _FeatureRow(
                icon: Icons.lock,
                title: 'End-to-End Encrypted',
                description: 'Only your circle members can see your location',
              ),
              const SizedBox(height: HavenSpacing.base),
              const _FeatureRow(
                icon: Icons.visibility_off,
                title: 'You Control Precision',
                description:
                    'Share exact, neighborhood, or city-level location',
              ),
              const SizedBox(height: HavenSpacing.base),
              const _FeatureRow(
                icon: Icons.cloud_off,
                title: 'No Server Storage',
                description: 'Location data is never stored on our servers',
              ),
              const Spacer(flex: 2),
              const EncryptionBadge(showLabel: true),
              const SizedBox(height: HavenSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onContinue,
                  child: const Text('Continue'),
                ),
              ),
              const SizedBox(height: HavenSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: onCancel,
                  child: const Text('Not Now'),
                ),
              ),
              const SizedBox(height: HavenSpacing.base),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row displaying a privacy feature with icon and description.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(HavenSpacing.sm),
          decoration: BoxDecoration(
            color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(HavenSpacing.sm),
          ),
          child: Icon(icon, color: HavenSecurityColors.encrypted),
        ),
        const SizedBox(width: HavenSpacing.base),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: textTheme.titleSmall),
              Text(
                description,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
