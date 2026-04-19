/// Top-level routing gate: onboarding vs main shell.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/pages/onboarding/onboarding_shell.dart';
import 'package:haven/src/providers/onboarding_provider.dart';

/// Renders the [OnboardingShell] or the [MapShell] depending on whether
/// the user has completed first-run onboarding.
///
/// The underlying [onboardingControllerProvider] is hydrated from
/// `SharedPreferences` before `runApp` in `main.dart`, so the first frame
/// routes correctly without loading-state flicker.
class AppRouter extends ConsumerWidget {
  /// Creates an app router.
  const AppRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completed = ref.watch(onboardingCompletedProvider);
    // AnimatedSwitcher prevents a jarring swap when the user taps
    // "Enter Haven" on the ready screen.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: completed
          ? const MapShell(key: ValueKey('map_shell'))
          : const OnboardingShell(key: ValueKey('onboarding_shell')),
    );
  }
}
