/// QR code scanner page for reading member IDs.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// QR code scanner for reading member IDs.
///
/// Scans QR codes and extracts member ID values.
/// Returns the scanned ID via [Navigator.pop].
class QrScannerPage extends StatefulWidget {
  /// Creates a [QrScannerPage].
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Scan frame and instruction scrim use absolute white/black overlays
    // rather than theme tokens so they remain legible on any camera feed
    // (light or dark scenes, day or night).
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.qrScannerTitle),
        actions: [
          // Torch toggle
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, state, child) {
                return Icon(
                  state.torchState == TorchState.on
                      ? LucideIcons.zap
                      : LucideIcons.zapOff,
                );
              },
            ),
            onPressed: () => _controller.toggleTorch(),
            tooltip: l10n.qrScannerToggleFlash,
          ),
          // Camera switch
          IconButton(
            icon: const Icon(LucideIcons.switchCamera),
            onPressed: () => _controller.switchCamera(),
            tooltip: l10n.qrScannerSwitchCamera,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera view
          MobileScanner(controller: _controller, onDetect: _onDetect),

          // Scan frame overlay
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          // Corner decorations
          Center(
            child: SizedBox(
              width: 250,
              height: 250,
              child: CustomPaint(
                painter: const _CornerPainter(color: Colors.white),
              ),
            ),
          ),

          // Instructions
          Positioned(
            bottom: HavenSpacing.xxl,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HavenSpacing.base,
                    vertical: HavenSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    // Camera-UI scrim — black87 keeps white text legible in
                    // bright outdoor scenes where black54 falls below 4.5:1.
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(HavenSpacing.sm),
                  ),
                  child: Text(
                    l10n.qrScannerInstruction,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(height: HavenSpacing.sm),
                Text(
                  l10n.qrScannerScanning,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      // Try to extract npub from the scanned value
      final npub = NpubValidator.extract(value);
      if (npub != null) {
        _hasScanned = true;

        // Provide haptic feedback
        // HapticFeedback.mediumImpact(); // Uncomment if desired

        // Return the npub
        Navigator.pop(context, npub);
        return;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Paints corner decorations for the scan frame.
class _CornerPainter extends CustomPainter {
  const _CornerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cornerLength = 30.0;
    const radius = 16.0;

    // Top-left corner
    canvas.drawPath(
      Path()
        ..moveTo(cornerLength, 0)
        ..lineTo(radius, 0)
        ..arcToPoint(
          const Offset(0, radius),
          radius: const Radius.circular(radius),
        )
        ..lineTo(0, cornerLength),
      paint,
    );

    // Top-right corner
    canvas.drawPath(
      Path()
        ..moveTo(size.width - cornerLength, 0)
        ..lineTo(size.width - radius, 0)
        ..arcToPoint(
          Offset(size.width, radius),
          radius: const Radius.circular(radius),
          clockwise: true,
        )
        ..lineTo(size.width, cornerLength),
      paint,
    );

    // Bottom-left corner
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height - cornerLength)
        ..lineTo(0, size.height - radius)
        ..arcToPoint(
          Offset(radius, size.height),
          radius: const Radius.circular(radius),
        )
        ..lineTo(cornerLength, size.height),
      paint,
    );

    // Bottom-right corner
    canvas.drawPath(
      Path()
        ..moveTo(size.width, size.height - cornerLength)
        ..lineTo(size.width, size.height - radius)
        ..arcToPoint(
          Offset(size.width - radius, size.height),
          radius: const Radius.circular(radius),
          clockwise: true,
        )
        ..lineTo(size.width - cornerLength, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CornerPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
