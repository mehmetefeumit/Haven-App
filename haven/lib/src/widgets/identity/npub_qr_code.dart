/// QR code display widget for Nostr public keys.
///
/// Renders an npub as a scannable QR code using the `nostr:` URI format
/// (NIP-21), compatible with Haven's QR scanner and other Nostr clients.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Size variants for the QR code display.
enum NpubQrSize {
  /// Small QR code (150x150) for inline display.
  small(150),

  /// Medium QR code (200x200) for standard use.
  medium(200),

  /// Large QR code (280x280) for prominent display and easy scanning.
  large(280);

  const NpubQrSize(this.dimension);

  /// The width and height in logical pixels.
  final double dimension;
}

/// Displays an npub as a scannable QR code.
///
/// The QR code encodes the npub in `nostr:npub1...` URI format,
/// which is the standard Nostr URI scheme (NIP-21). This format is
/// already handled by [NpubValidator.extract] on the scanning side.
///
/// When [enableCopy] is true (the default), the user can copy the plain
/// `npub1...` public key to the clipboard two ways: pressing and holding the
/// QR code, or tapping the "Copy public key" button beneath it. The button
/// is the accessible primary affordance (single tap, 48dp target, focusable);
/// the long-press is a convenience shortcut. This lets users share their key
/// over text or chat when scanning in person isn't possible. The npub is
/// public information, so copying it carries no secret-leakage risk (unlike
/// the secret key, which lives behind an explicit warning elsewhere).
///
/// The QR rendering area maintains a white background with dark modules
/// regardless of the app theme, ensuring reliable scanning in all
/// conditions. The outer container adapts to the current theme.
class NpubQrCode extends StatelessWidget {
  /// Creates an npub QR code widget.
  ///
  /// The [npub] must be a valid bech32-encoded Nostr public key
  /// starting with `npub1`.
  const NpubQrCode({
    required this.npub,
    super.key,
    this.size = NpubQrSize.medium,
    this.showLabel = true,
    this.enableCopy = true,
  });

  /// The npub to encode as a QR code.
  final String npub;

  /// The display size of the QR code.
  final NpubQrSize size;

  /// Whether to show a "Scan to add me" label below the QR code.
  final bool showLabel;

  /// Whether the npub can be copied to the clipboard.
  ///
  /// When true, a "Copy public key" button is shown beneath the code and both
  /// tapping it and long-pressing the QR copy the plain `npub1...` string with
  /// a confirmation.
  final bool enableCopy;

  /// The data encoded in the QR code.
  ///
  /// Uses the `nostr:` URI prefix per NIP-21 for the Nostr URI scheme.
  String get qrData => 'nostr:$npub';

  /// Copies the plain npub to the clipboard with haptic and visual feedback.
  ///
  /// Copies [npub] (not the `nostr:` URI) so the recipient receives a clean,
  /// portable public key. The npub is public, so no clipboard warning is
  /// shown — contrast with secret-key copying, which warns explicitly.
  Future<void> _copyNpub(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await HapticFeedback.mediumImpact();
    await Clipboard.setData(ClipboardData(text: npub));
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Public key copied to clipboard'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget qrContainer = Container(
      padding: const EdgeInsets.all(HavenSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(HavenSpacing.md),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: QrImageView(
        data: qrData,
        version: QrVersions.auto,
        size: size.dimension,
        backgroundColor: Colors.white,
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
      ),
    );

    if (enableCopy) {
      // Long-press is a sighted-user touch shortcut. Its semantics are
      // excluded because the "Copy public key" button below is the
      // first-class affordance for assistive tech — exposing both would make
      // a screen reader announce the same action twice.
      qrContainer = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _copyNpub(context),
        excludeFromSemantics: true,
        child: qrContainer,
      );
    }

    return Semantics(
      label: 'QR code for your public identity',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          qrContainer,
          if (enableCopy) ...[
            const SizedBox(height: HavenSpacing.xs),
            TextButton.icon(
              onPressed: () => _copyNpub(context),
              icon: const Icon(LucideIcons.copy, size: 16),
              label: const Text('Copy public key'),
              style: TextButton.styleFrom(
                // Guarantee a ≥48dp touch target for accessibility.
                minimumSize: const Size(0, 48),
              ),
            ),
          ],
          if (showLabel) ...[
            const SizedBox(height: HavenSpacing.sm),
            Text(
              'Scan to add me',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
