/// 13+ self-attestation age gate, shown after the intro and before identity
/// creation when [kAgeGateEnabled] is `true`.
///
/// A lightweight self-attestation (matching Signal's 13+ floor) that keeps
/// Haven in a general-audience, non-child-directed posture. It is NOT identity
/// verification; see `docs/MAP_AND_PRIVACY_BACKLOG.md` for the COPPA/GDPR/store
/// context and the items requiring legal counsel before public launch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Confirms the user meets Haven's 13+ minimum age.
///
/// The primary action calls [OnboardingController.markAgeConfirmed], which
/// advances the step machine. Users who indicate they are under 13 see a
/// polite, dismissible explanation and are not advanced.
class AgeGateScreen extends ConsumerStatefulWidget {
  /// Creates an age-gate screen.
  const AgeGateScreen({super.key});

  @override
  ConsumerState<AgeGateScreen> createState() => _AgeGateScreenState();
}

class _AgeGateScreenState extends ConsumerState<AgeGateScreen> {
  bool _busy = false;

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(onboardingControllerProvider.notifier).markAgeConfirmed();
    // No explicit navigation — the shell re-routes once the flag persists.
  }

  Future<void> _showUnderAge() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(OnboardingStrings.ageGateUnderTitle),
        content: const Text(OnboardingStrings.ageGateUnderBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(OnboardingStrings.ageGateUnderDismiss),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return OnboardingScaffold(
      stepNumber: kOnboardingStepAgeGate,
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
                LucideIcons.calendarCheck,
                size: 48,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: HavenSpacing.xl),
          Text(
            OnboardingStrings.ageGateTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.base),
          Text(
            OnboardingStrings.ageGateBody,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      secondaryAction: TextButton(
        key: WidgetKeys.ageGateUnder,
        onPressed: _busy ? null : _showUnderAge,
        child: const Text(OnboardingStrings.ageGateUnderCta),
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.ageGateConfirm,
        onPressed: _busy ? null : _confirm,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.onPrimary,
                ),
              )
            : const Text(OnboardingStrings.ageGateConfirmCta),
      ),
    );
  }
}
