/// Display-name screen (after identity creation, before the ready screen).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Captures the user's local-only display name.
///
/// The user can explicitly skip via the secondary button. Either path flips
/// the `display_name_set` flag so the step machine advances to
/// [OnboardingStep.ready].
class DisplayNameScreen extends ConsumerStatefulWidget {
  /// Creates a display-name screen.
  const DisplayNameScreen({super.key});

  @override
  ConsumerState<DisplayNameScreen> createState() => _DisplayNameScreenState();
}

class _DisplayNameScreenState extends ConsumerState<DisplayNameScreen> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish({required bool saveName}) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _busy = true);
    final notifier = ref.read(onboardingControllerProvider.notifier);

    try {
      if (saveName) {
        final text = _controller.text.trim();
        if (text.isNotEmpty) {
          final service = ref.read(identityServiceProvider);
          await service.setDisplayName(text);
          ref.invalidate(displayNameProvider);
        }
      }
      await notifier.markDisplayNameSet();
    } on IdentityServiceException catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.onboardingDisplayNameError),
          backgroundColor: HavenSecurityColors.danger,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return OnboardingScaffold(
      stepNumber: kOnboardingStepDisplayName,
      totalSteps: kOnboardingTotalSteps,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Icon(
                LucideIcons.user,
                size: 48,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: HavenSpacing.xl),
          Text(
            l10n.onboardingDisplayNameTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.base),
          Text(
            l10n.onboardingDisplayNameBody,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.lg),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              LengthLimitingTextInputFormatter(64),
              FilteringTextInputFormatter.singleLineFormatter,
            ],
            decoration: InputDecoration(
              hintText: l10n.onboardingDisplayNameHint,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _finish(saveName: true),
          ),
        ],
      ),
      secondaryAction: TextButton(
        key: WidgetKeys.displayNameSkip,
        onPressed: _busy ? null : () => _finish(saveName: false),
        child: Text(l10n.commonSkip),
      ),
      primaryAction: FilledButton(
        onPressed: _busy ? null : () => _finish(saveName: true),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.commonContinue),
      ),
    );
  }
}
