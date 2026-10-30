/// The consent an invitation needs when it would replace a circle this phone
/// already holds.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/bidi_isolate.dart';

/// What the user chose in a [RejoinCircleDialog].
enum RejoinChoice {
  /// Join the circle again: this phone's copy is replaced.
  join,

  /// Decline the invitation.
  decline,
}

/// Asks whether to join [circleName] again from [inviterName]'s invitation;
/// [inviterName] is `null` when no name resolves.
///
/// Returns `null` when the user cancels or dismisses it: nothing changes and
/// the invitation stays in the list.
Future<RejoinChoice?> showRejoinCircleDialog(
  BuildContext context, {
  required String circleName,
  required String? inviterName,
}) => showDialog<RejoinChoice>(
  context: context,
  builder: (_) =>
      RejoinCircleDialog(circleName: circleName, inviterName: inviterName),
);

/// The rejoin consent dialog.
class RejoinCircleDialog extends StatelessWidget {
  /// Creates the dialog for [circleName], offered by [inviterName].
  const RejoinCircleDialog({
    required this.circleName,
    required this.inviterName,
    super.key,
  });

  /// This phone's name for the circle the invitation would replace.
  final String circleName;

  /// The inviter's resolved name, raw; `null` when only their key is known.
  /// The card above shows that key, and the dialog never reads a bech32
  /// string aloud as a name.
  final String? inviterName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final inviter = inviterName;
    // Rendered with the names bidi-isolated, announced without: the isolate
    // protects a layout the label never undergoes, and a screen reader would
    // otherwise meet invisible code points in the sentence.
    final shown = inviter == null
        ? l10n.rejoinDialogBodyUnnamed(bidiIsolate(circleName))
        : l10n.rejoinDialogBody(bidiIsolate(inviter), bidiIsolate(circleName));
    final spoken = inviter == null
        ? l10n.rejoinDialogBodyUnnamed(circleName)
        : l10n.rejoinDialogBody(inviter, circleName);
    return AlertDialog(
      // `AlertDialog` clips content it does not scroll, and the consequence
      // of joining again is the body's last sentence: at large text sizes
      // it must stay readable before the choice.
      scrollable: true,
      title: Text(l10n.rejoinDialogTitle),
      content: Semantics(
        label: spoken,
        excludeSemantics: true,
        child: Text(shown),
      ),
      actions: [
        // The default: it holds input focus, so Enter or a keyboard's
        // activate keeps the invitation and changes nothing. (A screen reader
        // starts at the title, and reaches this first among the actions.)
        TextButton(
          key: WidgetKeys.rejoinDialogCancel,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          key: WidgetKeys.rejoinDialogDecline,
          onPressed: () => Navigator.of(context).pop(RejoinChoice.decline),
          child: Text(l10n.invitationCardDecline),
        ),
        TextButton(
          key: WidgetKeys.rejoinDialogConfirm,
          onPressed: () => Navigator.of(context).pop(RejoinChoice.join),
          child: Text(l10n.rejoinDialogConfirm),
        ),
      ],
    );
  }
}
