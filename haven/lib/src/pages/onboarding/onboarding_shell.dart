/// Dispatcher that renders the correct onboarding screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/intro_screen.dart';
import 'package:haven/src/providers/onboarding_provider.dart';

/// Renders the onboarding screen matching the current [OnboardingStep].
///
/// Both steps are root-level replacements driven by the derived
/// [onboardingStepProvider], so killing and relaunching the app always lands
/// the user on the correct screen without intermediate state.
class OnboardingShell extends ConsumerWidget {
  /// Creates an onboarding shell.
  const OnboardingShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(onboardingStepProvider);

    // AppRouter listens to the completed flag, but watch here too as a
    // defence-in-depth — covers the rare frame where the flag flips but
    // AppRouter hasn't rebuilt yet.
    if (step == OnboardingStep.done) {
      return const SizedBox.shrink();
    }

    return switch (step) {
      OnboardingStep.intro => const IntroScreen(),
      OnboardingStep.createIdentity => const CreateIdentityScreen(),
      OnboardingStep.done => const SizedBox.shrink(),
    };
  }
}
