/// Identity creation screen (after the intro).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/onboarding/import_nsec_screen.dart';
import 'package:haven/src/pages/onboarding/onboarding_scaffold.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Screen that generates the user's Nostr identity.
///
/// The primary action calls [IdentityNotifier.createIdentity] and then
/// fire-and-forgets [keyPackagePublisherProvider] exactly like the previous
/// Settings flow. The onboarding step advances automatically once the
/// derived `identity_ready` flag flips via [identityProvider].
///
/// A secondary link navigates to [ImportNsecScreen] for users bringing an
/// existing key from another Haven-compatible client.
class CreateIdentityScreen extends ConsumerStatefulWidget {
  /// Creates an identity-creation screen.
  const CreateIdentityScreen({super.key});

  @override
  ConsumerState<CreateIdentityScreen> createState() =>
      _CreateIdentityScreenState();
}

class _CreateIdentityScreenState extends ConsumerState<CreateIdentityScreen> {
  Future<void> _createIdentity() async {
    final notifier = ref.read(identityNotifierProvider.notifier);
    await notifier.createIdentity();
    if (!mounted) return;

    final state = ref.read(identityNotifierProvider);
    if (state.hasError) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.onboardingCreateIdentityError),
          backgroundColor: HavenSecurityColors.danger,
        ),
      );
      return;
    }

    // Fire-and-forget key-package publication. Mirrors identity_page.dart
    // so that the relay gains the user's key package as early as possible.
    // Network failures are non-fatal and do not block onboarding advance.
    ref
      ..invalidate(keyPackagePublisherProvider)
      ..read(keyPackagePublisherProvider);
  }

  void _goToImport() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ImportNsecScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final identityAsync = ref.watch(identityNotifierProvider);
    final isLoading = identityAsync.isLoading;

    return OnboardingScaffold(
      stepNumber: kOnboardingStepCreateIdentity,
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
                LucideIcons.fingerprintPattern,
                size: 48,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: HavenSpacing.xl),
          Text(
            l10n.onboardingCreateIdentityTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.base),
          Text(
            l10n.onboardingCreateIdentityBody,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: HavenSpacing.lg),
          _WarningCard(message: l10n.onboardingCreateIdentityWarning),
        ],
      ),
      secondaryAction: TextButton(
        onPressed: isLoading ? null : _goToImport,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${l10n.onboardingCreateIdentityImportPrompt} ',
              ),
              TextSpan(
                text: l10n.onboardingCreateIdentityImportLink,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          textAlign: TextAlign.center,
        ),
      ),
      primaryAction: FilledButton(
        key: WidgetKeys.createIdentityCta,
        onPressed: isLoading ? null : _createIdentity,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: isLoading
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  Text(l10n.onboardingCreateIdentityLoading),
                ],
              )
            : Text(l10n.onboardingCreateIdentityCta),
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(HavenSpacing.base),
      decoration: BoxDecoration(
        color: HavenSecurityColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(HavenSpacing.sm),
        border: Border.all(
          color: HavenSecurityColors.warning.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            LucideIcons.triangleAlert,
            color: HavenSecurityColors.warning,
          ),
          const SizedBox(width: HavenSpacing.sm),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
