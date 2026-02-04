/// Search bar for adding members by npub or QR code.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';

/// Search bar for adding members by npub or QR code.
///
/// Features:
/// - Text input for npub entry with validation
/// - Paste button for accessibility
/// - QR scan button (triggers [onQrScanRequested])
/// - Debounced validation feedback
class MemberSearchBar extends StatefulWidget {
  /// Creates a [MemberSearchBar].
  const MemberSearchBar({
    required this.onMemberAdded,
    required this.onQrScanRequested,
    this.existingMembers = const [],
    super.key,
  });

  /// Callback when a valid member npub is added.
  final void Function(String npub) onMemberAdded;

  /// Callback when QR scan button is pressed.
  final VoidCallback onQrScanRequested;

  /// Already selected member npubs (to prevent duplicates).
  final List<String> existingMembers;

  @override
  State<MemberSearchBar> createState() => _MemberSearchBarState();
}

class _MemberSearchBarState extends State<MemberSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  hintText: 'Enter npub...',
                  prefixIcon: const Icon(Icons.person_add),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Paste button
                      IconButton(
                        icon: const Icon(Icons.content_paste),
                        onPressed: _pasteFromClipboard,
                        tooltip: 'Paste npub from clipboard',
                      ),
                      // Add button
                      IconButton(
                        icon: const Icon(Icons.add_circle),
                        onPressed: _validateAndAdd,
                        tooltip: 'Add member',
                      ),
                    ],
                  ),
                  errorText: _errorMessage,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _validateAndAdd(),
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
              ),
            ),
            const SizedBox(width: HavenSpacing.sm),
            // QR scan button
            IconButton.filled(
              onPressed: widget.onQrScanRequested,
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan QR Code',
            ),
          ],
        ),
        const SizedBox(height: HavenSpacing.xs),
        // Helper text
        Padding(
          padding: const EdgeInsets.only(left: HavenSpacing.base),
          child: Text(
            'Ask contacts for their Haven QR code or npub',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _controller.text = data.text!;
      _validateAndAdd();
    }
  }

  void _validateAndAdd() {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _errorMessage = null);
      return;
    }

    try {
      // Extract npub from various formats
      final extracted = NpubValidator.extract(input);
      if (extracted == null) {
        setState(() => _errorMessage = 'No valid npub found in input');
        return;
      }

      final npub = NpubValidator.validate(extracted);

      // Check for duplicates
      if (widget.existingMembers.contains(npub)) {
        setState(() => _errorMessage = 'Member already added');
        return;
      }

      // Success - add member and clear input
      widget.onMemberAdded(npub);
      _controller.clear();
      setState(() => _errorMessage = null);
      _focusNode.requestFocus();
    } on NpubValidationException catch (e) {
      setState(() => _errorMessage = e.message);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }
}

/// Sets an npub in the search bar from external source (e.g., QR scan).
///
/// Use this to programmatically add an npub scanned from QR.
extension MemberSearchBarController on GlobalKey<_MemberSearchBarState> {
  /// Sets the text and triggers validation.
  void setNpub(String npub) {
    final state = currentState;
    if (state != null) {
      state._controller.text = npub;
      state._validateAndAdd();
    }
  }
}
