/// Advanced sub-page of "Manage Identity".
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

  /// Copies arbitrary text to clipboard with a confirmation snackbar.
  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
    }
  }

  /// Copies the secret key to clipboard with an explicit security warning.
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
      appBar: AppBar(title: const Text('Advanced')),
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
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildErrorBody() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(HavenSpacing.base),
      child: Card(
        color: colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Text(
            'Something went wrong loading your identity. '
            'Please try again.',
            style: TextStyle(color: colorScheme.onErrorContainer),
          ),
        ),
      ),
    );
  }

  Widget _buildMissingIdentityBody() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Text(
          'No identity is set up.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildPublicKeyCard(Identity identity) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
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
              onCopy: () => _copyToClipboard(identity.pubkeyHex, 'Public key'),
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
    );
  }

  Widget _buildSecretKeyCard() {
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
