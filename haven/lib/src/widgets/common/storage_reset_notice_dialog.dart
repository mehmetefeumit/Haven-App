/// The one-time notice shown after the MDK v0.10.4 storage reset.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/long_message_snack_bar.dart';

/// How the user answered the storage-reset notice.
enum StorageResetNoticeChoice {
  /// Carry on with Haven's default relay settings.
  continueWithDefaults,

  /// Review the relay settings first.
  openRelaySettings,
}

/// Tells the user what the storage reset kept, what it removed, and that it
/// reset their relay settings to defaults — and that their relay lists and
/// KeyPackage are not published until they answer, so they can add their own
/// relays first.
///
/// Not dismissable by tapping outside or by the back gesture: both answers
/// release relay-list publishing, so the user must pick one. An unanswered
/// notice stays owed and returns next launch.
class StorageResetNoticeDialog extends StatelessWidget {
  const StorageResetNoticeDialog._();

  /// Shows the notice and resolves with the user's answer.
  static Future<StorageResetNoticeChoice?> show(BuildContext context) {
    return showDialog<StorageResetNoticeChoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const StorageResetNoticeDialog._(),
    );
  }

  /// Runs the notice to its answer and reports whether the reset was
  /// acknowledged, calling [onAcknowledged] once it is.
  ///
  /// "Relay settings" first runs [openRelaySettings] to completion, so the
  /// user can add their own relays before a relay list is published; coming
  /// back counts as the answer. An unanswered notice acknowledges nothing. An
  /// [acknowledge] that throws says so on a snackbar whose Try Again runs it
  /// again — and [onAcknowledged] once that succeeds — so publishing is not
  /// held for the rest of the session; left alone, the notice is owed again
  /// next launch.
  static Future<bool> answer(
    BuildContext context, {
    required Future<void> Function() openRelaySettings,
    required Future<void> Function() acknowledge,
    required void Function() onAcknowledged,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = AppLocalizations.of(context);
    Future<bool> tryAcknowledge() async {
      try {
        await acknowledge();
        return true;
      } on Object catch (e) {
        debugPrint('[StorageReset] acknowledge failed: ${e.runtimeType}');
        return false;
      }
    }

    // Built while `context` is certainly mounted; shown after the awaits,
    // by which time the messenger may be gone too.
    late final SnackBar failed;
    void sayFailed() {
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(failed);
      }
    }

    Future<void> retry() async {
      if (await tryAcknowledge()) {
        onAcknowledged();
      } else {
        sayFailed();
      }
    }

    failed = longMessageSnackBar(
      context,
      l10n.storageResetAcknowledgeFailed,
      action: SnackBarAction(
        label: l10n.commonTryAgain,
        onPressed: () => unawaited(retry()),
      ),
    );

    final choice = await show(context);
    if (choice == null) return false;
    if (choice == StorageResetNoticeChoice.openRelaySettings) {
      await openRelaySettings();
    }
    if (!await tryAcknowledge()) {
      sayFailed();
      return false;
    }
    onAcknowledged();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = Theme.of(context).textTheme.bodyMedium;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        // Named by its title on every platform: Material only lets the title
        // name the route on iOS and macOS, and elsewhere a screen reader would
        // announce a generic "Alert".
        semanticLabel: l10n.storageResetTitle,
        // Title and paragraphs scroll together, so at large text on a small
        // phone nothing overflows and the answers stay on screen.
        scrollable: true,
        title: Text(l10n.storageResetTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.storageResetKept, style: body),
            const SizedBox(height: HavenSpacing.base),
            Text(l10n.storageResetLost, style: body),
            const SizedBox(height: HavenSpacing.base),
            Text(l10n.storageResetRelays, style: body),
          ],
        ),
        actions: [
          TextButton(
            key: WidgetKeys.storageResetOpenRelaySettings,
            onPressed: () => Navigator.of(
              context,
            ).pop(StorageResetNoticeChoice.openRelaySettings),
            child: Text(l10n.storageResetOpenRelaySettings),
          ),
          FilledButton(
            key: WidgetKeys.storageResetContinue,
            onPressed: () => Navigator.of(
              context,
            ).pop(StorageResetNoticeChoice.continueWithDefaults),
            child: Text(l10n.storageResetContinue),
          ),
        ],
      ),
    );
  }
}
