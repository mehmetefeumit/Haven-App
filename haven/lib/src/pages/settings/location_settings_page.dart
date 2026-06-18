/// Location settings page for Haven.
///
/// Allows the user to configure background location sharing and view
/// platform-specific guidance on keeping the service reliable.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
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

    // Capture messenger BEFORE any await (use_build_context_synchronously).
    final messenger = ScaffoldMessenger.of(context);

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
            const SnackBar(content: Text('Background sharing disabled')),
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
                const SnackBar(
                  content: Text(
                    'Background sharing needs a notification so Android'
                    " keeps it running. It's off for now. Enable"
                    ' notifications for Haven to turn it on.',
                  ),
                  duration: Duration(seconds: 8),
                  action: SnackBarAction(
                    label: 'Open settings',
                    onPressed: geo.Geolocator.openAppSettings,
                  ),
                ),
              );

          case EnsurePermissionsBatteryOptDenied():
            messenger
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'On. Battery optimization may pause sharing on some'
                    ' phones. Exclude Haven from battery optimization'
                    ' to keep it reliable.',
                  ),
                  duration: Duration(seconds: 8),
                ),
              );

          case EnsurePermissionsGranted():
          case null:
            messenger
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text('Background sharing enabled'),
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
            const SnackBar(content: Text('Something went wrong')),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sharingEnabled = ref.watch(backgroundSharingProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Location')),
      body: ListView(
        padding: const EdgeInsets.all(HavenSpacing.base),
        children: [
          // Framing paragraph.
          Text(
            'When background sharing is on, your circles keep seeing your '
            'live location even when Haven is closed.',
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
                  title: const Text('Share in background'),
                  subtitle: const Text(
                    'Keep sharing when the app is closed',
                  ),
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
            const Card(
              child: ListTile(
                leading: Icon(
                  LucideIcons.triangleAlert,
                  color: HavenSecurityColors.warning,
                  size: 20,
                ),
                title: Text(
                  "Limited in background. Set Location to 'Always' for "
                  'Haven in Settings',
                ),
                trailing: TextButton(
                  onPressed: geo.Geolocator.openAppSettings,
                  child: Text('Open settings'),
                ),
              ),
            ),
          ],

          // Platform-specific reliability guidance.
          // IMPORTANT: Android strings ('notification', 'battery
          // optimization', etc.) are inside `if (Platform.isAndroid)` so
          // they are absent on the Linux widget-test host. ExpansionTile
          // keeps children in the tree when collapsed, so the platform
          // branch (not expansion state) prevents the strings from
          // appearing in tests.
          if (Platform.isAndroid) ...[
            const SizedBox(height: HavenSpacing.base),
            Card(
              child: ExpansionTile(
                leading: const Icon(LucideIcons.info, size: 20),
                title: const Text(
                  'OS settings for reliability',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      HavenSpacing.base,
                      0,
                      HavenSpacing.base,
                      HavenSpacing.base,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Haven needs a persistent notification so Android'
                          ' keeps the background service alive. If you'
                          ' denied the notification permission, open'
                          ' Settings and allow notifications for Haven.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: HavenSpacing.sm),
                        Text(
                          'For reliable background sharing, also exclude'
                          ' Haven from battery optimization. Go to'
                          ' Settings → Apps → Haven → Battery →'
                          ' Allow all the time.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: HavenSpacing.sm),
                        Text(
                          'On Samsung devices, remove Haven from "Sleeping'
                          ' apps" (Device care → Battery → Background'
                          ' usage limits). On Xiaomi, enable Autostart'
                          ' for Haven.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else if (Platform.isIOS && !_iosLimited) ...[
            const SizedBox(height: HavenSpacing.base),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(HavenSpacing.base),
                child: Text(
                  'For continuous background sharing, set Location to'
                  ' "Always" for Haven in Settings. iOS shows a blue'
                  ' status-bar indicator while an app is using your'
                  ' location in the background.',
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
