import 'package:flutter/widgets.dart';
import 'package:haven/src/widgets/map/avatar_image_cache.dart';

/// Maximum bytes the global [ImageCache] may hold for decoded images.
///
/// Avatars are small (96 px thumbnails on the hot path), so a tight bound keeps
/// decoded pixels from accumulating in memory. This is a privacy bound, not a
/// performance cache — keep it small.
const int kHavenImageCacheMaxBytes = 8 * 1024 * 1024; // 8 MiB

/// App-lifecycle observer that bounds the global [ImageCache] and evicts it
/// when Haven is backgrounded, so decoded avatar (and other) pixels do not
/// linger in memory while the app is not in the foreground.
///
/// Scope note (do not over-rely): clearing the [ImageCache] frees
/// decoded-but-offscreen images; it does NOT scrub the GPU texture of an image
/// currently on screen — that is what the platform app-switcher protection
/// (Android `FLAG_SECURE` / iOS snapshot blur) and the documented live-memory
/// residual in `SECURITY.md` cover.
class HavenImageCacheGuard with WidgetsBindingObserver {
  bool _installed = false;

  /// Bounds the cache and registers the lifecycle observer. Idempotent.
  void install() {
    if (_installed) return;
    _installed = true;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        kHavenImageCacheMaxBytes;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Unregisters the lifecycle observer.
  ///
  /// Call this when the guard is no longer needed (e.g., in tests or if the
  /// guard is scoped to a sub-tree). In production, [install] is called once
  /// from `main` for the lifetime of the process, so [dispose] is typically
  /// not called. It is provided here so the guard is cleanly testable.
  void dispose() {
    if (!_installed) return;
    WidgetsBinding.instance.removeObserver(this);
    _installed = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      evictNow();
    }
  }

  /// Clears both the pending and live decoded-image caches, and also evicts
  /// the [AvatarImageCache] so decoded marker-avatar GPU pixels are released.
  void evictNow() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    AvatarImageCache.instance.clear();
  }
}
