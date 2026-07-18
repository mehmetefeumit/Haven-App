/// Tile displaying a circle member with status.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/member_detail_sheet.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// npub is 63 chars; show enough of the distinguishing prefix (after the
// constant "npub1" HRP) and suffix to differentiate members at a glance.
String _shortNpub(String npub) =>
    NpubValidator.truncate(npub, prefixLength: 12, suffixLength: 6);

/// Displays a circle member with their status and actions.
///
/// When [member] is the current user, the title and avatar use the display
/// name saved in settings (via `IdentityService.setDisplayName`) rather
/// than the pubkey hex — see [resolveMemberDisplayName]. Other members'
/// names resolve via [resolveEffectiveMemberName] (local nickname → public
/// kind-0 `display_name` → `name` → npub fallback, plan D6).
///
/// When [hasLocation] is `false` the tile is rendered in a disabled
/// Material state and [onTap] is ignored, so a user can see at a glance
/// which members can be centered on the map. Accepted members with no
/// cached location display a "No recent location" hint; pending invitees
/// keep the existing "Invitation Pending" status.
///
/// The avatar area shows the member's public profile picture — self via
/// [ownProfileProvider], others via [memberProfileProvider(pubkey)] — when
/// [publicProfilesEnabled] and a picture is known, falling back to the
/// initials-based [CircleAvatar] otherwise. Tapping the avatar opens
/// [showMemberDetailSheet] (nickname editing + copy-npub) without disturbing
/// the row's own tap-to-center / long-press-to-copy gestures.
class CircleMemberTile extends ConsumerWidget {
  /// Creates a [CircleMemberTile].
  const CircleMemberTile({
    required this.member,
    this.onTap,
    this.trailing,
    this.hasLocation = true,
    this.onRemove,
    super.key,
  });

  /// The member to display.
  final CircleMember member;

  /// Callback when the tile is tapped.
  ///
  /// Ignored when [hasLocation] is `false` or the member is pending.
  final VoidCallback? onTap;

  /// Optional trailing widget (e.g., remove button). When provided, it
  /// overrides the default focus-locator affordance that tappable tiles
  /// render.
  final Widget? trailing;

  /// Whether a last-known location is available for this member.
  ///
  /// Defaults to `true` to preserve the widget's original behaviour when
  /// used outside the map-centric context.
  final bool hasLocation;

  /// When non-null, renders an admin "Remove member" action in the
  /// trailing area. Set by the parent when the viewer is an admin and
  /// it is safe for them to evict this member.
  ///
  /// Ignored when [trailing] is provided (explicit override wins).
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    // While either provider is still loading we treat the value as null and
    // fall back to the Contact-table name / truncated pubkey — exactly how
    // the tile behaved before self-awareness was added.
    final currentUserPubkey = ref
        .watch(identityProvider)
        .valueOrNull
        ?.pubkeyHex;
    final currentUserDisplayName = ref.watch(displayNameProvider).valueOrNull;

    // The current user's own avatar lives in the OWN-profile store (keyed
    // only by pubkey), NOT the received-member store the other tiles read
    // from. When this tile is the viewer's own row we must source the name
    // and thumbnail from `ownProfileProvider` instead, otherwise the user
    // never sees their own name/picture reflected in the member list. See
    // [_MemberAvatar].
    final isSelf = isSelfMember(member, currentUserPubkey: currentUserPubkey);

    final npubFallback = _shortNpub(member.npub);

    // Self keeps its dedicated resolution path (today's settings-name
    // branch) so the member list and the Identity page always agree (D6 /
    // Flutter review F3); only non-self members route through the generic
    // four-tier resolver, which — unlike `resolveMemberDisplayName` — always
    // returns a non-null string (falling back to the npub itself), so
    // `hasRealName` tracks separately whether a NAME (vs. the npub fallback)
    // was actually resolved, for the mono-font/subtitle decisions below.
    final String displayedName;
    final bool hasRealName;
    if (isSelf) {
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: currentUserPubkey,
        currentUserDisplayName: currentUserDisplayName,
      );
      hasRealName = resolved != null;
      displayedName = resolved ?? npubFallback;
    } else {
      final profile = publicProfilesEnabled
          ? ref.watch(memberProfileProvider(member.pubkey)).valueOrNull
          : null;
      final resolved = resolveEffectiveMemberName(
        localOverride: member.displayName,
        profile: profile,
        npubFallback: npubFallback,
      );
      hasRealName = resolved != npubFallback;
      displayedName = resolved;
    }
    // Only used for the avatar-initials fallback: null when no real name was
    // resolved, matching the pre-migration contract of `_initialFor`.
    final effectiveDisplayName = hasRealName ? displayedName : null;

    final isPending = member.status == MembershipStatus.pending;
    final isInteractive = onTap != null && !isPending && hasLocation;

    final canCopy = member.npub.isNotEmpty;
    final semanticHint = _semanticsHint(
      l10n,
      isPending: isPending,
      hasLocation: hasLocation,
      isInteractive: isInteractive,
    );

    // Keep the ListTile visually enabled even when non-interactive: the
    // "disabled" state dims the title and avatar, which obscures the
    // member's identity for a condition ("no recent location") that is a
    // *data* state rather than an action being unavailable. Interaction
    // gating is done via `onTap: null`. Screen readers no longer hear the
    // row as non-actionable in this case, though: it still carries the
    // copy-npub custom action below, so the outer Semantics node stays
    // enabled whenever that action is present (see `enabled` below).
    //
    // When an interactive child (e.g. the Remove button) is present, do
    // not exclude descendant semantics — otherwise the IconButton's
    // tooltip/label would be swallowed and the button would be
    // invisible to TalkBack/VoiceOver. The row label still reads first
    // thanks to standard traversal order.
    final hasInteractiveChild = onRemove != null;
    final descendantsExcluded = !hasInteractiveChild;

    // Expose "member details" (the avatar's showMemberDetailSheet tap —
    // nickname edit + copy-npub) as a labeled CustomSemanticsAction in BOTH
    // branches (NIT-b): the leading avatar's `GestureDetector` carries no
    // semantics label of its own, so without this action screen reader
    // users had no way to reach it whenever a Remove button forced
    // `descendantsExcluded: false` (the ListTile's own, non-excluded
    // semantics do not cover the avatar's separate tap target).
    //
    // Copy-npub is layered in as its own CustomSemanticsAction ONLY in the
    // descendant-excluded case: TalkBack surfaces `ListTile.onLongPress`
    // fine on its own, but iOS VoiceOver has no discoverable long-press
    // gesture and ignores `onLongPressHint` (an Android-only property),
    // leaving copy unreachable there unless backed by a CustomSemanticsAction
    // — needed only when the ListTile's own (non-excluded) long-press
    // semantics are dropped, i.e. exactly the descendant-excluded case. When
    // a Remove button is present the ListTile keeps its own long-press
    // semantics below, so copy stays reachable via TalkBack there too.
    final copyActions = <CustomSemanticsAction, VoidCallback>{
      if (descendantsExcluded && canCopy)
        CustomSemanticsAction(label: l10n.circleMemberCopyPublicKeyHint):
            () => _copyNpub(context, l10n),
      CustomSemanticsAction(label: l10n.memberDetailSheetTitle): () =>
          showMemberDetailSheet(context, ref, member),
    };

    return Semantics(
      button: isInteractive,
      // The row is actionable whenever it can be tapped-to-center OR offers
      // a custom action (copy / member details — the latter is now always
      // present, see `copyActions` above), so never mark it disabled — a
      // disabled node hides those actions from screen readers.
      enabled: isInteractive || copyActions.isNotEmpty,
      label: '$displayedName, $semanticHint',
      excludeSemantics: descendantsExcluded,
      // In the excluded case the ListTile's own tap semantics are
      // dropped; forward tap-to-center to the outer node so screen
      // readers can activate it.
      onTap: (isInteractive && descendantsExcluded) ? onTap : null,
      // "Member details" (always) and, when descendants are excluded,
      // "copy" too, are exposed as labeled custom actions → discoverable on
      // TalkBack AND VoiceOver, decoupled from the tap gesture and enabled
      // state. Sighted users get copy via the ListTile long-press below and
      // member details via the avatar tap.
      customSemanticsActions: copyActions,
      child: ListTile(
        leading: GestureDetector(
          onTap: () => showMemberDetailSheet(context, ref, member),
          child: _MemberAvatar(
            pubkey: member.pubkey,
            displayName: effectiveDisplayName,
            isCurrentUser: isSelf,
          ),
        ),
        title: Text(
          displayedName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: effectiveDisplayName == null
              ? TextDirection.ltr
              : null,
          style: effectiveDisplayName == null
              ? HavenTypography.mono.copyWith(fontSize: 14)
              : null,
        ),
        subtitle: _buildSubtitle(
          context,
          l10n,
          colorScheme,
          effectiveDisplayName,
        ),
        trailing: trailing ?? _buildTrailing(l10n),
        onTap: isInteractive ? onTap : null,
        onLongPress: canCopy ? () => _copyNpub(context, l10n) : null,
      ),
    );
  }

  /// Copies [member]'s npub to the clipboard and shows a confirming
  /// SnackBar, then announces the confirmation to screen readers (a
  /// SnackBar is not a live region, so it is otherwise silent to them). An
  /// npub is a PUBLIC key — safe to copy/display, no secret warning needed.
  Future<void> _copyNpub(BuildContext context, AppLocalizations l10n) async {
    // Capture messenger before the async gap; npub is public (no clipboard
    // warning).
    final messenger = ScaffoldMessenger.of(context);
    await HapticFeedback.mediumImpact();
    await Clipboard.setData(ClipboardData(text: member.npub));
    if (!context.mounted) return;
    // Capture before the next async gap, same as `messenger` above.
    final textDirection = Directionality.of(context);
    final view = View.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.circleMemberPublicKeyCopied),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    // SnackBars are not live regions; announce copy success for screen
    // readers. `SemanticsService.announce` is deprecated in favor of this
    // view-scoped variant.
    await SemanticsService.sendAnnouncement(
      view,
      l10n.circleMemberPublicKeyCopied,
      textDirection,
    );
  }

  Widget? _buildSubtitle(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    String? effectiveDisplayName,
  ) {
    if (member.status == MembershipStatus.pending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.clock, size: 14, color: HavenSecurityColors.warning),
          const SizedBox(width: HavenSpacing.xs),
          Text(
            l10n.circleMemberInvitationPending,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: HavenSecurityColors.warning),
          ),
        ],
      );
    }

    if (!hasLocation) {
      return Text(
        l10n.circleMemberNoRecentLocation,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      );
    }

    if (effectiveDisplayName != null) {
      // Show the member's npub as subtitle when we have a display name
      return Text(
        _shortNpub(member.npub),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textDirection: TextDirection.ltr,
        style: HavenTypography.monoSmall.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    return null;
  }

  Widget? _buildTrailing(AppLocalizations l10n) {
    final removeButton = onRemove == null
        ? null
        : IconButton(
            icon: const Icon(
              LucideIcons.userMinus,
              size: 22,
              color: HavenSecurityColors.warning,
            ),
            onPressed: onRemove,
            tooltip: l10n.circleMemberRemoveTooltip,
            visualDensity: VisualDensity.compact,
          );

    if (member.isAdmin) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(
            label: Text(l10n.circleMemberAdmin),
            labelStyle: const TextStyle(fontSize: 11),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          if (removeButton != null) ...[
            const SizedBox(width: HavenSpacing.xs),
            removeButton,
          ],
        ],
      );
    }

    return removeButton;
  }

  String _semanticsHint(
    AppLocalizations l10n, {
    required bool isPending,
    required bool hasLocation,
    required bool isInteractive,
  }) {
    if (isPending) return l10n.circleMemberHintPending;
    if (!hasLocation) return l10n.circleMemberHintNoLocation;
    if (!isInteractive) return l10n.circleMemberHintMember;
    return l10n.circleMemberHintTapToCenter;
  }
}

/// Avatar widget for a circle member.
///
/// When [publicProfilesEnabled], watches the pubkey's public profile —
/// self via [ownProfileProvider], others via `memberProfileProvider(pubkey)`
/// — and renders [Profile.pictureBytes] via [HavenAvatar] when available.
/// Falls back to an initials-based [CircleAvatar] when no picture is known,
/// the provider is loading, or an error occurs. No shimmer is shown during
/// loading — that would leak "avatar incoming" to a bystander observing the
/// UI. When [publicProfilesEnabled] is off, always renders the initials
/// fallback (no fetching).
///
/// When [isCurrentUser] is `true`, the thumbnail is sourced from
/// [ownProfileProvider] (the OWN-profile store) rather than
/// `memberProfileProvider` (the received-member store). The viewer's own
/// profile is resolved locally/by their own publishes, not by receiving a
/// broadcast from themselves, so self and other members read from two
/// distinct stores; reading the member store for self would always miss.
/// Sourcing from [ownProfileProvider] also means the row refreshes the
/// instant the user sets or clears their picture in settings (that
/// controller invalidates it). Diameter (logical px) shared by both
/// member-avatar branches so the image avatar and the initials
/// [CircleAvatar] are always rendered at the same size. Matches Material's
/// default [CircleAvatar] radius of 20 (→ 40dp): the initials fallback
/// keeps its standard list dimensions while the image variant grows to
/// match it rather than rendering smaller.
const double _memberAvatarDiameter = 40;

class _MemberAvatar extends ConsumerWidget {
  const _MemberAvatar({
    required this.pubkey,
    this.displayName,
    this.isCurrentUser = false,
  });

  final String pubkey;
  final String? displayName;

  /// Whether this tile represents the current user (the viewer).
  ///
  /// When `true`, the avatar is read from [ownProfileProvider] instead of
  /// the per-member received-profile store.
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    // Desaturated HSL hue derived from the pubkey gives each member a stable
    // tint without the brand-blue/red collisions of Colors.primaries.
    final hue = (pubkey.hashCode.abs() % 360).toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.30, 0.55).toColor();

    final initial = _initialFor(displayName, pubkey);

    // Build the initials fallback once; reused by both branches.
    final initialsAvatar = CircleAvatar(
      radius: _memberAvatarDiameter / 2,
      backgroundColor: tint.withValues(alpha: 0.18),
      foregroundColor: colorScheme.onSurface,
      child: Text(
        initial,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
    );

    if (!publicProfilesEnabled) return initialsAvatar;

    // Resolve the picture bytes from the correct store:
    // - self: the own-profile store (ownProfileProvider), keyed by pubkey
    //   only. Invalidated by OwnProfileController on set/clear/save, so this
    //   row refreshes the instant the user changes their picture.
    // - others: the plain-pubkey-keyed member-profile store (D6 — no
    //   mlsGroupId component; the same pubkey resolves the same profile
    //   across every shared circle).
    // Both providers are autoDispose — released when the tile leaves the tree.
    final thumbnailBytes = isCurrentUser
        ? ref.watch(ownProfileProvider).valueOrNull?.pictureBytes
        : ref.watch(memberProfileProvider(pubkey)).valueOrNull?.pictureBytes;

    // On loading or error: show initials (no shimmer — bystander privacy).
    // On data: show HavenAvatar with image bytes when non-null.
    //
    // Wrap the whole initials-or-image decision in a single AnimatedSwitcher
    // so a nil→image transition crossfades rather than hard-popping.
    // The ValueKey differentiates the two widget types so Flutter knows to
    // animate the swap. No shimmer — bystander privacy.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: thumbnailBytes == null
          ? KeyedSubtree(key: const ValueKey('initials'), child: initialsAvatar)
          : HavenAvatar(
              key: const ValueKey('image'),
              imageBytes: thumbnailBytes,
              initials: initial,
              publicKey: pubkey,
              // Match the initials CircleAvatar exactly so a member with a
              // profile picture is the same size as one showing initials.
              diameter: _memberAvatarDiameter,
            ),
    );
  }

  // The FFI today always delivers a 64-char lowercase hex pubkey, but we
  // don't want a malformed record (short pubkey + no display name) to crash
  // the whole member list. Pick a deterministic fallback glyph instead.
  static String _initialFor(String? displayName, String pubkey) {
    final name = displayName;
    if (name != null && name.isNotEmpty) {
      return name.characters.first.toUpperCase();
    }
    if (pubkey.length > 5) {
      return pubkey[5].toUpperCase();
    }
    if (pubkey.isNotEmpty) {
      return pubkey.characters.first.toUpperCase();
    }
    return '?';
  }
}

/// A tile for displaying a pending member being added to a circle.
///
/// Shows validation status (loading, valid, error) while KeyPackage is fetched.
class PendingMemberTile extends StatelessWidget {
  /// Creates a [PendingMemberTile].
  const PendingMemberTile({
    required this.npub,
    required this.status,
    this.errorMessage,
    this.onRemove,
    this.onRetry,
    super.key,
  });

  /// The npub of the member.
  final String npub;

  /// Current validation status.
  final ValidationStatus status;

  /// Error message if validation failed.
  final String? errorMessage;

  /// Callback when remove button is pressed.
  final VoidCallback? onRemove;

  /// Callback when retry button is pressed (for network failures).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: _buildLeadingIcon(l10n, colorScheme),
      title: Text(
        NpubValidator.truncate(npub),
        style: HavenTypography.mono.copyWith(fontSize: 14),
      ),
      subtitle: _buildSubtitle(context, l10n),
      trailing: _buildTrailing(l10n),
    );
  }

  Widget? _buildTrailing(AppLocalizations l10n) {
    if (onRemove == null && onRetry == null) return null;

    // Show retry + close for retryable failures
    if (status == ValidationStatus.invalid && onRetry != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: onRetry,
            tooltip: l10n.pendingMemberRetryTooltip,
          ),
          if (onRemove != null) ...[
            const SizedBox(width: HavenSpacing.xs),
            IconButton(
              icon: const Icon(LucideIcons.x),
              onPressed: onRemove,
              tooltip: l10n.pendingMemberRemoveTooltip,
            ),
          ],
        ],
      );
    }

    // Default: just close button
    if (onRemove != null) {
      return IconButton(
        icon: const Icon(LucideIcons.x),
        onPressed: onRemove,
        tooltip: l10n.pendingMemberRemoveTooltip,
      );
    }

    return null;
  }

  Widget _buildLeadingIcon(AppLocalizations l10n, ColorScheme colorScheme) {
    return switch (status) {
      ValidationStatus.validating => Semantics(
        label: l10n.pendingMemberValidating,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
      ValidationStatus.valid => CircleAvatar(
        backgroundColor: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
        child: Icon(
          LucideIcons.circleCheck,
          color: HavenSecurityColors.encrypted,
          semanticLabel: l10n.pendingMemberValid,
        ),
      ),
      ValidationStatus.invalid => CircleAvatar(
        backgroundColor: HavenSecurityColors.warning.withValues(alpha: 0.1),
        child: Icon(
          LucideIcons.triangleAlert,
          color: HavenSecurityColors.warning,
          semanticLabel: l10n.pendingMemberWarning,
        ),
      ),
      ValidationStatus.needsUpdate => CircleAvatar(
        backgroundColor: HavenSecurityColors.warning.withValues(alpha: 0.1),
        child: Icon(
          LucideIcons.cloudDownload,
          color: HavenSecurityColors.warning,
          semanticLabel: l10n.pendingMemberNeedsUpdate,
        ),
      ),
    };
  }

  Widget? _buildSubtitle(BuildContext context, AppLocalizations l10n) {
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return switch (status) {
      ValidationStatus.validating => Text(
        l10n.pendingMemberCheckingAvailability,
        style: textStyle?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      ValidationStatus.valid => Text(
        l10n.pendingMemberReadyToInvite,
        style: textStyle?.copyWith(color: HavenSecurityColors.encrypted),
      ),
      ValidationStatus.invalid => Text(
        errorMessage ?? l10n.createCircleNoAccountFound,
        style: textStyle?.copyWith(color: HavenSecurityColors.warning),
      ),
      ValidationStatus.needsUpdate => Text(
        errorMessage ?? l10n.pendingMemberNeedsUpdate,
        style: textStyle?.copyWith(color: HavenSecurityColors.warning),
      ),
    };
  }
}

/// Validation status for a pending member.
enum ValidationStatus {
  /// Currently validating (fetching KeyPackage).
  validating,

  /// Validation successful (KeyPackage found).
  valid,

  /// Validation failed (no KeyPackage found).
  invalid,

  /// A KeyPackage was found, but it carries the deprecated pre-Dark-Matter
  /// kind (443) — the person is running an old Haven build and cannot be
  /// invited into a circle on the new engine until they update (DM-4c, plan
  /// §6 F11). Distinct from [invalid]: this is not a network/lookup failure
  /// and offers no retry.
  needsUpdate,
}
