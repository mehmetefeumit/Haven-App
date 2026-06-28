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
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/ios_location_auth_service.dart';
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
                  content: Text(l10n.locationSettingsNotificationDeniedSnack),
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
                SnackBar(content: Text(l10n.locationSettingsEnabledSnack)),
              );
            // Refresh the iOS authorization reading now that the Always
            // escalation prompt (triggered inside setEnabled) has resolved.
            // The "limited in background" note is driven off
            // [iosLocationPermissionProvider] in build(); invalidating it
            // re-reads the native status. No-op on non-iOS (the provider
            // reports always there).
            ref.invalidate(iosLocationPermissionProvider);
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

    // iOS only: true when background sharing is enabled but the granted
    // authorization is still while-in-use, so background delivery will not
    // survive the app being suspended or the device locking. Drives the
    // inline "Always required" note below. Reports always (not limited) on
    // non-iOS, so the note never shows there.
    final iosLimited =
        ref.watch(iosLocationPermissionProvider).valueOrNull ==
        IosAuthStatus.whenInUse;

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

          // iOS residual note: background sharing is on but only while-in-use
          // is granted, so it will stop once the app is suspended or the phone
          // locks. [iosLimited] is false on non-iOS (provider reports always),
          // so this never renders off iOS.
          if (sharingEnabled && iosLimited) ...[
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
          ] else if (Platform.isIOS && !iosLimited) ...[
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
