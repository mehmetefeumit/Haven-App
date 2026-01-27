import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';

void main() {
  testWidgets('HavenApp renders HomePage', (tester) async {
    await tester.pumpWidget(const HavenApp());

    expect(find.text('Haven'), findsOneWidget);
    expect(find.text('Welcome to Haven'), findsOneWidget);
  });
}
