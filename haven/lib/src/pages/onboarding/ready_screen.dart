/// Final onboarding screen, gating entry into the main app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/pages/onboarding/onboarding_strings.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Confirmation screen the user reaches once identity and name are done.
///
/// The single CTA calls [OnboardingController.markCompleted], flipping the
/// terminal flag. `AppRouter` watches that flag and immediately swaps in
/// the main shell once it turns true.
class ReadyScreen extends ConsumerStatefulWidget {
  /// Creates a ready screen.
  const ReadyScreen({super.key});

  @override
  ConsumerState<ReadyScreen> createState() => _ReadyScreenState();
}

class _ReadyScreenState extends ConsumerState<ReadyScreen> {
  bool _busy = false;

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Seed default relays BEFORE marking onboarding complete so the
    // first KP / inbox publish has a populated list. The provider's
    // `build()` self-heals on read, but pre-seeding here removes the
    // race window between AppRouter rebuilding and the publisher
    // actually firing.
    try {
      final relayPrefs = await ref.read(relayPreferencesServiceProvider.future);
      await relayPrefs.seedDefaultsIfUnseeded();
    } on Object catch (e) {
      // Non-fatal: provider self-heal will catch up. Don't block
      // onboarding on a transient seeding failure.
      debugPrint('Seed defaults during onboarding failed: ${e.runtimeType}');
    }
    await ref.read(onboardingControllerProvider.notifier).markCompleted();
    // No explicit navigation — AppRouter listens to onboardingCompletedProvider
    // and rebuilds into the main shell.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return OnboardingScaffold(
      stepNumber: 5,
      totalSteps: 5,
      body: Padding(
        padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: HavenSecurityColors.encrypted.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  LucideIcons.check,
                  size: 64,
                  color: HavenSecurityColors.encrypted,
                ),
              ),
            ),
            const SizedBox(height: HavenSpacing.xl),
            Text(
              OnboardingStrings.readyTitle,
              style: theme.textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              OnboardingStrings.readyBody,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.readyCta,
        onPressed: _busy ? null : _finish,
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
            : const Text(OnboardingStrings.readyCta),
      ),
    );
  }
}
