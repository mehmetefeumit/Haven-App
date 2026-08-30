/// QR code subpage under "Identity".
///
/// Shows the user's public key as a scannable QR code and as selectable text,
/// with a copy affordance (provided by [NpubQrCode]). Exposes only the npub —
/// never the hex key or any secret material.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context);
    final identityAsync = ref.watch(identityProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identityPublicKeyQrTitle)),
      body: identityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) {
          debugPrint('[Identity] QR: provider error');
          return _buildMessage(context, l10n.qrCodeLoadError);
        },
        data: (identity) {
          if (identity == null) {
            return _buildMessage(context, l10n.identityAdvancedMissingBody);
          }
          return _buildQr(context, identity);
        },
      ),
    );
  }

  Widget _buildQr(BuildContext context, Identity identity) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(HavenSpacing.base),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: NpubQrCode(
              npub: identity.npub,
              size: _qrSizeForScreen(context),
              showLabel: false,
            ),
          ),
          const SizedBox(height: HavenSpacing.lg),
          Text(
            l10n.qrCodeYourPublicKeyLabel,
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
          const SizedBox(height: HavenSpacing.lg),
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
                    Text(
                      l10n.qrCodeWhatIsThisTitle,
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(l10n.qrCodeExplainerKeys, style: bodyStyle),
                const SizedBox(height: HavenSpacing.sm),
                Text(l10n.qrCodeExplainerUsername, style: bodyStyle),
              ],
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
