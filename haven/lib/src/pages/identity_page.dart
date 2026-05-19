/// Identity management page for Haven.
///
/// This page allows users to:
/// - Generate a new identity
/// - View their public key
/// - Export their secret key for backup
/// - Delete their identity (with confirmation)
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
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
  String? _nsec;
  bool _showNsec = false;
  final _displayNameController = TextEditingController();
  bool _displayNameLoaded = false;

  @override
  void dispose() {
    _nsec = null;
    _displayNameController.dispose();
    super.dispose();
  }

  /// Exports the secret key for display.
  Future<void> _exportNsec() async {
    try {
      final nsec = await ref
          .read(identityNotifierProvider.notifier)
          .exportNsec();
      if (mounted) {
        setState(() {
          _nsec = nsec;
          _showNsec = true;
        });
      }
    } on IdentityServiceException catch (_) {
      debugPrint('[Identity] Export failed');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to export secret key. Please try again.'),
            backgroundColor: HavenSecurityColors.danger,
          ),
        );
      }
    }
  }

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
        setState(() {
          _nsec = null;
          _showNsec = false;
        });

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

  /// Saves the display name.
  Future<void> _saveDisplayName() async {
    final service = ref.read(identityServiceProvider);
    final text = _displayNameController.text.trim();
    try {
      await service.setDisplayName(text.isEmpty ? null : text);
      ref.invalidate(displayNameProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Display name saved'),
            backgroundColor: HavenSecurityColors.encrypted,
          ),
        );
      }
    } on IdentityServiceException catch (_) {
      debugPrint('[Identity] Display name save failed');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save display name. Please try again.'),
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

  /// Copies text to clipboard.
  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
    }
  }

  /// Copies secret key to clipboard with a security warning.
  Future<void> _copyNsecToClipboard() async {
    if (_nsec == null) return;
    await Clipboard.setData(ClipboardData(text: _nsec!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Secret key copied. Warning: other apps may read your '
            'clipboard. Paste it somewhere safe and clear your clipboard.',
          ),
          backgroundColor: HavenSecurityColors.warning,
          duration: Duration(seconds: 5),
        ),
      );
    }
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
        // Display name card
        _buildDisplayNameCard(),

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

        // Public keys card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Public Key',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: HavenSpacing.sm),
                _buildKeyContainer(
                  value: identity.npub,
                  onCopy: () => _copyToClipboard(identity.npub, 'Public key'),
                  tooltip: 'Copy public key',
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  'Public Key (hex)',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: HavenSpacing.sm),
                _buildKeyContainer(
                  value: identity.pubkeyHex,
                  onCopy: () =>
                      _copyToClipboard(identity.pubkeyHex, 'Public key'),
                  tooltip: 'Copy hex',
                  useSmallFont: true,
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  'Created: ${identity.createdAt.toLocal()}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: HavenSpacing.base),

        // Secret key card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      LucideIcons.triangleAlert,
                      color: HavenSecurityColors.warning,
                    ),
                    const SizedBox(width: HavenSpacing.sm),
                    Text(
                      'Secret Key',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  'Your secret key gives full access to your identity. '
                  'Never share it with anyone.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: HavenSpacing.md),
                if (!_showNsec)
                  OutlinedButton.icon(
                    onPressed: _exportNsec,
                    icon: const Icon(LucideIcons.eye),
                    label: const Text('Reveal Secret Key'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HavenSecurityColors.warning,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(HavenSpacing.md),
                        decoration: BoxDecoration(
                          color: HavenSecurityColors.warning.withValues(
                            alpha: 0.1,
                          ),
                          borderRadius: BorderRadius.circular(HavenSpacing.sm),
                          border: Border.all(
                            color: HavenSecurityColors.warning.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(_nsec!, style: HavenTypography.mono),
                            ),
                            IconButton(
                              icon: const Icon(LucideIcons.copy, size: 20),
                              onPressed: _copyNsecToClipboard,
                              tooltip: 'Copy secret key',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: HavenSpacing.sm),
                      TextButton(
                        onPressed: () => setState(() {
                          _showNsec = false;
                          _nsec = null;
                        }),
                        child: const Text('Hide Secret Key'),
                      ),
                    ],
                  ),
              ],
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

  Widget _buildDisplayNameCard() {
    final colorScheme = Theme.of(context).colorScheme;
    final displayNameAsync = ref.watch(displayNameProvider);

    // Initialize the text controller from the provider value (once).
    if (!_displayNameLoaded) {
      displayNameAsync.whenData((name) {
        _displayNameController.text = name ?? '';
        _displayNameLoaded = true;
      });
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Display Name', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'This name is only visible to people in your circles.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _displayNameController,
                    decoration: const InputDecoration(
                      hintText: 'Enter your display name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLength: 64,
                  ),
                ),
                const SizedBox(width: HavenSpacing.sm),
                FilledButton(
                  onPressed: _saveDisplayName,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyContainer({
    required String value,
    required VoidCallback onCopy,
    required String tooltip,
    bool useSmallFont = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(HavenSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(HavenSpacing.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              value,
              style: useSmallFont
                  ? HavenTypography.monoSmall
                  : HavenTypography.mono,
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.copy, size: 20),
            onPressed: onCopy,
            tooltip: tooltip,
          ),
        ],
      ),
    );
  }
}
