/// Import-existing-key screen.
///
/// Reachable from `CreateIdentityScreen` via the secondary "Already have a
/// key?" affordance. Accepts a bech32 `nsec1...` string and forwards it to
/// `IdentityNotifier.importFromNsec`. On success the underlying
/// `identity_ready` flag flips, the onboarding shell rebuilds, and the user
/// lands on the display-name screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/theme/theme.dart';

/// Screen that imports an existing identity from a bech32 secret key.
class ImportNsecScreen extends ConsumerStatefulWidget {
  /// Creates an import screen.
  const ImportNsecScreen({super.key});

  @override
  ConsumerState<ImportNsecScreen> createState() => _ImportNsecScreenState();
}

class _ImportNsecScreenState extends ConsumerState<ImportNsecScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    // Clear before disposing so the buffer holding the secret is zeroed
    // before Dart frees the backing string.
    _controller.text = '';
    _controller.dispose();
    super.dispose();
  }

  bool _looksLikeNsec(String input) {
    final trimmed = input.trim();
    return trimmed.length >= 10 && trimmed.toLowerCase().startsWith('nsec1');
  }

  Future<void> _onImport() async {
    if (_busy) return;
    final input = _controller.text.trim();
    if (!_looksLikeNsec(input)) {
      setState(() => _error = OnboardingStrings.importInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    await ref.read(identityNotifierProvider.notifier).importFromNsec(input);
    if (!mounted) return;

    final state = ref.read(identityNotifierProvider);
    if (state.hasError) {
      setState(() {
        _busy = false;
        _error = OnboardingStrings.importError;
      });
      return;
    }

    // Clear the text buffer to minimise plaintext secret lifetime.
    _controller.text = '';

    ref
      ..invalidate(keyPackagePublisherProvider)
      ..read(keyPackagePublisherProvider);

    // Pop back to the onboarding shell; the derived step provider will
    // route the user to the display-name screen.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return OnboardingScaffold(
      showBackButton: true,
      announcement: OnboardingStrings.importTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            OnboardingStrings.importTitle,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: HavenSpacing.base),
          Text(
            OnboardingStrings.importBody,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          TextField(
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: true,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
            decoration: InputDecoration(
              hintText: OnboardingStrings.importHint,
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _onImport(),
          ),
        ],
      ),
      primaryAction: FilledButton(
        onPressed: _busy ? null : _onImport,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _busy
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: HavenSpacing.sm),
                  Text(OnboardingStrings.importLoading),
                ],
              )
            : const Text(OnboardingStrings.importCta),
      ),
    );
  }
}
