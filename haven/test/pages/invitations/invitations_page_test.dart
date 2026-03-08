/// Tests for the InvitationsPage.
///
/// Verifies:
/// - AppBar title and refresh button
/// - Loading state
/// - Empty state display
/// - Invitation list rendering
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';
import 'package:haven/src/widgets/common/empty_state.dart';

/// Completer used by the loading test so the future never completes
/// without leaving a pending Timer.
Completer<List<Invitation>>? _loadingCompleter;

Widget _buildApp({required AsyncValue<List<Invitation>> invitationsState}) {
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
      // Override the poller to avoid side effects
      invitationPollerProvider.overrideWith((ref) async => 0),
    ],
    child: MaterialApp(
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
    memberCount: 3,
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

      expect(find.text('Invitations'), findsOneWidget);
    });

    testWidgets('shows refresh button in AppBar', (tester) async {
      await tester.pumpWidget(
        _buildApp(invitationsState: const AsyncValue.data([])),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byTooltip('Refresh invitations'), findsOneWidget);
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

      expect(find.byType(HavenEmptyState), findsOneWidget);
      expect(find.text('No Invitations'), findsOneWidget);
      expect(
        find.text('When someone invites you to a circle, it will appear here.'),
        findsOneWidget,
      );
    });

    testWidgets('shows invitation cards when invitations exist', (
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

      expect(find.byType(InvitationCard), findsNWidgets(2));
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
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

      expect(find.text('Could not load invitations'), findsOneWidget);
    });
  });
}
