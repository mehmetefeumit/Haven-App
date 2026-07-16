/// Identity management page for Haven.
///
/// Day-to-day controls only:
/// - Profile photo (view / edit / remove) and an end-to-end-encryption note
/// - Display name with persistent inline save state
/// - QR code subpage for sharing the public key
/// - Photo-sharing subpage (send / receive avatars, data saver)
/// - Entry point to the [IdentityAdvancedPage] (raw keys, secret export)
/// - Identity deletion (behind Advanced)
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/pages/identity_advanced_page.dart';
import 'package:haven/src/pages/settings/qr_code_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/directional_arrow.dart';
import 'package:haven/src/widgets/common/disclosure_chevron.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page for managing the user's identity.
class IdentityPage extends ConsumerStatefulWidget {
  /// Creates the identity page.
  const IdentityPage({super.key});

  @override
  ConsumerState<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends ConsumerState<IdentityPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final identityAsync = ref.watch(identityNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.identityTitle),
        actions: [
          if (publicProfilesEnabled)
            IconButton(
              key: WidgetKeys.identityRefreshButton,
              icon: const Icon(LucideIcons.refreshCw),
              tooltip: l10n.identityRefreshProfileTooltip,
              onPressed: () =>
                  ref.read(ownProfileControllerProvider.notifier).refresh(),
            ),
        ],
      ),
      body: identityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) {
          debugPrint('[Identity] Provider error');
          return SingleChildScrollView(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildErrorCard(l10n.identityLoadError),
                _buildMissingIdentityView(),
              ],
            ),
          );
        },
        data: (identity) => SingleChildScrollView(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (identity == null)
                _buildMissingIdentityView()
              else
                _buildIdentityView(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Text(
          message,
          style: TextStyle(color: colorScheme.onErrorContainer),
        ),
      ),
    );
  }

  /// Builds the recovery view shown when no identity exists.
  ///
  /// Identity creation has moved to the first-run onboarding flow, so this
  /// state is only reachable if the user explicitly deleted their identity
  /// from this page or their keychain was wiped externally. Tapping the
  /// button resets the onboarding flags so the next route decision falls
  /// back into the onboarding shell.
  Widget _buildMissingIdentityView() {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.lg),
        child: Column(
          children: [
            Icon(
              LucideIcons.user,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              l10n.identityMissingTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              l10n.identityMissingMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
            FilledButton.icon(
              onPressed: _restartOnboarding,
              icon: const ForwardArrow(),
              label: Text(l10n.identitySetUpCta),
            ),
          ],
        ),
      ),
    );
  }

  /// Clears the onboarding flags so `AppRouter` drops the user back into
  /// the onboarding shell.
  Future<void> _restartOnboarding() async {
    await ref.read(onboardingControllerProvider.notifier).reset();
    if (mounted) {
      // Pop out of Settings so AppRouter's rebuild takes over.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Builds the view when an identity exists.
  Widget _buildIdentityView() {
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IdentityPhotoHeader(),

        const SizedBox(height: HavenSpacing.base),

        // Publishing a name/photo is public-by-default and unconditional
        // (owner-directed 2026-07-16) — this is the single, standing
        // disclosure of that fact, placed next to both editable fields below.
        const PublicProfileNotice(),

        const SizedBox(height: HavenSpacing.base),

        const DisplayNameCard(),

        const SizedBox(height: HavenSpacing.base),

        // Public-key QR subpage: QR + npub text + copy.
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(LucideIcons.qrCode),
            title: Text(l10n.identityPublicKeyQrTitle),
            subtitle: Text(l10n.identityPublicKeyQrSubtitle),
            trailing: const DisclosureChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const QrCodePage()),
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.base),

        // Advanced entry: raw keys, secret-key export, and identity
        // deletion all live behind one tap.
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(LucideIcons.key),
            title: Text(l10n.identityAdvancedTitle),
            subtitle: Text(l10n.identityAdvancedSubtitle),
            trailing: const DisclosureChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const IdentityAdvancedPage(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
