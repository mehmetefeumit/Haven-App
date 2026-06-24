/// Full-screen viewer for the user's own profile photo.
///
/// Renders avatar bytes via [Image.memory] only (never a network URL) so no
/// avatar data is leaked to relays or CDNs, and writes nothing to disk.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A full-screen, pinch-zoomable view of an avatar image.
///
/// Dismissed via the close button, system back, or a tap while not zoomed in.
/// Bytes are held in memory only for the lifetime of the route.
class AvatarFullscreenViewer extends StatefulWidget {
  /// Creates a full-screen avatar viewer for [imageBytes].
  const AvatarFullscreenViewer({required this.imageBytes, super.key});

  /// Raw JPEG/PNG/WebP bytes of the avatar to display.
  final Uint8List imageBytes;

  @override
  State<AvatarFullscreenViewer> createState() => _AvatarFullscreenViewerState();
}

class _AvatarFullscreenViewerState extends State<AvatarFullscreenViewer> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Dismisses only when not zoomed in, so a tap after a pinch-zoom does not
  /// fight [InteractiveViewer] panning.
  void _handleTap() {
    if (_transform.value.getMaxScaleOnAxis() <= 1.01) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(LucideIcons.x),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: GestureDetector(
          onTap: _handleTap,
          child: Center(
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: 1,
              maxScale: 4,
              child: Semantics(
                label: 'Profile photo, full screen',
                image: true,
                child: Image.memory(
                  widget.imageBytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      _buildDecodeError(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDecodeError(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.broken_image_outlined,
          color: Colors.white70,
          size: 48,
        ),
        const SizedBox(height: HavenSpacing.md),
        Text(
          "Couldn't load photo",
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }
}

/// Opens [AvatarFullscreenViewer] for [imageBytes] as a full-screen route.
Future<void> showAvatarFullscreen(BuildContext context, Uint8List imageBytes) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => AvatarFullscreenViewer(imageBytes: imageBytes),
    ),
  );
}
