/// Widget tests for the [DisplayNameCard].
///
/// Covers the persistent inline edit/save state machine: initial saved,
/// dirty-on-typing, whitespace-only edits, success transitions including
/// the intermediate Saving state, failure surfacing, and the
/// initial-load race where the user types before the async provider
/// resolves.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  Widget buildHarness({
    required IdentityService service,
    AsyncValue<String?>? displayNameOverride,
  }) {
    return ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(service),
        if (displayNameOverride != null)
          displayNameProvider.overrideWith(
            // Always-pending future so the override controls the AsyncValue.
            (ref) => switch (displayNameOverride) {
              AsyncData(:final value) => Future<String?>.value(value),
              AsyncError(:final error, :final stackTrace) =>
                Future<String?>.error(error, stackTrace),
              _ => Completer<String?>().future,
            },
          ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Padding(padding: EdgeInsets.all(16), child: DisplayNameCard()),
        ),
      ),
    );
  }

  group('DisplayNameCard', () {
    testWidgets('initial saved state when display name is loaded', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsNothing);
      expect(
        _findSaveButton().onPressed,
        isNull,
        reason: 'Save button must be disabled with no edits',
      );
      // The saved state is encoded by a check icon on the circular button.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.check),
        ),
        findsOneWidget,
        reason: 'saved state shows a check icon',
      );
    });

    testWidgets('typing flips status to Unsaved changes and enables Save', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Alice!');
      await tester.pump();

      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      expect(_findSaveButton().onPressed, isNotNull);
    });

    testWidgets('whitespace-only edit does not mark dirty', (tester) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  Alice  ');
      await tester.pump();

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsNothing);
      expect(_findSaveButton().onPressed, isNull);
    });

    testWidgets('save success: Saving -> Saved, no SnackBar', (tester) async {
      final completer = Completer<void>();
      final service = _FakeIdentityService(
        initialDisplayName: 'Alice',
        setDisplayNameGate: completer.future,
      );

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.pump();
      expect(find.text('Unsaved changes'), findsOneWidget);

      await tester.tap(_findSaveButtonFinder());
      await tester.pump();

      expect(
        find.text('Saving…'),
        findsOneWidget,
        reason: 'Intermediate Saving state must be visible',
      );
      expect(
        _findSaveButton().onPressed,
        isNull,
        reason: 'Save button disabled while saving',
      );
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      completer.complete();
      await tester.pumpAndSettle();

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Saving…'), findsNothing);
      expect(
        _findSaveButton().onPressed,
        isNull,
        reason: 'After save the button is disabled (no longer dirty)',
      );
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'No SnackBar on success — inline indicator carries it',
      );
      expect(service.setDisplayNameCalls, ['Bob']);
    });

    testWidgets('save failure flips status to failed and re-enables Save', (
      tester,
    ) async {
      final service = _FakeIdentityService(
        initialDisplayName: 'Alice',
        throwOnSet: true,
      );

      await tester.pumpWidget(buildHarness(service: service));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Bob');
      await tester.pump();

      await tester.tap(_findSaveButtonFinder());
      await tester.pumpAndSettle();

      expect(find.text('Save failed, try again'), findsOneWidget);
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'Failure is inline, not a SnackBar',
      );
      expect(
        _findSaveButton().onPressed,
        isNotNull,
        reason: 'User must be able to retry',
      );
      // The failed state is encoded by a retry icon on the circular button.
      expect(
        find.descendant(
          of: _findSaveButtonFinder(),
          matching: find.byIcon(LucideIcons.rotateCcw),
        ),
        findsOneWidget,
        reason: 'failed state shows a retry icon',
      );
    });

    testWidgets('loading provider: field disabled, typing cannot mark dirty', (
      tester,
    ) async {
      final service = _FakeIdentityService(initialDisplayName: 'Alice');

      await tester.pumpWidget(
        buildHarness(
          service: service,
          displayNameOverride: const AsyncLoading<String?>(),
        ),
      );
      // Do NOT pumpAndSettle — keep the provider in loading state.
      await tester.pump();

      // Loading skeleton, not the loaded body.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      expect(find.text('Unsaved changes'), findsNothing);
    });
  });
}

ButtonStyleButton _findSaveButton() {
  return _findSaveButtonFinder().evaluate().single.widget as ButtonStyleButton;
}

Finder _findSaveButtonFinder() =>
    find.byKey(WidgetKeys.displayNameSaveButton);

class _FakeIdentityService implements IdentityService {
  _FakeIdentityService({
    this.initialDisplayName,
    this.throwOnSet = false,
    this.setDisplayNameGate,
  });

  final String? initialDisplayName;
  final bool throwOnSet;
  final Future<void>? setDisplayNameGate;
  final List<String?> setDisplayNameCalls = [];

  String? _current;

  @override
  Future<String?> getDisplayName() async => _current ?? initialDisplayName;

  @override
  Future<void> setDisplayName(String? name) async {
    if (setDisplayNameGate != null) {
      await setDisplayNameGate;
    }
    if (throwOnSet) {
      throw const IdentityServiceException('boom');
    }
    setDisplayNameCalls.add(name);
    _current = name;
  }

  @override
  Future<Identity?> getIdentity() async => null;

  @override
  Future<bool> hasIdentity() async => false;

  @override
  Future<Identity> createIdentity() async => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String> exportNsec() async => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) async =>
      throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => throw UnimplementedError();

  @override
  Future<List<int>> getSecretBytes() async => throw UnimplementedError();

  @override
  Future<void> clearCache() async {}
}
