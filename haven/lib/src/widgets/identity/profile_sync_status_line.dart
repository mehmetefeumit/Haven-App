/// The own-profile publish-status line, rendered ONCE at Identity-page scope
/// — directly under `PublicProfileNotice`, between the photo header above it
/// and the display-name card below it, the two editors it reports on.
///
/// One shared status for the WHOLE own profile — never one per field, and
/// never one instance per editor — BY DESIGN: a name edit and a photo edit
/// both land in the SAME kind-0 event, so there is exactly one honest thing
/// to say about it. A second instance would announce that one fact twice
/// (WCAG 4.1.3) and run two spinners for one publish.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/profile_sync_trigger.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Renders [ProfileSyncStatus] as an icon + short text, with a Retry action
/// when the last attempt failed.
///
/// Renders nothing for [ProfileSyncStatus.unknown] — the first local read has
/// not resolved, and claiming "up to date" before that would be a lie.
///
/// Semantics (`clock_skew_banner.dart` precedent): the passive icon+text sits
/// inside a `Semantics(container: true, liveRegion: ..., label: ...)` node
/// WRAPPING an `ExcludeSemantics`-hidden visual `Row` — a bare
/// `container: true` around `Text` children leaves the live-region node
/// label-less, so the announcement would fire with nothing to say. The Retry
/// button is a SIBLING OUTSIDE that node, not nested inside it: a live region
/// re-announces its entire subtree on every rebuild, which would re-speak
/// "Retry" on every unrelated status change if the button lived inside it.
///
/// `liveRegion` is FALSE while the status has been `synced` since this widget
/// mounted and has never been anything else — opening the Identity page must
/// not announce the resting "up to date" state, which would fire on every
/// visit. Once a real transition is observed (any non-`unknown`, non-`synced`
/// status), the node stays live for the rest of this mount, so the
/// transition BACK to `synced` — the one a user who just made an edit is
/// actually waiting to hear about — is announced.
///
/// The whole line is wrapped in an [AnimatedSize] so the icon/text swap and
/// the Retry button's appearance/disappearance never jump the layout below
/// it; the duration collapses to zero under reduced motion
/// (`display_name_card.dart`'s `_CircularSaveButton` idiom).
class ProfileSyncStatusLine extends ConsumerStatefulWidget {
  /// Creates the profile-sync status line.
  const ProfileSyncStatusLine({super.key});

  @override
  ConsumerState<ProfileSyncStatusLine> createState() =>
      _ProfileSyncStatusLineState();
}

class _ProfileSyncStatusLineState
    extends ConsumerState<ProfileSyncStatusLine> {
  /// Whether a non-`unknown`, non-`synced` status has been observed since
  /// this widget mounted — see the class doc for why `synced` alone must
  /// never set this.
  bool _sawTransitionThisMount = false;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(ownProfileSyncProvider);
    if (status != ProfileSyncStatus.synced &&
        status != ProfileSyncStatus.unknown) {
      _sawTransitionThisMount = true;
    }

    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    final visual = switch (status) {
      ProfileSyncStatus.unknown => null,
      ProfileSyncStatus.syncing => (
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        l10n.profileSyncStatusSyncing,
      ),
      ProfileSyncStatus.partial => (
        Icon(
          LucideIcons.clock,
          size: 14,
          color: colorScheme.onSurfaceVariant,
        ),
        l10n.profileSyncStatusPartial,
      ),
      ProfileSyncStatus.synced => (
        Icon(
          LucideIcons.circleCheck,
          size: 14,
          color: colorScheme.onSurfaceVariant,
        ),
        l10n.profileSyncStatusSynced,
      ),
      ProfileSyncStatus.failed => (
        Icon(LucideIcons.circleAlert, size: 14, color: colorScheme.error),
        l10n.profileSyncStatusFailed,
      ),
    };

    Widget content = const SizedBox.shrink();
    if (visual != null) {
      final (icon, text) = visual;
      final liveRegion =
          status != ProfileSyncStatus.synced || _sawTransitionThisMount;

      content = Row(
        children: [
          Flexible(
            child: Semantics(
              container: true,
              liveRegion: liveRegion,
              label: text,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    icon,
                    const SizedBox(width: HavenSpacing.xs),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: status == ProfileSyncStatus.failed
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (status == ProfileSyncStatus.failed) ...[
            const SizedBox(width: HavenSpacing.xs),
            // A SIBLING of the live-region node above, not nested inside it: a
            // live region re-announces its whole subtree on every rebuild,
            // which would re-speak "Retry" on every unrelated status change if
            // the button lived inside it. The button widget itself already
            // creates a real, actionable semantics node (with `button: true`
            // and the tap action) — relabelling only its passive `Text` child
            // (`_CircularSaveButton`'s pattern) keeps that action intact,
            // while giving screen readers a more descriptive name than the
            // short visible "Retry" caption.
            TextButton(
              key: WidgetKeys.profileSyncRetryButton,
              onPressed: () => triggerProfileSync(ref),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 36),
                padding: const EdgeInsets.symmetric(
                  horizontal: HavenSpacing.xs,
                ),
              ),
              child: Semantics(
                label: l10n.profileSyncStatusRetrySemantics,
                excludeSemantics: true,
                child: Text(l10n.commonRetry),
              ),
            ),
          ],
        ],
      );
    }

    return AnimatedSize(
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: AlignmentDirectional.topStart,
      child: content,
    );
  }
}
