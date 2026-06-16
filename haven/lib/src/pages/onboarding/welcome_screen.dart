/// First screen of the onboarding flow.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/pages/onboarding/value_props_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';

/// Hero screen shown on the user's very first launch.
///
/// Shows Haven's primary tagline and a single CTA that pushes the
/// [ValuePropsScreen] onto the local onboarding navigator. The
/// `intro_seen` flag is not flipped here — only [ValuePropsScreen]'s
/// Continue action flips it — so a kill between Welcome and ValueProps
/// returns the user to Welcome on relaunch.
class WelcomeScreen extends StatelessWidget {
  /// Creates a welcome screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stepLabel = OnboardingStrings.stepOf(
      kOnboardingStepWelcome,
      kOnboardingTotalSteps,
    );

    return OnboardingScaffold(
      stepNumber: kOnboardingStepWelcome,
      totalSteps: kOnboardingTotalSteps,
      announcement: '$stepLabel. ${OnboardingStrings.appName}',
      body: Padding(
        padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: HavenLogo()),
            const SizedBox(height: HavenSpacing.xl),
            Text(
              OnboardingStrings.appName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineLarge,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              OnboardingStrings.welcomeHeadline,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
            Text(
              OnboardingStrings.welcomeSub,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.welcomeCta,
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ValuePropsScreen()),
          );
        },
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text(OnboardingStrings.welcomeCta),
      ),
    );
  }
}
