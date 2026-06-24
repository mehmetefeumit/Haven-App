/// QR code subpage under "Identity".
///
/// Shows the user's public key as a scannable QR code and as selectable text,
/// with a copy affordance (provided by [NpubQrCode]). Exposes only the npub —
/// never the hex key or any secret material.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';

/// Page that displays the user's public key as a QR code for sharing.
class QrCodePage extends ConsumerWidget {
  /// Creates the QR code page.
  const QrCodePage({super.key});

  /// Returns the appropriate QR size based on screen width.
  NpubQrSize _qrSizeForScreen(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 360) return NpubQrSize.medium;
    return NpubQrSize.large;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Public Key QR')),
      body: identityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) {
          debugPrint('[Identity] QR: provider error');
          return _buildMessage(
            context,
            'Something went wrong loading your public key. '
            'Please try again.',
          );
        },
        data: (identity) {
          if (identity == null) {
            return _buildMessage(context, 'No identity is set up.');
          }
          return _buildQr(context, identity);
        },
      ),
    );
  }

  Widget _buildQr(BuildContext context, Identity identity) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(HavenSpacing.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Plain-language explainer — assumes no Nostr familiarity.
          Container(
            padding: const EdgeInsets.all(HavenSpacing.md),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: HavenSpacing.sm),
                    Text('What is this?', style: theme.textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  'Haven runs on Nostr — an open network with no company '
                  'account or sign-up behind it. Your identity is just a pair '
                  'of keys: a secret key only you hold, and this public key '
                  'made from it.',
                  style: bodyStyle,
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  'Your public key works like a username that is safe to '
                  'share. People scan this code — or paste the text below — to '
                  'invite you to a circle. It can’t reveal your name, '
                  'location, or messages.',
                  style: bodyStyle,
                ),
              ],
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Center(
            child: NpubQrCode(
              npub: identity.npub,
              size: _qrSizeForScreen(context),
              showLabel: false,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Text(
            'Your public key',
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HavenSpacing.md),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(HavenSpacing.sm),
            ),
            child: SelectableText(
              identity.npub,
              style: HavenTypography.monoStyle(context).copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context, String message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
