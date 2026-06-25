/// First screen of the onboarding flow.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
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
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stepLabel = l10n.onboardingStepOf(
      kOnboardingStepWelcome,
      kOnboardingTotalSteps,
    );

    return OnboardingScaffold(
      stepNumber: kOnboardingStepWelcome,
      totalSteps: kOnboardingTotalSteps,
      announcement: '$stepLabel. ${l10n.onboardingAppName}',
      body: Padding(
        padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: HavenLogo()),
            const SizedBox(height: HavenSpacing.xl),
            Text(
              l10n.onboardingAppName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineLarge,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text.rich(
              TextSpan(children: _welcomeHeadlineSpans(l10n)),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
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
        child: Text(l10n.onboardingWelcomeCta),
      ),
    );
  }
}

/// Splits the welcome headline into spans so that its emphasised word
/// (`onboardingWelcomeHeadlineEmphasis`) renders in bold while the rest
/// inherits the surrounding style.
///
/// Falls back to the whole sentence as a single span if the emphasis word is
/// somehow absent, so the copy is never dropped.
List<TextSpan> _welcomeHeadlineSpans(AppLocalizations l10n) {
  final full = l10n.onboardingWelcomeHeadline;
  final word = l10n.onboardingWelcomeHeadlineEmphasis;
  final start = full.indexOf(word);
  if (start < 0) return [TextSpan(text: full)];
  return [
    TextSpan(text: full.substring(0, start)),
    TextSpan(text: word, style: const TextStyle(fontWeight: FontWeight.bold)),
    TextSpan(text: full.substring(start + word.length)),
  ];
}
