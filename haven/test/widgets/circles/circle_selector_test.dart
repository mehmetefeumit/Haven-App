/// Tests for CircleSelector widget.
///
/// Verifies that:
/// - Empty state shows loading then "New" button only
/// - Circles are displayed as chips
/// - Selection state is managed correctly
/// - "New" button navigates to create circle page
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/widgets/circles/circle_selector.dart';

import '../../mocks/mock_circle_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CircleSelector', () {
    testWidgets('shows loading indicator while fetching circles', (
      tester,
    ) async {
      // Use a completer to control when the future completes
      final mockService = MockCircleService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );

      // Initially shows loading
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Wait for the future to complete
      await tester.pumpAndSettle();

      // Loading indicator should be gone
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows only "New" button when no circles exist', (
      tester,
    ) async {
      final mockService = MockCircleService(circles: []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );
      await tester.pumpAndSettle();

      // Should show "New" button
      expect(find.text('New'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);

      // Should not show any circle chips
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('displays circle chips when circles exist', (tester) async {
      final testCircles = [
        TestCircleFactory.createCircle(
          mlsGroupId: [1, 2, 3],
          displayName: 'Family',
        ),
        TestCircleFactory.createCircle(
          mlsGroupId: [4, 5, 6],
          displayName: 'Friends',
        ),
      ];
      final mockService = MockCircleService(circles: testCircles);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );
      await tester.pumpAndSettle();

      // Should show circle names
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);

      // Should show "New" button too
      expect(find.text('New'), findsOneWidget);
    });

    testWidgets('tapping circle chip selects it', (tester) async {
      final testCircle = TestCircleFactory.createCircle(
        mlsGroupId: [1, 2, 3],
        displayName: 'Family',
      );
      final mockService = MockCircleService(circles: [testCircle]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: MaterialApp(
            // Use InkSplash to avoid ink_sparkle.frag shader issue in tests.
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the circle chip
      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      // The chip should now be selected (FilterChip with selected=true)
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isTrue);
    });

    testWidgets('tapping selected circle deselects it', (tester) async {
      final testCircle = TestCircleFactory.createCircle(
        mlsGroupId: [1, 2, 3],
        displayName: 'Family',
      );
      final mockService = MockCircleService(circles: [testCircle]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockService),
            // Pre-select the circle
            selectedCircleProvider.overrideWith((ref) => testCircle),
          ],
          child: MaterialApp(
            // Use InkSplash to avoid ink_sparkle.frag shader issue in tests.
            theme: ThemeData(splashFactory: InkSplash.splashFactory),
            home: const Scaffold(body: CircleSelector()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially selected
      var chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isTrue);

      // Tap to deselect
      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      // Should now be deselected
      chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isFalse);
    });

    testWidgets('shows error state when service fails', (tester) async {
      final mockService = MockCircleService(
        shouldThrowOnGetCircles: true,
        errorMessage: 'Network error',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [circleServiceProvider.overrideWithValue(mockService)],
          child: const MaterialApp(home: Scaffold(body: CircleSelector())),
        ),
      );
      await tester.pumpAndSettle();

      // With graceful degradation, should show empty state (just "New" button)
      // because circlesProvider returns empty list on error
      expect(find.text('New'), findsOneWidget);
    });
  });
}
