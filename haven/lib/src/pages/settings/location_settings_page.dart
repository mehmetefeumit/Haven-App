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
import 'package:haven/src/widgets/widgets.dart';
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

class _LocationSettingsPageState extends ConsumerState<LocationSettingsPage>
    with WidgetsBindingObserver {
  /// Whether an async toggle operation is in progress.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-reads the two iOS states this page renders from, on every return to
  /// the foreground.
  ///
  /// Both can change while the user is away, in the same trip to Settings: the
  /// authorization tier when they answer the "Always" prompt, and the
  /// indicator sentence when the resulting service-session diagnostic confirms
  /// that Always — which releases the activity session and, with it, the blue
  /// bar this page would otherwise still be promising.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    ref
      ..invalidate(iosLocationPermissionProvider)
      ..invalidate(iosIndicatorSentenceProvider);
  }

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
        // Disabling disarms the native session handler, which clears the
        // confirmation the indicator sentence is read from — so the reading
        // this page holds is now a teardown residue, not a tier. Re-read it
        // for the same reason the enable path does: without this, a user who
        // toggles off and on again in one visit is shown a different sentence
        // than a fresh visit to the identical device state would show.
        // Sequenced AFTER the await so the native `disarm` (dispatched from
        // inside `setEnabled`) is already queued on the same channel this
        // re-read travels.
        ref.invalidate(iosIndicatorSentenceProvider);
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
            // escalation prompt (triggered inside setEnabled) has resolved,
            // and the indicator reading now that `arm()` has run: enabling is
            // what creates (or, under a confirmed Always, declines to create)
            // the session that puts the blue bar on screen. Both drive
            // build(); invalidating re-reads the native state. No-ops on
            // non-iOS (the providers report always / not held there).
            ref
              ..invalidate(iosLocationPermissionProvider)
              ..invalidate(iosIndicatorSentenceProvider);
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

    // iOS only. Reports always (not limited) on non-iOS, so neither the note
    // nor the guidance card below can show there.
    final iosTier = ref.watch(iosLocationPermissionProvider).valueOrNull;

    // True when background sharing is enabled but the granted authorization is
    // still while-in-use, so Haven cannot catch up after iOS closes the app.
    // Drives the inline "Always required" note below.
    final iosLimited = iosTier == IosAuthStatus.whenInUse;

    // Which indicator the user actually sees, decided by the session handler's
    // own state rather than by the tier — a provisional Always reports
    // `.authorizedAlways` while the OS still treats the app as When-In-Use.
    //
    // Null in the two cases that are really one: the handler has not answered
    // yet, or it is disarmed and has therefore measured nothing (background
    // sharing off, background disclosure unaccepted, authorization not
    // granted). Either way no indicator sentence is known to be true of this
    // reader, and the card below waits rather than guessing one.
    final iosIndicator = ref.watch(iosIndicatorSentenceProvider).valueOrNull;

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
            const AndroidReliabilityCard(),
          ]
          // The iOS guidance card, under two conditions that are one promise:
          // every sentence in it has to be true of THIS user.
          //
          // 1. `IosAuthStatus.always` only. It used to render for every
          //    non-while-in-use reading, so a user who had DENIED location was
          //    told how their location session behaves.
          // 2. Only once the indicator reading has resolved AND the handler
          //    has something to report. One of the two sentences names what
          //    the user can SEE while sharing, and there is no honest sentence
          //    to pick before the session handler has answered — nor while it
          //    is disarmed, where its `alwaysConfirmed` is cleared by
          //    `disarm()` and would otherwise read as a measured "not
          //    confirmed" and promise the blue bar to a reader whose next
          //    enable may well release the bar. So the card waits rather than
          //    guessing. That is also why background sharing being OFF needs
          //    no separate gate here: an off toggle is a disarmed handler.
          //
          // There is deliberately no third sentence urging the reader to
          // GRANT "Always": condition 1 means every reader of this card
          // already holds it, so such a sentence would contradict the one
          // before it and ask for a permission the reader has. One was
          // composed here while the card still covered the non-Always tiers,
          // and was deleted with its key once this gate left it no reader. The
          // cohort the advice IS for, while-in-use, gets it above from
          // `locationSettingsIosLimitedNote`, framed as an instruction and
          // carrying the button that acts on it.
          else if (iosTier == IosAuthStatus.always && iosIndicator != null) ...[
            const SizedBox(height: HavenSpacing.base),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(HavenSpacing.base),
                // ONE Text, not two: VoiceOver reads the card as a single
                // paragraph rather than two separate swipes. Session first,
                // then the indicator that session puts on screen.
                //
                // bodyMedium, matching the page's intro paragraph: this is
                // the only card an iPhone renders, so there is no denser
                // sibling to match, and the one paragraph whose job is to say
                // what the OS will show should not be the smallest text on
                // the page.
                child: Text(
                  '${l10n.locationSettingsIosGuidance} '
                  '${_indicatorSentence(l10n, iosIndicator)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
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

/// The one indicator sentence that is true while the handler is in [which].
///
/// The choice is made from the session handler's OWN state, never from the
/// authorization tier: a provisional "Always" reports `.authorizedAlways`
/// while the OS still treats the app as While-In-Use, and that user keeps the
/// activity session and therefore the blue location bar.
String _indicatorSentence(AppLocalizations l10n, IosIndicatorSentence which) =>
    switch (which) {
      IosIndicatorSentence.arrow => l10n.locationSettingsIosIndicatorArrow,
      IosIndicatorSentence.bar => l10n.locationSettingsIosIndicatorBar,
    };

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
