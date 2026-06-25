/// Tests for the InvitationsFloatingButton widget.
///
/// Verifies:
/// - Icon toggling (outlined vs filled) based on invitation count
/// - Badge visibility and count
/// - Tooltip text
/// - Navigation to InvitationsPage
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/providers/invitation_count_provider.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/common/invitations_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// No-op Settle Pill notifier so the navigated-to InvitationsPage's initState
/// refresh never touches the real identity/relay stack here.
class _NoopPollStatus extends InvitationPollStatusNotifier {
  @override
  InvitationPollStatus build() => InvitationPollStatus.idle;

  @override
  Future<void> refresh() async {}
}

Widget _buildApp({required int invitationCount}) {
  return ProviderScope(
    overrides: [
      invitationCountProvider.overrideWithValue(invitationCount),
      // Override pendingInvitationsProvider to prevent actual service calls
      // in the InvitationsPage that gets navigated to.
      pendingInvitationsProvider.overrideWith((ref) async => <Invitation>[]),
      invitationPollStatusProvider.overrideWith(_NoopPollStatus.new),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: false,
        splashFactory: InkSplash.splashFactory,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: InvitationsFloatingButton()),
    ),
  );
}

void main() {
  group('InvitationsFloatingButton', () {
    testWidgets('shows mail-open icon when no invitations', (tester) async {
      await tester.pumpWidget(_buildApp(invitationCount: 0));

      expect(find.byIcon(LucideIcons.mailOpen), findsOneWidget);
      expect(find.byIcon(LucideIcons.mail), findsNothing);
    });

    testWidgets('shows closed mail icon when invitations exist', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(invitationCount: 3));

      expect(find.byIcon(LucideIcons.mail), findsOneWidget);
      expect(find.byIcon(LucideIcons.mailOpen), findsNothing);
    });

    testWidgets('badge is hidden when count is 0', (tester) async {
      await tester.pumpWidget(_buildApp(invitationCount: 0));

      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, isFalse);
    });

    testWidgets('badge shows count when invitations exist', (tester) async {
      await tester.pumpWidget(_buildApp(invitationCount: 5));

      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, isTrue);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('tooltip shows generic text when no invitations', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(invitationCount: 0));

      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, 'Invitations');
    });

    testWidgets('tooltip shows count for single invitation', (tester) async {
      await tester.pumpWidget(_buildApp(invitationCount: 1));

      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, '1 pending invitation');
    });

    testWidgets('tooltip shows plural count for multiple invitations', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(invitationCount: 3));

      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.tooltip, '3 pending invitations');
    });

    testWidgets('navigates to InvitationsPage on tap', (tester) async {
      await tester.pumpWidget(_buildApp(invitationCount: 0));

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.byType(InvitationsPage), findsOneWidget);
    });
  });
}
