/// The map's mid-session "location access is gone" surface.
///
/// A non-blocking banner rather than a full-screen error, deliberately: the
/// user's OWN location being unreadable says nothing about their circles'
/// locations, which are still live and still worth looking at. Covering the map
/// would remove information the outage did not actually take away.
///
/// The banner is driven entirely by [locationAccessProvider], so it follows the
/// OS state in both directions within one session — appearing when access is
/// lost and disappearing when it returns, with no restart and no dismiss
/// affordance (a dismissible banner would let the user hide a condition that is
/// still true).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/location_access_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The remedy offered alongside a [LocationAccessStatus].
///
/// Separate from the copy so a test can assert WHICH OS screen a given cause
/// sends the user to — the whole point of distinguishing the causes.
enum LocationAccessAction {
  /// Open the device-wide location settings (the "Location" master toggle).
  openLocationSettings,

  /// Open Haven's own app settings, where the permission is re-granted.
  openAppSettings,

  /// Re-run the check. Offered only when the cause is unknown, so the app
  /// never sends the user to a screen that may be the wrong one.
  retry,
}

/// Title, body and remedy for one blocked [LocationAccessStatus].
@immutable
class LocationAccessCopy {
  /// Creates a resolved copy bundle.
  const LocationAccessCopy({
    required this.title,
    required this.message,
    required this.action,
  });

  /// Short headline naming the blocker.
  final String title;

  /// Body explaining what stopped and how to restore it.
  final String message;

  /// The remedy button to offer.
  final LocationAccessAction action;
}

/// Maps a blocked [status] to its user-facing copy and remedy.
///
/// Returns `null` for [LocationAccessStatus.available] — there is nothing to
/// say. Pure, so every branch is unit-testable without pumping a widget.
///
/// Reuses `mapLocationOffTitle` for both device-toggle cases so the headline
/// the app already uses for "location is off" keeps one meaning, and switches
/// to `mapLocationNoPermissionTitle` when the blocker is Haven's permission —
/// the title is what tells the user which of the two settings screens to open.
LocationAccessCopy? resolveLocationAccessCopy(
  LocationAccessStatus status,
  AppLocalizations l10n,
) {
  switch (status) {
    case LocationAccessStatus.available:
      return null;
    case LocationAccessStatus.serviceDisabled:
      return LocationAccessCopy(
        title: l10n.mapLocationOffTitle,
        message: l10n.mapLocationSharingStoppedServiceOff,
        action: LocationAccessAction.openLocationSettings,
      );
    case LocationAccessStatus.permissionDenied:
      return LocationAccessCopy(
        title: l10n.mapLocationNoPermissionTitle,
        message: l10n.mapLocationSharingStoppedPermission,
        action: LocationAccessAction.openAppSettings,
      );
    case LocationAccessStatus.permissionPermanentlyDenied:
      return LocationAccessCopy(
        title: l10n.mapLocationNoPermissionTitle,
        message: l10n.mapLocationSharingStoppedPermissionSettings,
        action: LocationAccessAction.openAppSettings,
      );
    case LocationAccessStatus.serviceDisabledAndPermissionDenied:
      return LocationAccessCopy(
        title: l10n.mapLocationOffTitle,
        message: l10n.mapLocationSharingStoppedBoth,
        // The device toggle is the outer blocker; the body names both remedies
        // so fixing this one does not leave the user stranded without a clue.
        action: LocationAccessAction.openLocationSettings,
      );
    case LocationAccessStatus.unknown:
      return LocationAccessCopy(
        title: l10n.mapLocationErrorTitle,
        message: l10n.mapLocationSharingStoppedUnknown,
        action: LocationAccessAction.retry,
      );
  }
}

/// Banner announcing that Haven can no longer read this device's location.
///
/// Renders nothing while access is fine, so it is safe to place
/// unconditionally in the map stack.
///
/// ## Height, and why the caller must bound it
///
/// The card is `mainAxisSize: min` — at the default text scale it is about
/// 208 dp on a 390 dp-wide phone and nothing here needs to scroll. At the
/// 200 % scale Android and iOS both offer it is 652 dp on that same phone and
/// 788 dp at 320 dp wide, i.e. taller than the viewport. So the status text
/// sits in a [SingleChildScrollView] under a [Flexible], and the remedy button
/// is OUTSIDE it: whatever the scale, the button is the last thing laid out
/// and is therefore always on screen and always tappable. A banner whose
/// remedy is 300 dp below the fold, in a surface with no scroll view of its
/// own, is a banner that cannot be acted on.
///
/// That only works if the incoming constraints have a bounded height — a
/// `Flexible` under an unbounded main axis degrades to intrinsic sizing and
/// the content runs off the viewport again, silently, with no overflow stripe
/// to notice (`RenderFlex` only reports an overflow it can measure). `MapShell`
/// supplies the bound by giving the banner's `PositionedDirectional` a
/// `bottom:` as well as a `top:`; pinned by
/// `map_shell_banner_layering_test.dart`.
class LocationAccessBanner extends ConsumerWidget {
  /// Creates the location-access banner.
  const LocationAccessBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    // A live region announces its APPEARANCE but never its removal, so a
    // screen-reader user would otherwise be told that sharing stopped and
    // never told that it resumed. Announce the recovery edge explicitly.
    ref.listen<LocationAccessStatus>(locationAccessProvider, (previous, next) {
      if (previous != null && previous.isBlocked && !next.isBlocked) {
        unawaited(
          SemanticsService.sendAnnouncement(
            View.of(context),
            l10n.mapLocationAccessRestoredAnnouncement,
            Directionality.of(context),
          ),
        );
      }
    });

    final status = ref.watch(locationAccessProvider);
    final copy = resolveLocationAccessCopy(status, l10n);
    if (copy == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // `Flexible`, so at ordinary text scales the card still
            // shrink-wraps its content and nothing scrolls; only when the text
            // no longer fits does the status area give way and keep the button
            // on screen. The scroll view is OUTSIDE the status node — wrapping
            // the other way would put a scrollable's own semantics inside the
            // live region and change what a screen reader announces.
            Flexible(
              child: SingleChildScrollView(
                child: Semantics(
                  // ONE node carrying the whole status, so a screen reader
                  // speaks cause and remedy as a single sentence rather than
                  // two orphaned fragments the user must swipe between.
                  // `liveRegion` makes TalkBack/VoiceOver speak it the moment
                  // it appears, without stealing focus (WCAG 2.1 SC 4.1.3
                  // Status Messages).
                  //
                  // The label is set explicitly and the visual subtree
                  // excluded: a bare `container: true` around Text children
                  // leaves the container node label-less, so the live region
                  // would fire with nothing to say.
                  container: true,
                  liveRegion: true,
                  label: '${copy.title}\n${copy.message}',
                  child: ExcludeSemantics(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Decorative: the headline beside it carries the same
                        // meaning, so an unlabelled icon avoids a duplicate
                        // read.
                        Icon(
                          LucideIcons.mapPinOff,
                          color: colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: HavenSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                copy.title,
                                style: textTheme.titleSmall?.copyWith(
                                  color: colorScheme.onErrorContainer,
                                ),
                              ),
                              const SizedBox(height: HavenSpacing.xs),
                              Text(
                                copy.message,
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onErrorContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            // Deliberately OUTSIDE the status node: the remedy must stay its
            // own focusable, actionable element rather than being merged into
            // a block of prose.
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onErrorContainer,
                ),
                onPressed: () => _runAction(ref, copy.action),
                child: Text(_actionLabel(l10n, copy.action)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _actionLabel(AppLocalizations l10n, LocationAccessAction a) {
    switch (a) {
      case LocationAccessAction.openLocationSettings:
      case LocationAccessAction.openAppSettings:
        return l10n.commonOpenSettings;
      case LocationAccessAction.retry:
        return l10n.commonTryAgain;
    }
  }

  /// Runs the remedy, then re-checks.
  ///
  /// The re-check matters for every branch, not just
  /// [LocationAccessAction.retry]: a user who fixes
  /// the blocker inside the OS settings screen returns to a resumed app, and
  /// while `MapShell` also refreshes on resume, an in-place fix (some OEM
  /// location toggles are reachable from a shade tile without ever pausing
  /// Haven) would otherwise wait for the next watchdog tick.
  Future<void> _runAction(WidgetRef ref, LocationAccessAction action) async {
    final launcher = ref.read(locationSettingsLauncherProvider);
    switch (action) {
      case LocationAccessAction.openLocationSettings:
        await launcher.openLocationSettings();
      case LocationAccessAction.openAppSettings:
        await launcher.openAppSettings();
      case LocationAccessAction.retry:
        break;
    }
    await ref.read(locationAccessProvider.notifier).refresh();
  }
}
