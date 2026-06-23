import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/image_cache_guard.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  test('install bounds the image cache to the privacy cap', () {
    final guard = HavenImageCacheGuard()..install();
    addTearDown(() => binding.removeObserver(guard));

    expect(
      PaintingBinding.instance.imageCache.maximumSizeBytes,
      kHavenImageCacheMaxBytes,
    );
  });

  test('evicts decoded images when the app is backgrounded', () async {
    final image = await createTestImage(width: 4, height: 4);
    final cache = PaintingBinding.instance.imageCache
      ..putIfAbsent(
        'avatar-test-key',
        () => OneFrameImageStreamCompleter(
          SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
        ),
      );
    expect(cache.currentSize, greaterThan(0),
        reason: 'precondition: the test image is cached');

    final guard = HavenImageCacheGuard()..install();
    addTearDown(() => binding.removeObserver(guard));

    guard.didChangeAppLifecycleState(AppLifecycleState.paused);

    expect(cache.currentSize, 0,
        reason: 'backgrounding must evict decoded images');
    expect(cache.currentSizeBytes, 0);
  });

  test('inactive and hidden also evict', () {
    final guard = HavenImageCacheGuard()..install();
    addTearDown(() => binding.removeObserver(guard));
    // Should not throw and should leave the cache empty.
    guard.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(PaintingBinding.instance.imageCache.currentSize, 0);
    guard.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(PaintingBinding.instance.imageCache.currentSize, 0);
  });

  test('resumed does not evict', () async {
    final image = await createTestImage(width: 4, height: 4);
    final cache = PaintingBinding.instance.imageCache
      ..putIfAbsent(
        'keep-on-resume',
        () => OneFrameImageStreamCompleter(
          SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
        ),
      );
    final guard = HavenImageCacheGuard()..install();
    addTearDown(() => binding.removeObserver(guard));

    guard.didChangeAppLifecycleState(AppLifecycleState.resumed);

    expect(cache.currentSize, greaterThan(0),
        reason: 'resuming must not clear the cache');
  });
}
