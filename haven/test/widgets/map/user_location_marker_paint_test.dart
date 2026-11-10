/// What the self-marker costs the map and says to a screen reader.
///
/// The dot is constant ink with nothing animating: `flutter_map` wraps the
/// whole map in one `RepaintBoundary`, so any perpetual animation in here
/// would redraw the tiles and every member marker at the display refresh
/// rate. Its label carries no accuracy figure because none was ever real.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/widgets/map/member_marker.dart' show kMarkerKeyline;
import 'package:haven/src/widgets/map/user_location_marker.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/localized_app_harness.dart';

const Color _core = Color(0xFF0A0A0A);
const Color _white = Color(0xFFFFFFFF);

final Finder _boxes = find.descendant(
  of: find.byType(UserLocationMarker),
  matching: find.byType(DecoratedBox),
);

List<BoxDecoration> _decorations(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(_boxes)
    .map((box) => box.decoration as BoxDecoration)
    .toList();

Future<void> _pump(WidgetTester tester, {ThemeData? theme}) async {
  const marker = Scaffold(body: Center(child: UserLocationMarker()));
  await pumpLocalized(
    tester,
    theme == null ? marker : Theme(data: theme, child: marker),
    settle: false,
  );
  await tester.pump();
}

void main() {
  testWidgets('the label is the fixed phrase with no accuracy claim', (
    tester,
  ) async {
    await _pump(tester);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(UserLocationMarker)),
    );
    final label = tester
        .getSemantics(find.byType(UserLocationMarker))
        .label;

    expect(label, l10n.userLocationMarkerSemantics);
    expect(label, isNot(matches(RegExp(r'\d'))));
    expect(label.toLowerCase(), isNot(contains('accuracy')));
  });

  testWidgets('nothing animates, now or later', (tester) async {
    await _pump(tester);
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pump(const Duration(seconds: 2));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('paints an ink core, a white 3 px ring and a keyline', (
    tester,
  ) async {
    await _pump(tester);

    final decorations = _decorations(tester);
    expect(decorations, hasLength(2));
    final [keyline, ring] = decorations;

    expect(keyline.shape, BoxShape.circle);
    final keylineBorder = keyline.border! as Border;
    expect(keylineBorder.top.color, kMarkerKeyline);
    expect(keylineBorder.top.width, 1);
    expect(keyline.boxShadow, hasLength(1));
    expect(
      keyline.boxShadow!.single.color,
      Colors.black.withValues(alpha: 0.25),
    );
    expect(keyline.boxShadow!.single.blurRadius, 4);
    expect(keyline.boxShadow!.single.offset, const Offset(0, 2));

    expect(ring.shape, BoxShape.circle);
    expect(ring.color, _core);
    final ringBorder = ring.border! as Border;
    expect(ringBorder.top.color, _white);
    expect(ringBorder.top.width, 3);
  });

  testWidgets('the outermost box is 26 dp: an 18 dp core, 3 dp ring, 1 px '
      'keyline', (tester) async {
    await _pump(tester);

    expect(tester.getSize(_boxes.first), const Size.square(26));
    expect(tester.getSize(_boxes.last), const Size.square(24));
    expect(tester.getSize(find.byType(UserLocationMarker)).longestSide,
        lessThanOrEqualTo(26));
  });

  testWidgets('stays 26 dp under the tight constraints a Marker imposes', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 32,
            child: UserLocationMarker(),
          ),
        ),
      ),
      settle: false,
    );
    await tester.pump();

    expect(tester.getSize(_boxes.first), const Size.square(26));
    expect(tester.getSize(_boxes.last), const Size.square(24));
  });

  testWidgets('the ink is identical under a light and a dark theme', (
    tester,
  ) async {
    await _pump(tester, theme: ThemeData.light());
    final light = _decorations(tester);
    await _pump(tester, theme: ThemeData.dark());
    final dark = _decorations(tester);

    expect(dark.length, light.length);
    for (var i = 0; i < light.length; i++) {
      expect(dark[i].color, light[i].color);
      expect(dark[i].border, light[i].border);
      expect(dark[i].boxShadow, light[i].boxShadow);
    }
  });

  testWidgets('sits at its point inside a MarkerLayer', (tester) async {
    await pumpLocalized(
      tester,
      const Scaffold(
        body: FlutterMap(
          options: MapOptions(
            initialCenter: LatLng(10, 20),
            initialZoom: 5,
          ),
          children: [
            MarkerLayer(
              markers: [
                Marker(
                  point: LatLng(10, 20),
                  width: 32,
                  height: 32,
                  child: UserLocationMarker(),
                ),
              ],
            ),
          ],
        ),
      ),
      settle: false,
    );
    await tester.pump();

    expect(tester.getSize(_boxes.first), const Size.square(26));
    final marker = tester.getCenter(find.byType(UserLocationMarker));
    final map = tester.getCenter(find.byType(FlutterMap));
    expect((marker - map).distance, lessThan(0.5));
  });
}
