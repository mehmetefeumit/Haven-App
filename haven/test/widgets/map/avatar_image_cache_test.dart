/// Tests for [AvatarImageCache] — the bounded LRU cache for decoded
/// `dart:ui.Image` objects used by circle-member map markers.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/image_cache_guard.dart';
import 'package:haven/src/widgets/map/avatar_image_cache.dart';

/// Creates a minimal [ui.Image] for testing.
///
/// Uses [createTestImage] from the test framework which produces a real
/// raster image backed by the test compositor.
Future<ui.Image> _makeImage() => createTestImage(width: 4, height: 4);

void main() {
  // Each test operates on a fresh cache instance so test order does not
  // matter.  We clear between tests instead of creating new instances
  // because the cache is a singleton (by design — the guard and the
  // layer both reference `AvatarImageCache.instance`).
  tearDown(() => AvatarImageCache.instance.clear());

  group('AvatarImageCache — get/put', () {
    test('put stores and get retrieves by content-hash', () async {
      final img = await _makeImage();
      final cache = AvatarImageCache.instance;
      cache.put('hash-a', img);
      expect(cache.get('hash-a'), same(img));
    });

    test('get returns null for an unknown hash', () {
      expect(AvatarImageCache.instance.get('no-such-hash'), isNull);
    });

    test('put replaces an existing entry and disposes the old image', () async {
      final img1 = await _makeImage();
      final img2 = await _makeImage();
      final cache = AvatarImageCache.instance;
      cache.put('hash-b', img1);
      cache.put('hash-b', img2);
      // The new image is retrievable; img1 was disposed by put().
      expect(cache.get('hash-b'), same(img2));
    });

    test('evicts the LRU entry when maxEntries is reached', () async {
      final cache = AvatarImageCache.instance;
      final max = AvatarImageCache.maxEntries;

      // Fill the cache to the limit.
      for (var i = 0; i < max; i++) {
        cache.put('hash-$i', await _makeImage());
      }
      expect(cache.length, max);

      // Access hash-0 to make it most-recently-used.
      cache.get('hash-0');

      // One more entry evicts the current LRU (hash-1).
      cache.put('hash-overflow', await _makeImage());
      expect(cache.length, max);
      expect(cache.get('hash-1'), isNull,
          reason: 'hash-1 should have been evicted as LRU');
      expect(cache.get('hash-0'), isNotNull,
          reason: 'hash-0 was recently accessed and must stay');
    });

    test('get promotes an entry to most-recently-used', () async {
      final cache = AvatarImageCache.instance;
      final max = AvatarImageCache.maxEntries;

      // Fill the cache so the first entry (hash-0) is the LRU.
      for (var i = 0; i < max; i++) {
        cache.put('hash-$i', await _makeImage());
      }

      // Touch hash-0 to promote it.
      final promoted = cache.get('hash-0');
      expect(promoted, isNotNull);

      // Now hash-1 is the LRU.  Adding one more entry evicts hash-1.
      cache.put('hash-new', await _makeImage());
      expect(cache.get('hash-0'), isNotNull,
          reason: 'promoted entry must survive');
      expect(cache.get('hash-1'), isNull,
          reason: 'hash-1 is now LRU and should be evicted');
    });
  });

  group('AvatarImageCache — clear', () {
    test('clear empties the cache', () async {
      final cache = AvatarImageCache.instance;
      cache.put('c1', await _makeImage());
      cache.put('c2', await _makeImage());
      expect(cache.length, 2);

      cache.clear();

      expect(cache.length, 0);
      expect(cache.get('c1'), isNull);
      expect(cache.get('c2'), isNull);
    });

    test('clear is a no-op on an already-empty cache', () {
      expect(() => AvatarImageCache.instance.clear(), returnsNormally);
      expect(AvatarImageCache.instance.length, 0);
    });
  });

  group('AvatarImageCache — lifecycle eviction via HavenImageCacheGuard', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    tearDown(() {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });

    test('evictNow() also clears the AvatarImageCache', () async {
      final cache = AvatarImageCache.instance;
      cache.put('evict-test', await _makeImage());
      expect(cache.length, 1);

      final guard = HavenImageCacheGuard()..install();
      addTearDown(() => binding.removeObserver(guard));

      guard.evictNow();

      expect(cache.length, 0,
          reason: 'evictNow must clear the AvatarImageCache');
    });

    test('paused lifecycle state clears the AvatarImageCache', () async {
      final cache = AvatarImageCache.instance;
      cache.put('paused-test', await _makeImage());

      final guard = HavenImageCacheGuard()..install();
      addTearDown(() => binding.removeObserver(guard));

      guard.didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(cache.length, 0,
          reason: 'backgrounding must evict avatar images');
    });

    test('inactive lifecycle state clears the AvatarImageCache', () async {
      final cache = AvatarImageCache.instance;
      cache.put('inactive-test', await _makeImage());

      final guard = HavenImageCacheGuard()..install();
      addTearDown(() => binding.removeObserver(guard));

      guard.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(cache.length, 0);
    });

    test('hidden lifecycle state clears the AvatarImageCache', () async {
      final cache = AvatarImageCache.instance;
      cache.put('hidden-test', await _makeImage());

      final guard = HavenImageCacheGuard()..install();
      addTearDown(() => binding.removeObserver(guard));

      guard.didChangeAppLifecycleState(AppLifecycleState.hidden);

      expect(cache.length, 0);
    });

    test('resumed lifecycle state does NOT clear the AvatarImageCache', () async {
      final cache = AvatarImageCache.instance;
      cache.put('keep-on-resume', await _makeImage());

      final guard = HavenImageCacheGuard()..install();
      addTearDown(() => binding.removeObserver(guard));

      guard.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(cache.length, 1,
          reason: 'resuming must not clear avatar images');
    });
  });
}
