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
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
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

        // Every enable path re-probes the battery-optimization exemption, so
        // re-read the verdict `setEnabled` just persisted. The standing
        // advisory below then appears (or clears) without leaving the page.
        ref.invalidate(batteryOptimizationDeniedProvider);
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

  /// Opens Android's battery-optimization screen and re-reads the verdict.
  ///
  /// The system screen reports nothing back, so the exemption is re-probed
  /// when the user returns; invalidating is what clears the advisory once they
  /// grant it.
  Future<void> _openBatteryOptimizationSettings() async {
    await ref.read(openBatteryOptimizationSettingsProvider)();
    if (!mounted) return;
    ref.invalidate(batteryOptimizationDeniedProvider);
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

    // Android only: background sharing is on but Android still applies
    // battery optimization to Haven. The provider owns both the platform gate
    // and the live OS probe (it answers `false` off Android), so this branch
    // is reachable in widget tests — the guidance card below deliberately is
    // not.
    final batteryOptDenied =
        ref.watch(batteryOptimizationDeniedProvider).valueOrNull ?? false;

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
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => Navigator.push(
                context,
                PrivacyTopicPage.route(PrivacyTopic.whatOthersSee),
              ),
              child: Text(l10n.commonLearnMore),
            ),
          ),
          const SizedBox(height: HavenSpacing.sm),

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
            _ActionableNote(
              icon: LucideIcons.triangleAlert,
              message: l10n.locationSettingsIosLimitedNote,
              actionLabel: l10n.commonOpenSettings,
              onAction: geo.Geolocator.openAppSettings,
            ),
          ],

          // Android residual note: sharing is on but Android may still
          // battery-optimize Haven, which is how OEM battery managers kill a
          // long-running foreground service. The one-off snackbar said this
          // once, at the moment the user declined; this line is what makes the
          // state discoverable afterwards.
          if (sharingEnabled && batteryOptDenied) ...[
            const SizedBox(height: HavenSpacing.base),
            _ActionableNote(
              icon: LucideIcons.batteryWarning,
              message: l10n.locationSettingsBatteryOptNote,
              actionLabel: l10n.commonOpenSettings,
              onAction: _openBatteryOptimizationSettings,
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

/// A warning note with one action, laid out so it survives a 200 % text scale.
///
/// NOT a `ListTile` with a `trailing:` button, which is what both of these
/// notes used to be: `ListTile` gives the trailing widget its intrinsic width
/// first, and at the largest text scale both platforms offer a button reading
/// "Open settings" consumes the whole tile on a 320 pt phone — Flutter then
/// asserts ("Trailing widget consumes the entire tile width") and the note is
/// replaced by an error box. Stacking the action UNDER the message lets both
/// wrap instead.
class _ActionableNote extends StatelessWidget {
  const _ActionableNote({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  color: HavenSecurityColors.warning,
                  size: 20,
                ),
                const SizedBox(width: HavenSpacing.md),
                Expanded(child: Text(message)),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
