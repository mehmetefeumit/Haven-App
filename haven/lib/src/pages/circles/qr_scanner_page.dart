/// QR code scanner page for reading a person's public key (npub).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/qr_scanner_channel.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// QR code scanner for reading a person's public key (npub).
///
/// Returns the scanned npub via [Navigator.pop].
class QrScannerPage extends ConsumerStatefulWidget {
  /// Creates a [QrScannerPage].
  const QrScannerPage({super.key});

  @override
  ConsumerState<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends ConsumerState<QrScannerPage>
    with WidgetsBindingObserver {
  final QrScannerChannel _scanner = QrScannerChannel();

  /// Null until the first answer about camera access arrives.
  QrCameraAccess? _access;
  bool _torchOn = false;
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanner.listen(
      onDetected: _onDetected,
      onTorch: (on) {
        if (mounted) setState(() => _torchOn = on);
      },
      onUnavailable: () => _setAccess(QrCameraAccess.unavailable),
    );
    unawaited(_scanner.requestAccess().then(_setAccess));
  }

  void _setAccess(QrCameraAccess access) {
    if (mounted) setState(() => _access = access);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Settings with the camera allowed, or from whatever held the
    // camera: scan without a second tap.
    if (state == AppLifecycleState.resumed &&
        (_access == QrCameraAccess.denied ||
            _access == QrCameraAccess.unavailable)) {
      unawaited(_scanner.checkAccess().then(_setAccess));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scanning = _access == QrCameraAccess.granted;
    // Scan frame and instruction scrim use absolute white/black overlays
    // rather than theme tokens so they remain legible on any camera feed
    // (light or dark scenes, day or night).
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.qrScannerTitle),
        actions: [
          if (scanning) ...[
            IconButton(
              icon: Icon(_torchOn ? LucideIcons.zap : LucideIcons.zapOff),
              onPressed: () => _scanner.setTorch(on: !_torchOn),
              tooltip: l10n.qrScannerToggleFlash,
            ),
            IconButton(
              icon: const Icon(LucideIcons.switchCamera),
              onPressed: _scanner.switchCamera,
              tooltip: l10n.qrScannerSwitchCamera,
            ),
          ],
        ],
      ),
      body: switch (_access) {
        null => const ColoredBox(color: Colors.black, child: SizedBox.expand()),
        QrCameraAccess.granted => _scannerBody(context, l10n),
        QrCameraAccess.denied => _Unavailable(
          message: l10n.qrScannerCameraDenied,
          actionLabel: l10n.commonOpenSettings,
          onAction: () =>
              ref.read(locationSettingsLauncherProvider).openAppSettings(),
        ),
        QrCameraAccess.unavailable => _Unavailable(
          message: l10n.qrScannerCameraUnavailable,
        ),
      },
    );
  }

  Widget _scannerBody(BuildContext context, AppLocalizations l10n) {
    return Stack(
      children: [
        // Camera view
        Positioned.fill(child: _cameraView()),

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
        const Center(
          child: SizedBox(
            width: 250,
            height: 250,
            child: CustomPaint(painter: _CornerPainter(color: Colors.white)),
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
    );
  }

  Widget _cameraView() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidView(
        viewType: QrScannerChannel.viewType,
        creationParams: _scanner.creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.iOS => UiKitView(
        viewType: QrScannerChannel.viewType,
        creationParams: _scanner.creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      _ => const ColoredBox(color: Colors.black),
    };
  }

  void _onDetected(String value) {
    if (_hasScanned || !mounted) return;
    final npub = NpubValidator.extract(value);
    if (npub == null) return;
    _hasScanned = true;
    Navigator.pop(context, npub);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanner.stopListening();
    // Release the camera with the page, not whenever the view is collected.
    unawaited(_scanner.stop());
    super.dispose();
  }
}

/// What the page shows in place of the camera when it cannot scan.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final label = actionLabel;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ExcludeSemantics(
              child: Icon(LucideIcons.cameraOff, size: 48),
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (label != null) ...[
              const SizedBox(height: HavenSpacing.base),
              FilledButton(onPressed: onAction, child: Text(label)),
            ],
          ],
        ),
      ),
    );
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
