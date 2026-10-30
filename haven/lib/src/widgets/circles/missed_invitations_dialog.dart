/// Who a partial invitation send missed, one tap away from the snackbar that
/// reports the count.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/bidi_isolate.dart';
import 'package:haven/src/utils/npub_validator.dart';

/// How long a row says its key was copied.
const Duration kMissedInvitationCopiedDuration = Duration(seconds: 2);

/// A "Show who" action for the snackbar carrying [message], which reports
/// that [sent] of [total] invitations were sent. It opens
/// [MissedInvitationsDialog] on [navigator], which outlives the page that sent
/// them, as the snackbar does.
///
/// Null when nobody was sent one (the count already says it was everyone) or
/// when [unsent] is not everyone who was missed, which would read as all.
SnackBarAction? missedInvitationsAction({
  required NavigatorState navigator,
  required AppLocalizations l10n,
  required String message,
  required List<String> unsent,
  required int sent,
  required int total,
}) {
  if (sent == 0 || unsent.isEmpty || unsent.length != total - sent) {
    return null;
  }
  return SnackBarAction(
    label: l10n.missedInvitationsShowWho,
    onPressed: () {
      if (!navigator.mounted) return;
      showDialog<void>(
        context: navigator.context,
        builder: (_) =>
            MissedInvitationsDialog(message: message, npubs: unsent),
      );
    },
  );
}

/// Repeats [message] — the snackbar that opened it closes, and it carries the
/// remedy — then lists each person whose invitation was not sent by their
/// shortened public key; a long press (or the screen reader's copy action)
/// copies the full key.
class MissedInvitationsDialog extends StatelessWidget {
  /// Creates a [MissedInvitationsDialog] listing [npubs] under [message].
  const MissedInvitationsDialog({
    required this.message,
    required this.npubs,
    super.key,
  });

  /// The snackbar's message, remedy included.
  final String message;

  /// The people whose invitation was not sent.
  final List<String> npubs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = l10n.missedInvitationsTitle(npubs.length);
    return AlertDialog(
      semanticLabel: title,
      title: Text(title),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: HavenSpacing.sm),
          for (final npub in npubs) _MissedNpubTile(npub: npub),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}

class _MissedNpubTile extends StatefulWidget {
  const _MissedNpubTile({required this.npub});

  final String npub;

  @override
  State<_MissedNpubTile> createState() => _MissedNpubTileState();
}

class _MissedNpubTileState extends State<_MissedNpubTile> {
  Timer? _copied;

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    void copy() => unawaited(_copy(l10n));
    // VoiceOver has no discoverable long press, so copy is also a named
    // custom action.
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.circleMemberCopyPublicKeyHint): copy,
      },
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          bidiIsolate(NpubValidator.shortenForDisplay(widget.npub)),
          style: HavenTypography.mono.copyWith(fontSize: 14),
        ),
        // Confirmed in the row: a snackbar would sit under the dialog's
        // barrier.
        subtitle: _copied == null
            ? null
            : Text(l10n.circleMemberPublicKeyCopied),
        onLongPress: copy,
      ),
    );
  }

  Future<void> _copy(AppLocalizations l10n) async {
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    await HapticFeedback.mediumImpact();
    await Clipboard.setData(ClipboardData(text: widget.npub));
    if (!mounted) return;
    _copied?.cancel();
    setState(() {
      _copied = Timer(kMissedInvitationCopiedDuration, () {
        if (mounted) setState(() => _copied = null);
      });
    });
    await SemanticsService.sendAnnouncement(
      view,
      l10n.circleMemberPublicKeyCopied,
      textDirection,
    );
  }
}
