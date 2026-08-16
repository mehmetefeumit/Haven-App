/// The admin remove-a-member interaction: confirm, run, report.
///
/// Kept out of the member list so the list stays a pure rendering of the
/// roster: it decides WHO may be removed, this file decides what happens
/// when the affordance is used. The removal itself lives one layer deeper
/// still, in [MemberRemovalController], which is where the one-at-a-time
/// rule and the service call are tested without a widget tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/member_removal_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/npub_validator.dart';

/// Asks the admin to confirm removing [member] from [circle], performs the
/// removal if they do, and reports the outcome in the same words to the
/// screen and to a screen reader.
///
/// Nothing is destroyed locally on the way: the dialog is the only guard,
/// and a declined dialog reaches no service. The action is irreversible in
/// the sense that matters to the user — re-adding someone needs a fresh
/// invitation — which is why the body says so rather than offering an undo
/// this protocol cannot honour.
Future<void> confirmAndRemoveMember({
  required BuildContext context,
  required WidgetRef ref,
  required Circle circle,
  required CircleMember member,
}) async {
  final l10n = AppLocalizations.of(context);
  final name = resolveRemovalDisplayName(ref, member);

  final confirmed =
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // The body is four sentences of consequence, and `AlertDialog`
          // does NOT scroll its content by default: it hands it a Flexible,
          // where a Text simply CLIPS — no overflow stripe, no exception,
          // nothing for a test to catch. Measured at 2.0x on a 360x690
          // phone, the German body needed 1720px and was given 298px, so
          // everything from "what stays on their phone" onwards was
          // invisible on the one screen where the user is deciding.
          scrollable: true,
          title: Text(l10n.circleMemberRemoveDialogTitle(name)),
          content: Text(l10n.circleMemberRemoveDialogBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              key: WidgetKeys.memberRemoveConfirm,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: Text(l10n.circleMemberRemoveConfirm),
            ),
          ],
        ),
      ) ??
      false;

  if (!confirmed || !context.mounted) return;

  // Captured before the first await: the sheet can be dismissed while the
  // commit is in flight, and the outcome must still reach the user.
  final messenger = ScaffoldMessenger.of(context);
  final view = View.of(context);
  final textDirection = Directionality.of(context);

  // The row's spinner is not a live region (it would re-announce on every
  // rebuild), so this is the one announcement that the work started.
  await SemanticsService.sendAnnouncement(
    view,
    l10n.circleMemberRemoveInProgress(name),
    textDirection,
  );

  final outcome = await ref
      .read(memberRemovalProvider.notifier)
      .remove(circle: circle, memberPubkeyHex: member.pubkey);

  // A lost race against a removal already running: the affordance is
  // disabled while that is true, so there is nothing to tell the user that
  // the disabled button has not already said.
  if (outcome == MemberRemovalOutcome.busy) return;

  final message = switch (outcome) {
    MemberRemovalOutcome.removed => l10n.circleMemberRemoveSuccess(name),
    MemberRemovalOutcome.failed => l10n.circleMemberRemoveError(name),
    MemberRemovalOutcome.busy => '',
  };
  messenger.showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
  // A SnackBar is not a live region; without this the outcome of a
  // destructive action is silent to a screen reader.
  await SemanticsService.sendAnnouncement(view, message, textDirection);
}

/// The name to put in front of the admin when they are about to remove
/// [member] — resolved exactly as `CircleMemberTile` resolves the row's
/// title, so the dialog names what the admin tapped.
///
/// Never the word "member": when nothing better resolves, the truncated
/// npub is what the row itself is showing, and a confirmation that says
/// less than the row it came from is a confirmation the user cannot check.
@visibleForTesting
String resolveRemovalDisplayName(WidgetRef ref, CircleMember member) {
  final npubFallback = NpubValidator.truncate(
    member.npub,
    prefixLength: 12,
    suffixLength: 6,
  );
  final profile = publicProfilesEnabled
      ? ref.read(memberProfileProvider(member.pubkey)).valueOrNull
      : null;
  return resolveEffectiveMemberName(
    localOverride: member.displayName,
    profile: profile,
    npubFallback: npubFallback,
  );
}
