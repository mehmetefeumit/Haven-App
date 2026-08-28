/// Tests for the InvitationsPage.
///
/// Verifies:
/// - AppBar title and refresh button
/// - Loading state
/// - Empty state display
/// - Invitation list rendering
/// - Opening the page issues no profile relay fetch for the inviters
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';
import 'package:haven/src/widgets/common/empty_state.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';

/// Completer used by the loading test so the future never completes
/// without leaving a pending Timer.
Completer<List<Invitation>>? _loadingCompleter;

/// Settle-pill notifier that does nothing, so the page's initState refresh
/// never touches the real identity/relay stack in these list-focused tests.
class _NoopPollStatus extends InvitationPollStatusNotifier {
  @override
  InvitationPollStatus build() => InvitationPollStatus.idle;

  @override
  Future<void> refresh() async {}
}

Widget _buildApp({
  required AsyncValue<List<Invitation>> invitationsState,
  MockProfileService? profileService,
}) {
  return ProviderScope(
    overrides: [
      pendingInvitationsProvider.overrideWith((ref) {
        return invitationsState.when(
          data: Future.value,
          loading: () {
            _loadingCompleter = Completer<List<Invitation>>();
            return _loadingCompleter!.future;
          },
          error: (e, s) => Future<List<Invitation>>.error(e, s),
        );
      }),
      // Stub the Settle Pill so the page's refresh has no side effects.
      invitationPollStatusProvider.overrideWith(_NoopPollStatus.new),
      // The cards read the inviter's name out of the profile cache, which
      // must stay off the real FFI stack in a widget test.
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      // ...and the local petname out of the contact table, same reason.
      circleServiceProvider.overrideWithValue(MockCircleService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: false,
        splashFactory: InkSplash.splashFactory,
      ),
      home: const InvitationsPage(),
    ),
  );
}

Invitation _createInvitation({String circleName = 'Test'}) {
  return Invitation(
    mlsGroupId: [1, 2, 3, 4],
    circleName: circleName,
    inviterPubkey:
        'abc123def456abc123def456abc123def456abc123def456abc123def456abcd',
    inviterNpub:
        'npub140qj8hh5264uzg7773t2hsfrmm69d27py000g44tcy3aaazk40xskwpam3',
    invitedAt: DateTime.now(),
  );
}

void main() {
  group('InvitationsPage', () {
    testWidgets('shows AppBar with correct title', (tester) async {
      await tester.pumpWidget(
        _buildApp(invitationsState: const AsyncValue.data([])),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, InvitationsPage);
      expect(l10n.commonInvitations, 'Invitations');
      expect(find.text(l10n.commonInvitations), findsOneWidget);
    });

    testWidgets('shows the refresh ring in the AppBar', (tester) async {
      await tester.pumpWidget(
        _buildApp(invitationsState: const AsyncValue.data([])),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, InvitationsPage);
      expect(l10n.invitationsRefreshTooltip, 'Refresh invitations');
      // The segmented ring replaces the old IconButton; idle, it shows the
      // refresh icon under the same tooltip and test key.
      expect(find.byType(RefreshRingButton), findsOneWidget);
      expect(find.byKey(WidgetKeys.invitationsRefresh), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      expect(find.byTooltip(l10n.invitationsRefreshTooltip), findsOneWidget);
    });

    testWidgets('shows loading indicator while loading', (tester) async {
      await tester.pumpWidget(
        _buildApp(invitationsState: const AsyncValue.loading()),
      );
      // Don't settle — loading state is intentionally indefinite
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Complete the future so no pending timers remain.
      _loadingCompleter?.complete([]);
      await tester.pumpAndSettle();
    });

    testWidgets('shows empty state when no invitations', (tester) async {
      await tester.pumpWidget(
        _buildApp(invitationsState: const AsyncValue.data([])),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, InvitationsPage);
      expect(l10n.invitationsEmptyTitle, 'No Invitations');
      expect(
        l10n.invitationsEmptyMessage,
        'When someone invites you to a circle, it will appear here.',
      );
      expect(find.byType(HavenEmptyState), findsOneWidget);
      expect(find.text(l10n.invitationsEmptyTitle), findsOneWidget);
      expect(find.text(l10n.invitationsEmptyMessage), findsOneWidget);
    });

    testWidgets('shows one card per invitation, none of them named', (
      tester,
    ) async {
      final invitations = [
        _createInvitation(circleName: 'Family'),
        _createInvitation(circleName: 'Work'),
      ];

      await tester.pumpWidget(
        _buildApp(invitationsState: AsyncValue.data(invitations)),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, InvitationsPage);
      expect(find.byType(InvitationCard), findsNWidgets(2));
      // Every card is headed the same, because pre-join Haven knows nothing
      // that distinguishes one circle from another: the name lives inside
      // the encrypted Welcome. A card that showed one would be showing the
      // stand-in.
      expect(find.text(l10n.invitationCardHeading), findsNWidgets(2));
      expect(find.text('Family'), findsNothing);
      expect(find.text('Work'), findsNothing);
    });

    testWidgets('opening the page fetches no profile for the inviters', (
      tester,
    ) async {
      // An inviter is a stranger until the invitation is accepted. A batch
      // refresh here would put their pubkey in the union, and every pubkey in
      // the union also reaches the picture download — a GET to a host THEY
      // chose, from the user's real IP, for a card that renders no image at
      // all. The name is a local cache read or nothing.
      final profileService = MockProfileService();

      await tester.pumpWidget(
        _buildApp(
          invitationsState: AsyncValue.data([_createInvitation()]),
          profileService: profileService,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        profileService.methodCalls.map((call) => call.method),
        isNot(contains('refreshMemberProfiles')),
      );
    });

    testWidgets('shows error message on error', (tester) async {
      await tester.pumpWidget(
        _buildApp(
          invitationsState: AsyncValue.error(
            Exception('Network error'),
            StackTrace.current,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester, InvitationsPage);
      expect(l10n.invitationsLoadError, 'Could not load invitations');
      expect(find.text(l10n.invitationsLoadError), findsOneWidget);
    });
  });
}
