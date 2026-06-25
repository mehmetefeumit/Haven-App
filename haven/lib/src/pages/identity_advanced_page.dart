/// Advanced sub-page of "Identity".
///
/// Surfaces the cryptographic primitives behind the user's identity:
/// - Public key (npub + hex)
/// - Secret key export
///
/// Kept off the main identity page so day-to-day users aren't confronted
/// with raw key material and one-tap copy buttons. Anything that can leak
/// or destroy the identity belongs here.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page exposing public-key and secret-key controls for an existing identity.
class IdentityAdvancedPage extends ConsumerStatefulWidget {
  /// Creates the advanced identity page.
  const IdentityAdvancedPage({super.key});

  @override
  ConsumerState<IdentityAdvancedPage> createState() =>
      _IdentityAdvancedPageState();
}

class _IdentityAdvancedPageState extends ConsumerState<IdentityAdvancedPage> {
  String? _nsec;
  bool _showNsec = false;

  @override
  void dispose() {
    // Drop the nsec reference promptly. Dart has no zeroize, but we
    // minimize the window during which it is reachable in memory.
    _nsec = null;
    super.dispose();
  }

  /// Exports the secret key for display.
  Future<void> _exportNsec() async {
    final l10n = AppLocalizations.of(context);
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
          SnackBar(
            content: Text(l10n.identityAdvancedExportError),
            backgroundColor: HavenSecurityColors.danger,
          ),
        );
      }
    }
  }

  /// Deletes the identity after confirmation.
  ///
  /// On success the page is popped so the user lands back on the main
  /// identity page, which then renders the "Set Up Identity" recovery view.
  Future<void> _deleteIdentity() async {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.identityAdvancedDeleteTitle),
        content: Text(l10n.identityAdvancedDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
            child: Text(l10n.identityAdvancedDeleteConfirm),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(identityNotifierProvider.notifier).deleteIdentity();
      if (!mounted) return;
      // Drop the nsec reference immediately if it was revealed; the page
      // is about to unmount, but be explicit so any synchronous rebuild
      // between now and the pop does not still render it.
      setState(() {
        _nsec = null;
        _showNsec = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.identityAdvancedDeletedSnack),
          backgroundColor: HavenSecurityColors.warning,
        ),
      );
      // Return to the main identity page; it will surface the recovery
      // view because the provider has already flipped to null.
      Navigator.of(context).pop();
    } on IdentityServiceException catch (_) {
      debugPrint('[Identity] Deletion failed');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.identityAdvancedDeleteError),
          backgroundColor: HavenSecurityColors.danger,
        ),
      );
    }
  }

  /// Copies arbitrary text to clipboard with a confirmation snackbar.
  Future<void> _copyToClipboard(String text, String label) async {
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.identityAdvancedCopiedToClipboard(label)),
        ),
      );
    }
  }

  /// Copies the secret key to clipboard with an explicit security warning.
  Future<void> _copyNsecToClipboard() async {
    if (_nsec == null) return;
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: _nsec!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.identityAdvancedSecretCopiedWarning),
          backgroundColor: HavenSecurityColors.warning,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final identityAsync = ref.watch(identityNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identityAdvancedTitle)),
      body: identityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) {
          debugPrint('[Identity] Advanced: provider error');
          return _buildErrorBody();
        },
        data: (identity) {
          if (identity == null) return _buildMissingIdentityBody();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPublicKeyCard(identity),
                const SizedBox(height: HavenSpacing.base),
                _buildSecretKeyCard(),
                const SizedBox(height: HavenSpacing.lg),
                OutlinedButton.icon(
                  onPressed: _deleteIdentity,
                  icon: const Icon(LucideIcons.trash2),
                  label: Text(l10n.identityAdvancedDeleteIdentityCta),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildErrorBody() {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(HavenSpacing.base),
      child: Card(
        color: colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Text(
            l10n.identityLoadError,
            style: TextStyle(color: colorScheme.onErrorContainer),
          ),
        ),
      ),
    );
  }

  Widget _buildMissingIdentityBody() {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Text(
          l10n.identityAdvancedMissingBody,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildPublicKeyCard(Identity identity) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.identityAdvancedPublicKeyLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            _buildKeyContainer(
              value: identity.npub,
              onCopy: () => _copyToClipboard(
                identity.npub,
                l10n.identityAdvancedCopyValue,
              ),
              tooltip: l10n.identityAdvancedCopyPublicKeyTooltip,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              l10n.identityAdvancedPublicKeyHexLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            _buildKeyContainer(
              value: identity.pubkeyHex,
              onCopy: () => _copyToClipboard(
                identity.pubkeyHex,
                l10n.identityAdvancedCopyValue,
              ),
              tooltip: l10n.identityAdvancedCopyHexTooltip,
              useSmallFont: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSecretKeyCard() {
    final l10n = AppLocalizations.of(context);
    return Card(
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
                  l10n.identityAdvancedSecretKeyTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              l10n.identityAdvancedSecretKeyWarning,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: HavenSpacing.md),
            if (!_showNsec)
              OutlinedButton.icon(
                onPressed: _exportNsec,
                icon: const Icon(LucideIcons.eye),
                label: Text(l10n.identityAdvancedRevealSecretKey),
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
                      color: HavenSecurityColors.warning.withValues(alpha: 0.1),
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
                          tooltip: l10n.identityAdvancedCopySecretKeyTooltip,
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
                    child: Text(l10n.identityAdvancedHideSecretKey),
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
