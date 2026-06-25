/// Widget tests for the add-relay bottom sheet ([showAddRelaySheet]).
///
/// Verifies the localized title (per category), the technical hint, the paste
/// tooltip, the Cancel/Add action labels, and that each validator error code
/// maps to its exact localized message. Pumped under [pumpLocalized] so the
/// localization delegates are registered.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/add_relay_sheet.dart';
import 'package:haven/src/services/relay_preferences_service.dart';

import '../../helpers/localized_app_harness.dart';

/// A trivial host that opens the add-relay sheet for [category], so the sheet
/// has a route/context to attach to.
class _Host extends StatelessWidget {
  const _Host({required this.category});

  final RelayCategory category;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAddRelaySheet(context, category: category),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }
}

/// Opens the sheet for [category] and settles.
Future<AppLocalizations> _openSheet(
  WidgetTester tester,
  RelayCategory category,
) async {
  await pumpLocalized(tester, _Host(category: category));
  final l10n = l10nOf(tester, _Host);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return l10n;
}

/// Simulates a clipboard paste of [text] and triggers the sheet's paste action,
/// which validates immediately (bypassing the typing debounce).
Future<void> _pasteAndValidate(WidgetTester tester, String text) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': text};
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}

void main() {
  group('showAddRelaySheet', () {
    testWidgets('shows the Inbox title', (tester) async {
      final l10n = await _openSheet(tester, RelayCategory.inbox);
      expect(find.text(l10n.addRelaySheetTitleInbox), findsOneWidget);
      expect(l10n.addRelaySheetTitleInbox, 'Add Inbox relay');
    });

    testWidgets('shows the KeyPackage title', (tester) async {
      final l10n = await _openSheet(tester, RelayCategory.keyPackage);
      expect(find.text(l10n.addRelaySheetTitleKeyPackage), findsOneWidget);
      expect(l10n.addRelaySheetTitleKeyPackage, 'Add KeyPackage relay');
    });

    testWidgets('shows the technical hint, paste tooltip, and actions', (
      tester,
    ) async {
      final l10n = await _openSheet(tester, RelayCategory.inbox);
      expect(find.text(l10n.addRelaySheetHint), findsOneWidget);
      expect(l10n.addRelaySheetHint, 'wss://relay.example.com');
      expect(
        find.byTooltip(l10n.addRelaySheetPasteTooltip),
        findsOneWidget,
      );
      expect(l10n.addRelaySheetPasteTooltip, 'Paste from clipboard');
      expect(find.text(l10n.commonCancel), findsOneWidget);
      expect(l10n.commonCancel, 'Cancel');
      expect(find.text(l10n.commonAdd), findsOneWidget);
      expect(l10n.commonAdd, 'Add');
    });

    testWidgets('maps the insecure-scheme error to its localized message', (
      tester,
    ) async {
      final l10n = await _openSheet(tester, RelayCategory.inbox);
      await _pasteAndValidate(tester, 'ws://insecure.example.com');
      await tester.tap(find.byTooltip(l10n.addRelaySheetPasteTooltip));
      await tester.pumpAndSettle();
      expect(find.text(l10n.addRelaySheetErrorInsecureScheme), findsOneWidget);
      expect(
        l10n.addRelaySheetErrorInsecureScheme,
        'Use wss:// so traffic to this relay is encrypted.',
      );
    });

    testWidgets('maps the credentials error to its localized message', (
      tester,
    ) async {
      final l10n = await _openSheet(tester, RelayCategory.inbox);
      await _pasteAndValidate(tester, 'wss://user:pass@relay.example.com');
      await tester.tap(find.byTooltip(l10n.addRelaySheetPasteTooltip));
      await tester.pumpAndSettle();
      expect(find.text(l10n.addRelaySheetErrorHasCredentials), findsOneWidget);
      expect(
        l10n.addRelaySheetErrorHasCredentials,
        'Relay URL must not contain credentials.',
      );
    });

    testWidgets('maps the invalid-format error to its localized message', (
      tester,
    ) async {
      final l10n = await _openSheet(tester, RelayCategory.inbox);
      await _pasteAndValidate(tester, 'wss://relay');
      await tester.tap(find.byTooltip(l10n.addRelaySheetPasteTooltip));
      await tester.pumpAndSettle();
      expect(find.text(l10n.addRelaySheetErrorInvalidFormat), findsOneWidget);
      expect(
        l10n.addRelaySheetErrorInvalidFormat,
        'Enter a relay address like wss://relay.example.com.',
      );
    });
  });
}
