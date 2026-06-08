/// Value-props screen, second step of onboarding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Four scrollable value-prop cards.
///
/// Tapping "Continue" flips the `intro_seen` flag. The `OnboardingShell`
/// listens to `onboardingStepProvider` and automatically advances to
/// the create-identity step once the flag persists.
class ValuePropsScreen extends ConsumerStatefulWidget {
  /// Creates a value-props screen.
  const ValuePropsScreen({super.key});

  @override
  ConsumerState<ValuePropsScreen> createState() => _ValuePropsScreenState();
}

class _ValuePropsScreenState extends ConsumerState<ValuePropsScreen> {
  bool _advancing = false;

  Future<void> _onContinue() async {
    if (_advancing) return;
    setState(() => _advancing = true);
    await ref.read(onboardingControllerProvider.notifier).markIntroSeen();
    if (!mounted) return;
    // Pop back to the OnboardingShell; shell rebuilds and routes to the
    // next step automatically now that `intro_seen = true`.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return OnboardingScaffold(
      stepNumber: kOnboardingStepValueProps,
      totalSteps: kOnboardingTotalSteps,
      showBackButton: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            OnboardingStrings.valuePropsTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.lg),
          const _ValuePropCard(
            icon: LucideIcons.users,
            title: OnboardingStrings.valueProp1Title,
            body: OnboardingStrings.valueProp1Body,
          ),
          const SizedBox(height: HavenSpacing.md),
          const _ValuePropCard(
            icon: LucideIcons.lock,
            title: OnboardingStrings.valueProp2Title,
            body: OnboardingStrings.valueProp2Body,
          ),
          const SizedBox(height: HavenSpacing.md),
          const _ValuePropCard(
            icon: LucideIcons.cloudOff,
            title: OnboardingStrings.valueProp3Title,
            body: OnboardingStrings.valueProp3Body,
          ),
          const SizedBox(height: HavenSpacing.md),
          const _ValuePropCard(
            icon: LucideIcons.smartphone,
            title: OnboardingStrings.valueProp4Title,
            body: OnboardingStrings.valueProp4Body,
          ),
        ],
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.valuePropsCta,
        onPressed: _advancing ? null : _onContinue,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _advancing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text(OnboardingStrings.valuePropsCta),
      ),
    );
  }
}

class _ValuePropCard extends StatelessWidget {
  const _ValuePropCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      label: '$title. $body',
      container: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(HavenSpacing.md),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(HavenSpacing.md),
                ),
                child: Icon(icon, color: colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: HavenSpacing.base),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: HavenSpacing.xs),
                    Text(
                      body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
