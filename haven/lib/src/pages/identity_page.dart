/// Identity management page for Haven.
///
/// Day-to-day controls only:
/// - Display name with persistent inline save state
/// - QR code for sharing the public key
/// - Entry point to the [IdentityAdvancedPage] (raw keys, secret export)
/// - Identity deletion
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/identity_advanced_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page for managing the user's identity.
class IdentityPage extends ConsumerStatefulWidget {
  /// Creates the identity page.
  const IdentityPage({super.key});

  @override
  ConsumerState<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends ConsumerState<IdentityPage> {
  /// Deletes the identity after confirmation.
  Future<void> _deleteIdentity() async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Identity?'),
        content: const Text(
          'This will permanently delete your identity. '
          'Make sure you have backed up your secret key if you want to '
          'recover it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(identityNotifierProvider.notifier).deleteIdentity();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Identity deleted'),
            backgroundColor: HavenSecurityColors.warning,
          ),
        );
      }
    } on IdentityServiceException catch (_) {
      debugPrint('[Identity] Deletion failed');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to delete identity. Please try again.'),
            backgroundColor: HavenSecurityColors.danger,
          ),
        );
      }
    }
  }

  /// Returns the appropriate QR size based on screen width.
  NpubQrSize _qrSizeForScreen(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 360) return NpubQrSize.medium;
    return NpubQrSize.large;
  }

  @override
  Widget build(BuildContext context) {
    final identityAsync = ref.watch(identityNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Manage Identity')),
      body: identityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) {
          debugPrint('[Identity] Provider error');
          return SingleChildScrollView(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildErrorCard(
                  'Something went wrong loading your identity. '
                  'Please try again.',
                ),
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
                _buildIdentityView(identity),
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
            Text('No Identity', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'Your identity is gone. Set up a new one to keep using Haven.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
            FilledButton.icon(
              onPressed: _restartOnboarding,
              icon: const Icon(LucideIcons.arrowRight),
              label: const Text('Set Up Identity'),
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
  Widget _buildIdentityView(Identity identity) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DisplayNameCard(),

        const SizedBox(height: HavenSpacing.base),

        // QR code card for sharing
        Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              children: [
                Text(
                  'Share Your Identity',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  'Others can scan this code to add you to a circle',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: HavenSpacing.base),
                NpubQrCode(
                  npub: identity.npub,
                  size: _qrSizeForScreen(context),
                  showLabel: false,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.base),

        // Advanced entry: raw keys + secret-key export live behind one tap.
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(LucideIcons.key),
            title: const Text('Advanced'),
            subtitle: const Text('Public key, secret key'),
            trailing: const Icon(LucideIcons.chevronRight),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const IdentityAdvancedPage(),
              ),
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.lg),

        // Delete button
        OutlinedButton.icon(
          onPressed: _deleteIdentity,
          icon: const Icon(LucideIcons.trash2),
          label: const Text('Delete Identity'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }
}
