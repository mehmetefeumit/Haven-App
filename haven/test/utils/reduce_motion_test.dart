/// Tests for the shared reduce-motion read (Android flag OR iOS flag).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/reduce_motion.dart';

void main() {
  Future<bool> read(WidgetTester tester, {MediaQueryData? media}) async {
    late bool result;
    final probe = Builder(
      builder: (context) {
        result = reduceMotionOf(context);
        return const SizedBox.shrink();
      },
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: media == null ? probe : MediaQuery(data: media, child: probe),
      ),
    );
    return result;
  }

  void setEngineReduceMotion(WidgetTester tester, {required bool on}) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(reduceMotion: on);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  testWidgets('both flags off is false', (tester) async {
    expect(await read(tester, media: const MediaQueryData()), isFalse);
  });

  testWidgets('MediaQuery disableAnimations alone is true', (tester) async {
    expect(
      await read(tester, media: const MediaQueryData(disableAnimations: true)),
      isTrue,
    );
  });

  testWidgets('the engine reduceMotion flag alone is true', (tester) async {
    setEngineReduceMotion(tester, on: true);
    expect(await read(tester, media: const MediaQueryData()), isTrue);
  });

  testWidgets('without a MediaQuery it falls back to the engine flag', (
    tester,
  ) async {
    expect(await read(tester), isFalse);
    setEngineReduceMotion(tester, on: true);
    expect(await read(tester), isTrue);
  });

  testWidgets('a rebuild re-reads the engine flag', (tester) async {
    setEngineReduceMotion(tester, on: false);
    expect(await read(tester, media: const MediaQueryData()), isFalse);
    setEngineReduceMotion(tester, on: true);
    expect(await read(tester, media: const MediaQueryData()), isTrue);
  });
}
