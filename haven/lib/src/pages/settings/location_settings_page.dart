/// Location settings page for Haven.
///
/// Allows the user to configure background location sharing and view
/// platform-specific guidance on keeping the service reliable.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings page for location sharing preferences.
///
/// Manages background location sharing, prominent disclosure gating,
/// and surfaces platform-specific reliability guidance.
class LocationSettingsPage extends ConsumerStatefulWidget {
  /// Creates the location settings page.
  const LocationSettingsPage({super.key});

  @override
  ConsumerState<LocationSettingsPage> createState() =>
      _LocationSettingsPageState();
}

class _LocationSettingsPageState extends ConsumerState<LocationSettingsPage> {
  /// Whether an async toggle operation is in progress.
  bool _busy = false;

  /// iOS only: true when background sharing is enabled but the granted
  /// permission is only while-in-use (not "Always").
  bool _iosLimited = false;

  Future<void> _onToggle(bool value) async {
    if (_busy) return;
    if (mounted) setState(() => _busy = true);

    // Capture messenger + l10n BEFORE any await
    // (use_build_context_synchronously).
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);

    try {
      if (!value) {
        // DISABLE — no disclosure gate, no permission gate.
        await ref
            .read(backgroundSharingProvider.notifier)
            .setEnabled(enabled: false);
        if (!mounted) return;
        // Clear any stale iOS "limited in background" note — it must not
        // outlive the feature being on.
        _iosLimited = false;
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.locationSettingsDisabledSnack)),
          );
      } else {
        // ENABLE — disclosure gate first, then permission gate.
        final disclosed = await ref
            .read(locationDisclosureControllerProvider.notifier)
            .ensureDisclosed(context, includeBackground: true);
        if (!mounted) return;
        if (!disclosed) return;

        final result = await ref
            .read(backgroundSharingProvider.notifier)
            .setEnabled(enabled: true);
        if (!mounted) return;

        switch (result) {
          case EnsurePermissionsNotificationDenied():
            messenger
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.locationSettingsNotificationDeniedSnack,
                  ),
                  duration: const Duration(seconds: 8),
                  action: SnackBarAction(
                    label: l10n.commonOpenSettings,
                    onPressed: geo.Geolocator.openAppSettings,
                  ),
                ),
              );

          case EnsurePermissionsBatteryOptDenied():
            messenger
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text(l10n.locationSettingsBatteryOptSnack),
                  duration: const Duration(seconds: 8),
                ),
              );

          case EnsurePermissionsGranted():
          case null:
            messenger
              ..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text(l10n.locationSettingsEnabledSnack),
                ),
              );
            // iOS residual check: if permission is only while-in-use, show
            // the persistent inline note so the user can open Settings.
            // Gate behind Platform.isIOS so Geolocator is never called on
            // the Linux test host.
            if (Platform.isIOS) {
              try {
                final perm = await geo.Geolocator.checkPermission();
                if (mounted) {
                  setState(
                    () => _iosLimited =
                        perm == geo.LocationPermission.whileInUse,
                  );
                }
              } on Object catch (e) {
                debugPrint(
                  '[LocationSettings] iOS perm check: ${e.runtimeType}',
                );
              }
            }
        }
      }
    } on Object catch (e) {
      debugPrint('[LocationSettings] ${e.runtimeType}');
      if (mounted) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.locationSettingsErrorSnack)),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sharingEnabled = ref.watch(backgroundSharingProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.locationSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(HavenSpacing.base),
        children: [
          // Framing paragraph.
          Text(
            l10n.locationSettingsIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.base),

          // Toggle card.
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  key: WidgetKeys.backgroundSharingTile,
                  title: Text(l10n.locationSettingsToggleTitle),
                  subtitle: Text(l10n.locationSettingsToggleSubtitle),
                  value: sharingEnabled,
                  onChanged: _busy ? null : _onToggle,
                ),
              ],
            ),
          ),

          // iOS residual note (only mounted on a real iOS device — _iosLimited
          // is only set inside a `if (Platform.isIOS)` guard in _onToggle,
          // so this branch is never reached on the Linux test host).
          if (Platform.isIOS && sharingEnabled && _iosLimited) ...[
            const SizedBox(height: HavenSpacing.base),
            Card(
              child: ListTile(
                leading: const Icon(
                  LucideIcons.triangleAlert,
                  color: HavenSecurityColors.warning,
                  size: 20,
                ),
                title: Text(l10n.locationSettingsIosLimitedNote),
                trailing: TextButton(
                  onPressed: geo.Geolocator.openAppSettings,
                  child: Text(l10n.commonOpenSettings),
                ),
              ),
            ),
          ],

          // Platform-specific reliability guidance.
          // IMPORTANT: Android strings ('notification', 'battery
          // optimization', etc.) are inside `if (Platform.isAndroid)` so
          // they are absent on the Linux widget-test host. The box is
          // always visible (no expand), so the platform branch — not any
          // expansion state — is what keeps the strings out of tests.
          if (Platform.isAndroid) ...[
            const SizedBox(height: HavenSpacing.base),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(HavenSpacing.base),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          LucideIcons.info,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: HavenSpacing.sm),
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              l10n.locationSettingsAndroidHeader,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: HavenSpacing.sm),
                    Text(
                      l10n.locationSettingsAndroidNotification,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: HavenSpacing.sm),
                    Text(
                      l10n.locationSettingsAndroidBattery,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: HavenSpacing.sm),
                    Text(
                      l10n.locationSettingsAndroidVendors,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (Platform.isIOS && !_iosLimited) ...[
            const SizedBox(height: HavenSpacing.base),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(HavenSpacing.base),
                child: Text(
                  l10n.locationSettingsIosGuidance,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
