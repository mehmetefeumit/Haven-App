/// Widget tests for [HavenLogo].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/haven_logo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpLogo(WidgetTester tester, {double size = 120}) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: HavenLogo(size: size)))),
    );
  }

  testWidgets('renders the bundled brand mark with an accessible label', (
    tester,
  ) async {
    await pumpLogo(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, HavenLogo.assetPath);
    expect(image.semanticLabel, 'Haven logo');
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('shows a white circular tile sized to `size`', (tester) async {
    await pumpLogo(tester, size: 80);

    expect(tester.getSize(find.byType(HavenLogo)), const Size(80, 80));

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(HavenLogo),
        matching: find.byType(Container),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(
      decoration.color,
      Colors.white,
      reason: 'the black/red mark must always sit on a white tile to stay '
          'legible on both light and dark surfaces',
    );
    expect(decoration.shape, BoxShape.circle);
  });
}
