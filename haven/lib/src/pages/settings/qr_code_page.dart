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
      appBar: AppBar(title: const Text('QR code')),
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
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(HavenSpacing.base),
      child: Column(
        children: [
          Text(
            'Others can scan this code to add you to a circle',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          NpubQrCode(
            npub: identity.npub,
            size: _qrSizeForScreen(context),
            showLabel: false,
          ),
          const SizedBox(height: HavenSpacing.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Your public key',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
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
