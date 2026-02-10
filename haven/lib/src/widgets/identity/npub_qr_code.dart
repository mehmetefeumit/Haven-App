/// QR code display widget for Nostr public keys.
///
/// Renders an npub as a scannable QR code using the `nostr:` URI format
/// (NIP-21), compatible with Haven's QR scanner and other Nostr clients.
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:haven/src/theme/theme.dart';

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
  });

  /// The npub to encode as a QR code.
  final String npub;

  /// The display size of the QR code.
  final NpubQrSize size;

  /// Whether to show a "Scan to add me" label below the QR code.
  final bool showLabel;

  /// The data encoded in the QR code.
  ///
  /// Uses the `nostr:` URI prefix per NIP-21 for the Nostr URI scheme.
  String get qrData => 'nostr:$npub';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'QR code for $npub',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(HavenSpacing.md),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(HavenSpacing.md),
              border: Border.all(
                color: colorScheme.outlineVariant,
              ),
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
          ),
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
