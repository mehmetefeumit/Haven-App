/// Merged intro screen — the first of two onboarding steps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// First onboarding screen: the hero (logo + tagline) merged with the three
/// "what makes Haven different" value props on a single page.
///
/// Tapping "Get Started" flips the `intro_seen` flag via
/// [OnboardingController.markIntroSeen]; the onboarding shell then advances to
/// the create-identity step automatically.
///
/// Non-scrolling by design (owner requirement): the layout is intentionally
/// compact so the whole page fits within the viewport on common phones without
/// scrolling. [OnboardingScaffold] still hosts the body in a scroll view as an
/// overflow safety valve for very small legacy devices — it should not scroll
/// in practice.
class IntroScreen extends ConsumerStatefulWidget {
  /// Creates an intro screen.
  const IntroScreen({super.key});

  @override
  ConsumerState<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends ConsumerState<IntroScreen> {
  bool _advancing = false;

  Future<void> _onContinue() async {
    if (_advancing) return;
    setState(() => _advancing = true);
    // Flipping the flag rebuilds the shell into the create-identity step; this
    // screen is then disposed, so `_advancing` never needs resetting.
    await ref.read(onboardingControllerProvider.notifier).markIntroSeen();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stepLabel = l10n.onboardingStepOf(
      kOnboardingStepIntro,
      kOnboardingTotalSteps,
    );

    return OnboardingScaffold(
      stepNumber: kOnboardingStepIntro,
      totalSteps: kOnboardingTotalSteps,
      announcement: '$stepLabel. ${l10n.onboardingAppName}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: HavenLogo(size: 64)),
          const SizedBox(height: HavenSpacing.md),
          Text(
            l10n.onboardingAppName,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: HavenSpacing.xs),
          Text.rich(
            TextSpan(children: _welcomeHeadlineSpans(l10n)),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Text(
            l10n.onboardingValuePropsTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: HavenSpacing.md),
          _ValuePropCard(
            icon: LucideIcons.lock,
            title: l10n.onboardingValueProp1Title,
            body: l10n.onboardingValueProp1Summary,
          ),
          const SizedBox(height: HavenSpacing.sm),
          _ValuePropCard(
            icon: LucideIcons.network,
            title: l10n.onboardingValueProp2Title,
            body: l10n.onboardingValueProp2Summary,
          ),
          const SizedBox(height: HavenSpacing.sm),
          _ValuePropCard(
            icon: LucideIcons.userX,
            title: l10n.onboardingValueProp3Title,
            body: l10n.onboardingValueProp3Summary,
          ),
        ],
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.introCta,
        onPressed: _advancing ? null : _onContinue,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: _advancing
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: l10n.onboardingCreateIdentityLoading,
                ),
              )
            : Text(l10n.onboardingWelcomeCta),
      ),
    );
  }
}

/// Splits the welcome headline into spans so its emphasised word
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

/// A compact value-prop card: leading icon tile, title, and body.
///
/// Exposes its title and body as a single [Semantics] block so a screen reader
/// announces them together, in reading order.
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
      // Announce title + body as one block, excluding the child Text nodes so a
      // screen reader doesn't read each card three times (mirrors the pattern
      // in PublicProfileNotice).
      label: '$title. $body',
      container: true,
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(HavenSpacing.sm),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(HavenSpacing.sm),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: HavenSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: HavenSpacing.xs),
                    Text(
                      body,
                      style: theme.textTheme.bodySmall?.copyWith(
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
