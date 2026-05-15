/// Bottom sheet for adding a custom relay URL to the user's preferences.
///
/// MD3 transient input pattern: keeps the relay list visible above so
/// the user sees the new entry appear in context. Auto-prefixes
/// `wss://`, debounces validation, surfaces specific error messages,
/// and disables the Add button while the input is invalid.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/relay_url_validator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows the add-relay bottom sheet.
///
/// Returns the canonical URL the caller should add to its category, or
/// `null` if the user cancelled. Caller is responsible for the actual
/// `addRelay` call so it can surface category-specific errors.
Future<String?> showAddRelaySheet(
  BuildContext context, {
  required RelayCategory category,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HavenSpacing.base),
      ),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: _AddRelaySheet(category: category),
    ),
  );
}

class _AddRelaySheet extends StatefulWidget {
  const _AddRelaySheet({required this.category});

  final RelayCategory category;

  @override
  State<_AddRelaySheet> createState() => _AddRelaySheetState();
}

class _AddRelaySheetState extends State<_AddRelaySheet> {
  static const _debounce = Duration(milliseconds: 500);

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;
  RelayValidationResult? _result;
  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    // Autofocus the field so users can start typing immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    setState(() => _isDirty = true);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      if (!mounted) return;
      setState(() {
        _result = validateRelayUrl(_controller.text);
      });
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _controller
      ..text = text
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    // Force immediate validation on paste — bypass the debounce.
    setState(() {
      _result = validateRelayUrl(text);
    });
  }

  void _submit() {
    final result = _result ?? validateRelayUrl(_controller.text);
    if (result.canonicalUrl == null) return;
    Navigator.of(context).pop(result.canonicalUrl);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Show error only after the user has typed something, so the field
    // does not flash a misleading "invalid" message on initial focus.
    final showError = _isDirty && _result != null && _result!.error != null;
    final canSubmit = _result?.isValid ?? false;
    final categoryLabel = switch (widget.category) {
      RelayCategory.inbox => 'Inbox',
      RelayCategory.keyPackage => 'KeyPackage',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpacing.base,
        HavenSpacing.sm,
        HavenSpacing.base,
        HavenSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle.
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: HavenSpacing.md),
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title.
          Semantics(
            header: true,
            child: Text(
              'Add $categoryLabel relay',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: HavenSpacing.md),
          // Input row. Wrapped in Semantics(liveRegion: true) so screen
          // readers announce validation errors when the debounced
          // validator updates `errorText`. Material's `InputDecoration`
          // does not mark its decoration text as a live region by
          // default; AT users would otherwise miss the error.
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    onSubmitted: canSubmit ? (_) => _submit() : null,
                    decoration: InputDecoration(
                      hintText: 'wss://relay.example.com',
                      border: const OutlineInputBorder(),
                      errorText: showError ? _result!.error : null,
                      errorMaxLines: 2,
                      suffixIcon: IconButton(
                        tooltip: 'Paste from clipboard',
                        icon: const Icon(LucideIcons.clipboardPaste),
                        onPressed: _pasteFromClipboard,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: HavenSpacing.md),
          // Action row.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: HavenSpacing.sm),
              FilledButton(
                onPressed: canSubmit ? _submit : null,
                child: const Text('Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
