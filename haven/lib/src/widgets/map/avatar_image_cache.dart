/// Bounded in-memory cache for decoded `dart:ui.Image` objects used by
/// circle-member map markers.
///
/// **Why a dedicated cache?**
/// [CustomPainter.paint] is synchronous, so `ui.Image` objects must be decoded
/// ahead of time and held in state.  Flutter's [ImageCache] holds
/// [ImageStreamCompleter]s, not bare `ui.Image` values, so it cannot serve
/// this purpose directly.  A small, explicit LRU map is simpler and cheaper.
///
/// **Bounds:** at most [maxEntries] images are kept.  The least-recently-used
/// entry is evicted (and its `ui.Image` disposed) when the cache is full.
///
/// **Privacy eviction:** [clear] disposes every cached image and empties the
/// map.  [HavenImageCacheGuard] calls [clear] on every
/// [AppLifecycleState.paused] / [inactive] / [hidden] transition, so decoded
/// GPU pixels do not linger while Haven is in the background.
///
/// **No disk cache.**  Images are held only in RAM for the lifetime of the
/// app foreground session.
library;

import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Singleton bounded LRU cache for decoded avatar [ui.Image]s.
///
/// Keyed by the avatar content-hash string (from
/// [MemberLocation.avatarContentHash]), so the same avatar is decoded at most
/// once per foreground session regardless of how many markers repaint.
class AvatarImageCache extends ChangeNotifier {
  AvatarImageCache._();

  static final AvatarImageCache instance = AvatarImageCache._();

  /// Maximum number of decoded images held simultaneously.
  ///
  /// Each decoded marker thumbnail is roughly 96×96 RGBA = ~37 KiB; 20
  /// entries ≈ 750 KiB — comfortably within the 8 MiB privacy cap.
  static const int maxEntries = 20;

  // LinkedHashMap preserves insertion order; we treat it as LRU by removing
  // and re-inserting on access (move-to-back).
  final LinkedHashMap<String, ui.Image> _cache =
      LinkedHashMap<String, ui.Image>();

  /// Returns the cached [ui.Image] for [contentHash], or `null` on a miss.
  ///
  /// A hit moves the entry to the back (most-recently-used position).
  ui.Image? get(String contentHash) {
    final image = _cache.remove(contentHash);
    if (image == null) return null;
    _cache[contentHash] = image; // move-to-back
    return image;
  }

  /// Stores [image] under [contentHash].
  ///
  /// If the cache already holds [maxEntries] images, the least-recently-used
  /// entry is evicted and disposed before the new image is inserted.
  ///
  /// If [contentHash] is already in the cache the old image is disposed and
  /// replaced (handles re-decode after a content change).
  void put(String contentHash, ui.Image image) {
    var disposedExisting = false;
    if (_cache.containsKey(contentHash)) {
      _cache.remove(contentHash)!.dispose();
      disposedExisting = true;
    }
    while (_cache.length >= maxEntries) {
      // The first key in a LinkedHashMap is the least-recently-used entry.
      final lruKey = _cache.keys.first;
      _cache.remove(lruKey)!.dispose();
      disposedExisting = true;
    }
    _cache[contentHash] = image;
    // Notify ONLY when an image was disposed (replace or LRU eviction) so a
    // loader still referencing that now-disposed image rebuilds and drops it.
    // A plain insert needs no broadcast (the decoding loader rebuilds itself),
    // so common decode completions don't cause a rebuild storm.
    if (disposedExisting) notifyListeners();
  }

  /// Disposes all cached images and empties the cache.
  ///
  /// Called by [HavenImageCacheGuard] on every background-lifecycle
  /// transition so decoded avatar pixels are not retained while Haven is
  /// not in the foreground.
  void clear() {
    if (_cache.isEmpty) return;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    // Broadcast so every loader rebuilds and stops referencing a disposed
    // image — defeats use-after-dispose on the next paint after a background
    // eviction (the loader re-reads this cache, the single source of truth).
    notifyListeners();
    debugPrint('[AvatarImageCache] cleared (background eviction)');
  }

  /// Number of images currently held in the cache.
  ///
  /// Exposed for testing.
  @visibleForTesting
  int get length => _cache.length;
}
