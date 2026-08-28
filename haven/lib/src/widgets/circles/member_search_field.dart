/// The one text field on the two screens that invite people into a circle.
///
/// It does two jobs at once: it FILTERS the local directory of people the
/// user already shares a circle with (reported through `onQueryChanged` on
/// every keystroke, with no debounce — plan §9.3), and it STAGES a pasted or
/// scanned identifier (through `onMemberAdded`).
///
/// Both `flutter drive` lanes reach the invite flow through this widget:
/// they type into [WidgetKeys.memberSearchInput] and submit with
/// [TextInputAction.done]. If submitting ever stops staging, those lanes do
/// not fail — they hang to a 60 s timeout (plan §9.2). Keep the key, the
/// action, and the submit-stages behaviour together.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/text_input_privacy.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_pick_state.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Search-and-add field for circle members.
class MemberSearchField extends StatefulWidget {
  /// Creates a [MemberSearchField].
  const MemberSearchField({
    required this.onMemberAdded,
    required this.onQrScanRequested,
    required this.entryStateFor,
    this.onQueryChanged,
    super.key,
  });

  /// Called with a validated npub the user chose to stage.
  final void Function(String npub) onMemberAdded;

  /// Called when the QR button is pressed.
  final VoidCallback onQrScanRequested;

  /// Whether the host screen can accept this npub, and if not, why.
  ///
  /// Asked BEFORE anything is staged and before any relay is dialled, so the
  /// three refusals hold offline. The check this replaces compared a hex
  /// pubkey read out of a FETCHED KeyPackage, which meant that with no
  /// network there was nothing to compare and the add went ahead (§9.5).
  final MemberPickState Function(String npub) entryStateFor;

  /// Called with the field's text on every keystroke, so the host can filter
  /// its list in the same frame. Never debounced.
  final void Function(String query)? onQueryChanged;

  @override
  State<MemberSearchField> createState() => _MemberSearchFieldState();
}

class _MemberSearchFieldState extends State<MemberSearchField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// The refusal currently shown, or `null` while the helper line is showing.
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => widget.onQueryChanged?.call(_controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final error = _errorMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: WidgetKeys.memberSearchInput,
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: l10n.memberSearchHint,
                  prefixIcon: const Icon(LucideIcons.userPlus),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(LucideIcons.clipboard),
                        onPressed: _pasteFromClipboard,
                        tooltip: l10n.memberSearchPasteTooltip,
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.circlePlus),
                        onPressed: _validateAndAdd,
                        tooltip: l10n.memberSearchAddTooltip,
                      ),
                    ],
                  ),
                  // Deliberately NO errorText: it grows the decoration
                  // mid-keystroke, moving the field out from under the
                  // caret. The message goes on the sibling line below.
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _validateAndAdd(),
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                // What is typed here identifies a person. The keyboard's
                // learned-word dictionary and the platform autofill service
                // both sit outside Haven's encrypted storage, outside its
                // logout wipe, and inside the OS backup — and an empty hint
                // list, the framework default, still enables autofill.
                enableIMEPersonalizedLearning: false,
                autofillHints: kNoAutofill,
              ),
            ),
            const SizedBox(width: HavenSpacing.sm),
            IconButton.filled(
              onPressed: widget.onQrScanRequested,
              icon: const Icon(LucideIcons.scanQrCode),
              tooltip: l10n.memberSearchScanTooltip,
            ),
          ],
        ),
        const SizedBox(height: HavenSpacing.xs),
        // One line, always present, carrying either the refusal or the
        // guidance. `memberSearchHelper` is the only place the app says
        // where an identifier comes from, so an error borrows this line and
        // then gives it back.
        Padding(
          padding: const EdgeInsetsDirectional.only(start: HavenSpacing.base),
          child: Text(
            error ?? l10n.memberSearchHelper,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: error == null
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    _controller.text = text;
    _validateAndAdd();
  }

  void _validateAndAdd() {
    final l10n = AppLocalizations.of(context);
    final input = _controller.text.trim();
    if (input.isEmpty) {
      _setError(null);
      return;
    }

    // Every string `extract` returns already satisfies what
    // `NpubValidator.validate` checks — the `npub1` prefix, 63 characters and
    // a bech32 charset — so there is no second validation step here that
    // could fail, and none of `NpubValidationException`'s untranslated
    // English messages can reach the screen.
    final npub = NpubValidator.extract(input);
    if (npub == null) {
      _setError(l10n.memberSearchNoValidId);
      return;
    }

    final refusal = memberPickRefusalMessage(l10n, widget.entryStateFor(npub));
    if (refusal != null) {
      _setError(refusal);
      return;
    }

    widget.onMemberAdded(npub);
    _controller.clear();
    _setError(null);
    _focusNode.requestFocus();
  }

  /// Shows [message] on the helper line, announcing it once when it appears.
  ///
  /// The framework spoke `InputDecoration.errorText` for us; a message on a
  /// plain sibling line is silent unless it is announced. Not a live region:
  /// that re-announces its whole subtree on every rebuild, and this line
  /// carries the always-present helper text.
  void _setError(String? message) {
    if (_errorMessage == message) return;
    setState(() => _errorMessage = message);
    if (message == null) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }
}
