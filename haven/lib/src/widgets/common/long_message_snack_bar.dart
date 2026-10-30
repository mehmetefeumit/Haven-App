/// A snackbar for a message the user has to read and act on.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';

/// The most of the screen's height the message may take before it scrolls.
const double _kMaxMessageHeightFraction = 0.4;

/// A snackbar carrying [message] that stays until the user closes it — no
/// timeout, so a remedy is never taken away mid-read, by eye or by screen
/// reader (WCAG 2.2.1). It closes with Dismiss, or — given [action] — with
/// that action or the close button. [error] paints it in the theme's error
/// colour.
///
/// At 200% text a two-sentence remedy can be taller than a small phone, and a
/// snackbar clips what does not fit, so the message scrolls past
/// [_kMaxMessageHeightFraction] of the screen. A given action sits under it,
/// not in the snackbar's own action slot: Material sizes that slot for one
/// unscaled line, so a long label would overflow it, while here it wraps. The
/// slot is what makes Material keep a snackbar up, so [SnackBar.persist] is
/// set outright.
///
/// Persisting holds the messenger's queue: a later snackbar waits behind this
/// one until the user closes it. So no caller may clear the queue to make room
/// for its own ([ScaffoldMessengerState.clearSnackBars] would throw the remedy
/// away); replace only your own, as `LocationSettingsPage` does.
SnackBar longMessageSnackBar(
  BuildContext context,
  String message, {
  bool error = false,
  SnackBarAction? action,
}) {
  final theme = Theme.of(context);
  return SnackBar(
    content: _LongMessage(
      message: message,
      action: action,
      actionColor:
          theme.snackBarTheme.actionTextColor ??
          theme.colorScheme.inversePrimary,
    ),
    persist: true,
    backgroundColor: error ? theme.colorScheme.error : null,
    showCloseIcon: action != null,
    action: action == null
        ? SnackBarAction(
            label: AppLocalizations.of(context).commonDismiss,
            onPressed: () {},
          )
        : null,
  );
}

class _LongMessage extends StatefulWidget {
  const _LongMessage({
    required this.message,
    required this.action,
    required this.actionColor,
  });

  final String message;
  final SnackBarAction? action;
  final Color actionColor;

  @override
  State<_LongMessage> createState() => _LongMessageState();
}

class _LongMessageState extends State<_LongMessage> {
  final _scroll = ScrollController();
  bool _pressed = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = DefaultTextStyle.of(context).style.color;
    final message = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight:
            MediaQuery.sizeOf(context).height * _kMaxMessageHeightFraction,
      ),
      // The thumb shows only when the message does not fit: the one cue that
      // more of it is below. Drawn in the message's own colour, at full
      // strength: the platform scrollbars are tuned for a light page, not a
      // snackbar, and any fade drops it under 3:1 on the error colour.
      child: RawScrollbar(
        controller: _scroll,
        thumbVisibility: true,
        thickness: 4,
        radius: const Radius.circular(2),
        thumbColor: textColor,
        // Not a second, desktop scrollbar on top of this one.
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: _scroll,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(widget.message),
            ),
          ),
        ),
      ),
    );
    final action = widget.action;
    if (action == null) return message;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        message,
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: widget.actionColor),
            // As Material's own action: pressing it closes the snackbar, and
            // only the first press counts.
            onPressed: () {
              if (_pressed) return;
              _pressed = true;
              ScaffoldMessenger.of(
                context,
              ).hideCurrentSnackBar(reason: SnackBarClosedReason.action);
              action.onPressed();
            },
            child: Text(action.label),
          ),
        ),
      ],
    );
  }
}
