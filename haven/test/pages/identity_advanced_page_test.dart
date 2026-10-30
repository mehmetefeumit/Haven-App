/// Deleting the identity from the advanced page: the revealed secret leaves
/// the screen before the delete is awaited (Rule 9), and while it runs the
/// control says so, a screen reader is told, and nothing can start it twice
/// or leave the page mid-delete.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/identity_advanced_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';

import '../helpers/accessibility_announcements.dart';
import '../helpers/localized_app_harness.dart';
import '../helpers/log_capture.dart';

const _nsec =
    'nsec1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jqemf7n';

final _identity = Identity(
  pubkeyHex: 'aa' * 32,
  npub: 'npub1self',
  createdAt: DateTime(2024),
);

/// An identity whose delete parks on [deleting] until the test completes it.
class _ParkedIdentity extends IdentityNotifier {
  final deleting = Completer<void>();
  int deletes = 0;

  @override
  Future<Identity?> build() async => _identity;

  @override
  Future<String> exportNsec() async => _nsec;

  @override
  Future<void> deleteIdentity() async {
    deletes++;
    await deleting.future;
  }
}

Future<(_ParkedIdentity, AppLocalizations)> _openAndConfirmDelete(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final identity = _ParkedIdentity();
  await pumpLocalized(
    tester,
    const Scaffold(body: Text('below')),
    overrides: [identityNotifierProvider.overrideWith(() => identity)],
  );
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const IdentityAdvancedPage()),
    ),
  );
  await tester.pumpAndSettle();
  final l10n = AppLocalizations.of(
    tester.element(find.byType(IdentityAdvancedPage)),
  );

  await tester.tap(find.text(l10n.identityAdvancedRevealSecretKey));
  await tester.pumpAndSettle();
  expect(find.textContaining(_nsec), findsOneWidget, reason: 'premise');

  await tester.ensureVisible(find.byKey(WidgetKeys.identityDeleteCta));
  await tester.tap(find.byKey(WidgetKeys.identityDeleteCta));
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.identityAdvancedDeleteConfirm));
  await tester.pump();
  return (identity, l10n);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the secret is gone before the delete completes, and the '
      'control says what is running', (tester) async {
    final said = captureAccessibilityAnnouncements(tester);
    final (identity, l10n) = await _openAndConfirmDelete(tester);

    expect(identity.deletes, 1);
    expect(
      find.textContaining(_nsec),
      findsNothing,
      reason: 'the secret must not stay on screen for the seconds a delete '
          'takes (Rule 9)',
    );
    final button = find.byKey(WidgetKeys.identityDeleteCta);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(
      find.descendant(
        of: button,
        matching: find.text(l10n.identityAdvancedDeletingProgress),
      ),
      findsOneWidget,
    );
    expect(said, contains(l10n.identityAdvancedDeletingProgress));

    identity.deleting.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('back is refused mid-delete', (tester) async {
    final (identity, _) = await _openAndConfirmDelete(tester);

    // The app bar's back button.
    await tester.pageBack();
    // Past any route transition (the spinner never settles): a frame to
    // start the transition's ticker, one to finish it, one to remove it.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(IdentityAdvancedPage), findsOneWidget);

    identity.deleting.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a delete that fails with any error gives the control and the '
      'way back, and logs only its type', (tester) async {
    final capture = LogCapture.install();
    final (identity, _) = await _openAndConfirmDelete(tester);
    identity.deleting.completeError(
      StateError('nsec1planted at wss://planted.example'),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(WidgetKeys.identityDeleteCta);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    capture
      ..restore()
      ..assertContains('[Identity] Deletion failed: StateError')
      ..assertNoNeedles(['nsec1planted', 'wss://planted.example']);
  });

  testWidgets('a delete that fails gives the control back', (tester) async {
    final (identity, l10n) = await _openAndConfirmDelete(tester);
    identity.deleting.completeError(
      const IdentityServiceException('failed'),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(WidgetKeys.identityDeleteCta);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    expect(find.text(l10n.identityAdvancedDeleteError), findsOneWidget);
  });
}
