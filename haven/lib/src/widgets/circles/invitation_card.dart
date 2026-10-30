/// Invitation card widget for displaying pending circle invitations.
///
/// Shows invitation details with accept/decline actions.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/contact_nickname_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/publish_stagger.dart'
    show kMaxCirclesPerAccount;
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/bidi_isolate.dart';
import 'package:haven/src/utils/log_alias.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/utils/profile_refresh_trigger.dart';
import 'package:haven/src/widgets/circles/rejoin_circle_dialog.dart';
import 'package:haven/src/widgets/common/long_message_snack_bar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A card widget that displays a pending circle invitation.
///
/// Shows who invited you, at which public key, and how long ago. Provides
/// buttons to accept or decline the invitation.
///
/// Deliberately shows neither a circle name nor a member count: pre-join
/// both live inside the still-encrypted Welcome, so the only values Haven
/// could put there are stand-ins presented as facts.
class InvitationCard extends ConsumerStatefulWidget {
  /// Creates an invitation card.
  const InvitationCard({required this.invitation, super.key});

  /// The invitation to display.
  final Invitation invitation;

  @override
  ConsumerState<InvitationCard> createState() => _InvitationCardState();
}

/// Which action the user triggered, for showing the correct loading spinner.
enum _LoadingAction { none, accepting, declining }


class _InvitationCardState extends ConsumerState<InvitationCard> {
  _LoadingAction _loadingAction = _LoadingAction.none;

  bool get _isLoading => _loadingAction != _LoadingAction.none;

  /// Stable, privacy-safe discriminator for this invitation's composite
  /// widget keys.
  ///
  /// E2E tests want stable `ValueKey`s so a scenario can target a
  /// specific invitation card when more than one is rendered. The
  /// previous implementation derived the key from
  /// `widget.invitation.mlsGroupId`, which embedded the real MLS group
  /// ID in the live widget tree — observable via the widget inspector,
  /// accessibility/semantics dumps, and `flutter test --reporter=json`
  /// artifacts. That violated CLAUDE.md rule #4 ("Only publish
  /// `nostr_group_id`, never real MLS group ID") at the on-device
  /// observability layer.
  ///
  /// The replacement combines the inviter's Nostr public key (which is
  /// already public — it's the `pubkey` field of every Nostr event the
  /// inviter ever sends) with the invitation's receive timestamp (which
  /// the relay also observes on the gift-wrap event). Both are derived
  /// strictly from public Nostr metadata; no MLS-side identifier touches
  /// the widget tree. The pair is unique per invitation in practice and
  /// stable across rebuilds for the lifetime of the card.
  String get _keyDiscriminator =>
      '${widget.invitation.inviterPubkey}_'
      '${widget.invitation.invitedAt.millisecondsSinceEpoch}';

  /// Formats a timestamp as a human-readable time ago string.
  String _formatTimeAgo(AppLocalizations l10n, DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays > 0) {
      return l10n.invitationCardDaysAgo(difference.inDays);
    } else if (difference.inHours > 0) {
      return l10n.invitationCardHoursAgo(difference.inHours);
    } else if (difference.inMinutes > 0) {
      return l10n.invitationCardMinutesAgo(difference.inMinutes);
    } else {
      return l10n.invitationCardJustNow;
    }
  }

  /// Handles accepting the invitation.
  Future<void> _handleAccept() async {
    final l10n = AppLocalizations.of(context);
    // Read before the await: everything after it must work even when this
    // card has already left the tree — the user navigated away, or the list
    // refreshed — and a disposed card's `ref` and `context` cannot be used.
    // The messenger outlives the card, and so does its context.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final inviter = _inviterLabel();
    final needsNewInvite = longMessageSnackBar(
      context,
      l10n.invitationNeedsNewInviteError(inviter),
      error: true,
    );
    setState(() {
      _loadingAction = _LoadingAction.accepting;
    });

    try {
      debugPrint('[Accept] starting acceptInvitation');
      final acceptedCircle = await _acceptOrRejoin(
        container,
        messenger,
        l10n,
        inviter,
        errorColor,
      );
      // Nothing joined: the user kept the invitation for later, or declined.
      if (acceptedCircle == null) return;
      debugPrint(
        '[Accept] acceptInvitation OK '
        '(members=${magnitudeBucket(acceptedCircle.members.length)}, '
        'relays=${magnitudeBucket(acceptedCircle.relays.length)})',
      );

      // Auto-select the accepted circle so the map immediately shows
      // member locations without requiring a manual tap.
      container.read(selectedCircleIdProvider.notifier).state =
          acceptedCircle.mlsGroupId;

      // Invalidate providers to refresh UI and republish a fresh KeyPackage.
      // read() after invalidate() triggers execution for fire-and-forget
      // providers that nothing watches.
      debugPrint('[Accept] triggering keyPackagePublisher + locationPublisher');
      container
        ..invalidate(pendingInvitationsProvider)
        ..invalidate(circlesProvider)
        ..invalidate(keyPackagePublisherProvider)
        ..read(keyPackagePublisherProvider)
        ..invalidate(locationPublisherProvider)
        ..read(locationPublisherProvider)
        ..invalidate(memberLocationsProvider);

      // Resolve the new co-members' public profiles. Their pubkeys have no
      // cache row yet, so they bypass the staleness gate entirely — without
      // this they render as a bare npub until some unrelated trigger fires.
      //
      // Deliberately NOT scoped to `acceptedCircle`: the refresh must cover
      // the union of every circle (§1.7). Sending just this circle's roster
      // would hand the relay an exact co-membership cluster. `circlesProvider`
      // was invalidated above, so resolving it here picks up the new circle.
      triggerProfileRefreshIn(container, maxAge: profileInteractiveMaxAge);

      // Kick off the joiner-side burst-poll window so existing members'
      // locations land within seconds. Self-terminates after a jittered
      // 50–80 s window.
      debugPrint('[Accept] starting joiner burst watcher');
      container
          .read(joinWatcherProvider.notifier)
          .startJoinerWatch(acceptedCircle.mlsGroupId);

      // The post-join self-update MDK owes is not issued here: haven-core
      // makes it from a full drive once the circle is caught up and quiet
      // (`SessionManager::post_join_due`), through the fanout driver like
      // every commit.

      messenger.showSnackBar(
        SnackBar(content: Text(l10n.invitationAcceptedSnack)),
      );
    } on InvitationNeedsNewInviteException catch (_) {
      // Made for keys this phone no longer holds, so no retry can work. The
      // core has already resolved it like a decline; the snack is shown before
      // the list refresh removes this card.
      debugPrint('[Accept] invitation needs a new invite');
      messenger.showSnackBar(needsNewInvite);
      container.invalidate(pendingInvitationsProvider);
    } on CircleRosterFullException catch (_) {
      // A refusal, not a failure: the generic message below tells the user to
      // try again, which can never work here. The held Welcome is untouched, so
      // the invitation is still waiting once they leave a circle.
      debugPrint('[Accept] roster full');
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.invitationRosterFullError(kMaxCirclesPerAccount)),
          backgroundColor: errorColor,
        ),
      );
    } on Object catch (e) {
      // Catch all throwables including FFI errors (which throw Error, not
      // Exception). Secret details are logged via debugPrint (stripped in
      // release) while the user sees a generic message.
      debugPrint('Failed to accept invitation: ${e.runtimeType}');
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.invitationAcceptError),
          backgroundColor: errorColor,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingAction = _LoadingAction.none;
        });
      }
    }
  }

  /// Accepts the invitation, asking for the consent one that would replace a
  /// circle already on this phone needs; `null` when nothing was joined.
  ///
  /// Every exception but that one reaches [_handleAccept], whose handling of
  /// each is the same as for a plain accept.
  Future<Circle?> _acceptOrRejoin(
    ProviderContainer container,
    ScaffoldMessengerState messenger,
    AppLocalizations l10n,
    String inviter,
    Color errorColor,
  ) async {
    final service = container.read(circleServiceProvider);
    final id = widget.invitation.mlsGroupId;
    try {
      return await service.acceptInvitation(id);
    } on InvitationRejoinConfirmationRequiredException catch (_) {
      debugPrint('[Accept] invitation would replace a held circle');
    }
    final offers = await service.rejoinOffersForInvitation(id);
    // None held any more: the copy it would replace may be gone, so the
    // invitation is accepted again, which joins directly or asks again.
    if (offers.isEmpty) return service.acceptInvitation(id);
    final offer = offers.first;
    if (!mounted) return null;
    final choice = await showRejoinCircleDialog(
      context,
      circleName: offer.circleName,
      inviterName: _inviterName(),
    );
    switch (choice) {
      case null:
        // Cancelled: nothing changes, and the invitation stays in the list.
        return null;
      case RejoinChoice.decline:
        try {
          await service.declineGroupRejoin(id);
        } on Object catch (e) {
          debugPrint('[Accept] rejoin decline failed: ${e.runtimeType}');
          messenger.showSnackBar(
            SnackBar(
              content: Text(l10n.invitationDeclineError),
              backgroundColor: errorColor,
            ),
          );
          return null;
        }
        container.invalidate(pendingInvitationsProvider);
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.invitationDeclinedSnack)),
        );
        return null;
      case RejoinChoice.join:
        try {
          return await service.confirmGroupRejoin(id, offer);
        } on InvitationRejoinConfirmationRequiredException catch (_) {
          // This phone's copy moved after the offer was read. The consent is
          // to join this circle again, so the same circle's offer is read
          // once more and confirmed; a second move fails the accept.
          final again = (await service.rejoinOffersForInvitation(id))
              .where((o) => listEquals(o.mlsGroupId, offer.mlsGroupId))
              .firstOrNull;
          if (again == null) rethrow;
          return service.confirmGroupRejoin(id, again);
        }
    }
  }

  /// The inviter as the card names them, for copy composed outside `build`.
  String _inviterLabel() {
    final name = _inviterName();
    return name == null
        ? NpubValidator.shortenForDisplay(widget.invitation.inviterNpub)
        : bidiIsolate(name);
  }

  /// The inviter's resolved name, raw; `null` when only their key is known.
  String? _inviterName() {
    final npub = NpubValidator.shortenForDisplay(widget.invitation.inviterNpub);
    final pubkey = widget.invitation.inviterPubkey;
    final profile = publicProfilesEnabled
        ? ref.read(memberProfileProvider(pubkey)).valueOrNull
        : null;
    final nickname = ref
        .read(contactNicknameProvider(pubkey))
        .valueOrNull
        ?.trim();
    final name = resolveEffectiveMemberName(
      localOverride: nickname,
      profile: profile,
      npubFallback: npub,
    );
    return name == npub ? null : name;
  }

  /// Handles declining the invitation.
  Future<void> _handleDecline() async {
    final l10n = AppLocalizations.of(context);
    // As in `_handleAccept`: nothing after the await may need this card.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    setState(() {
      _loadingAction = _LoadingAction.declining;
    });

    try {
      final circleService = container.read(circleServiceProvider);
      await circleService.declineInvitation(widget.invitation.mlsGroupId);

      // Invalidate provider to refresh UI
      container.invalidate(pendingInvitationsProvider);

      messenger.showSnackBar(
        SnackBar(content: Text(l10n.invitationDeclinedSnack)),
      );
      // Catch all throwables including FFI errors.
    } on Object catch (e) {
      debugPrint('Failed to decline invitation: ${e.runtimeType}');
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.invitationDeclineError),
          backgroundColor: errorColor,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingAction = _LoadingAction.none;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final inviterPubkey = widget.invitation.inviterPubkey;
    final npub = NpubValidator.shortenForDisplay(widget.invitation.inviterNpub);
    // A pure local cache read — no relay traffic, and nothing on this screen
    // triggers a fetch. An inviter is a stranger until the invitation is
    // accepted, and every pubkey handed to the batch refresh is also handed
    // to the picture download, so a name appears here only for someone
    // already cached (a re-invite, or an existing co-member); everyone else
    // stays the npub.
    final profile = publicProfilesEnabled
        ? ref.watch(memberProfileProvider(inviterPubkey)).valueOrNull
        : null;
    // The petname the user saved for this person somewhere else. An
    // invitation has no `CircleMember` row to carry it — the inviter is a
    // stranger until Accept — so without this read the one name an attacker
    // cannot forge would lose to the one they chose (plan §7.2). Non-blank
    // here is exactly the case where the resolver returns the nickname, so
    // it doubles as "the name below came from you".
    final nickname = ref
        .watch(contactNicknameProvider(inviterPubkey))
        .valueOrNull
        ?.trim();
    final hasNickname = nickname != null && nickname.isNotEmpty;
    // The resolver returns [npub] itself when nothing resolved, so comparing
    // against it is how this screen learns whether a NAME exists — the same
    // contract `circle_member_tile` relies on.
    final inviterName = resolveEffectiveMemberName(
      localOverride: nickname,
      profile: profile,
      npubFallback: npub,
    );
    final hasName = inviterName != npub;

    return Semantics(
      label: l10n.invitationCardSemantics(inviterName),
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.base,
          vertical: HavenSpacing.sm,
        ),
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Heading. NOT the circle's name — that is still inside the
              // encrypted Welcome pre-join, and the stand-in this replaces
              // was a hard-coded English literal ("New Circle") shown as the
              // card's largest, boldest element in every locale.
              Text(
                l10n.invitationCardHeading,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: HavenSpacing.sm),

              // Inviter. A resolved name becomes the value of the "Invited
              // by" line, but the npub NEVER leaves the card: a kind-0 name
              // is attacker-chosen — anyone can publish any name — so on the
              // screen whose output is live location sharing the name is the
              // convenience and the key is the identity.
              //
              // Rendered with a resolved name bidi-isolated, announced
              // without: the isolate protects a layout the label never
              // undergoes, and would otherwise put two invisible code points
              // into every announcement of this line. The npub-only case
              // keeps its own label, which says what the string IS rather
              // than reading a bech32 blob out as a name.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Semantics(
                      label: hasName
                          ? l10n.invitationCardInvitedBy(inviterName)
                          : l10n.invitationCardInvitedBySemantics(npub),
                      excludeSemantics: true,
                      child: Text(
                        l10n.invitationCardInvitedBy(
                          hasName ? bidiIsolate(inviterName) : npub,
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  // Outside the excluded subtree above, so the mark keeps a
                  // semantics node of its own.
                  if (hasNickname)
                    _NicknameMark(label: l10n.invitationCardNicknameNote),
                ],
              ),
              if (hasName) ...[
                const SizedBox(height: HavenSpacing.xs),
                // Its own `Text`, forced LTR and never concatenated with the
                // name: within ONE paragraph the bidi algorithm resolves run
                // boundaries across the whole string, so a strong-RTL name
                // could visually reorder the key beside it. Separate widgets
                // cannot interact. It also never ellipsizes — clipping the
                // tail would drop the bech32 checksum the 12/6 form exists
                // for.
                Semantics(
                  label: l10n.invitationCardInvitedBySemantics(npub),
                  excludeSemantics: true,
                  child: Text(
                    npub,
                    textDirection: TextDirection.ltr,
                    style: HavenTypography.monoSmall.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: HavenSpacing.xs),

              // Time ago
              Text(
                _formatTimeAgo(l10n, widget.invitation.invitedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: HavenSpacing.md),

              // Action buttons. An `OverflowBar` rather than a `Row`: at
              // accessibility text scales the two labels stop fitting side by
              // side on a narrow phone, and a Row clips the accept affordance
              // off the edge instead of stacking it.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: HavenSpacing.sm,
                overflowSpacing: HavenSpacing.sm,
                children: [
                  // Decline button
                  OutlinedButton(
                    key: WidgetKeys.invitationDecline(_keyDiscriminator),
                    onPressed: _isLoading ? null : _handleDecline,
                    child: _loadingAction == _LoadingAction.declining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.invitationCardDecline),
                  ),

                  // Accept button
                  FilledButton(
                    key: WidgetKeys.invitationAccept(_keyDiscriminator),
                    onPressed: _isLoading ? null : _handleAccept,
                    child: _loadingAction == _LoadingAction.accepting
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : Text(l10n.invitationCardAccept),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark that says the name beside it is the user's own petname.
///
/// Deliberately not a chip, a badge, or a colour: it answers "where did this
/// name come from", which is provenance, not trust. Nothing on this card may
/// look like a verification — the invitation screen is exactly where a user
/// would over-read one — so it inherits the muted colour of the line it
/// annotates rather than taking an accent. `HavenSecurityColors.encrypted`
/// and `warning` are doubly excluded: both fail WCAG AA at text contrast
/// (3.30:1 and 3.19:1), and the green already means "KeyPackage validated"
/// elsewhere in the app.
class _NicknameMark extends StatelessWidget {
  const _NicknameMark({required this.label});

  /// Announced by a screen reader and shown on long-press. The mark carries
  /// no visible text of its own: a running caption beside every nicknamed
  /// name would be louder than the name.
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scaled by hand because `Icon` does not follow the text scaler: at 2x
    // an unscaled 14dp glyph beside 28dp text reads as a rendering artefact
    // rather than as a mark.
    final glyphSize = MediaQuery.textScalerOf(context).scale(14);
    // The glyph's own box is the Tooltip's whole hit region, and at default
    // text scale that box is 14x14 — below the 24x24dp WCAG 2.2 minimum
    // long-press target, reached only once the glyph itself has grown past
    // it (~1.72x). Pad the HIT REGION out to 24dp without touching the
    // glyph's rendered size (plan F6 — same fix as member_picker.dart's
    // `_PickerNicknameMark`, which this class mirrors).
    final hitTargetSize = glyphSize < 24 ? 24.0 : glyphSize;

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: HavenSpacing.xs),
      // Excluded from semantics so the icon's own label is announced once,
      // not twice (a tooltip contributes its message to the same node).
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: hitTargetSize,
          height: hitTargetSize,
          child: Center(
            child: Icon(
              LucideIcons.tag,
              size: glyphSize,
              color: theme.colorScheme.onSurfaceVariant,
              semanticLabel: label,
            ),
          ),
        ),
      ),
    );
  }
}
