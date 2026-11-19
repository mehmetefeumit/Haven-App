/// Tests for the InvitationsPage.
///
/// Verifies:
/// - AppBar title and refresh button
/// - Loading state
/// - Empty state display
/// - Invitation list rendering
/// - Opening the page issues no profile relay fetch for the inviters
/// - A failed list read is an error with Retry, never an empty list
/// - A refresh that did not read every inbox relay in full shows a notice
///   with its one action, and one that did shows none
/// - A refresh that was refused or could not save an invitation announces
///   the notice once as it settles, after the ring's own announcement
/// - A tap on the ring while a refresh runs starts a new one, whose result
///   is what settles
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/models/relay_ring_slot.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';
import 'package:haven/src/widgets/common/empty_state.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';
import '../../mocks/mock_relay_preferences_service.dart';
import '../../mocks/mock_relay_service.dart';

/// Completer used by the loading test so the future never completes
/// without leaving a pending Timer.
Completer<List<Invitation>>? _loadingCompleter;

/// Refresh-status notifier that does nothing, so the page's initState refresh
/// never touches the real identity/relay stack in these list-focused tests.
class _NoopPollStatus extends InvitationPollStatusNotifier {
  @override
  InvitationPollStatus build() => InvitationPollStatus.idle;

  @override
  Future<void> refresh() async {}
}

/// A refresh status fixed at [status]; counts the refreshes asked for.
class _FixedPollStatus extends InvitationPollStatusNotifier {
  _FixedPollStatus(this.status);

  final InvitationPollStatus status;
  int refreshes = 0;

  @override
  InvitationPollStatus build() => status;

  @override
  Future<void> refresh() async => refreshes++;
}

/// Plays a refresh per call: every slot in flight, then, once [release]
/// completes, the relays' answers and [settled] in one synchronous run, so
/// the ring and the page see the settle in the same frame.
class _ScriptedPollStatus extends InvitationPollStatusNotifier {
  _ScriptedPollStatus(this.settled);

  final InvitationPollStatus settled;
  Completer<void> release = Completer<void>();

  @override
  InvitationPollStatus build() => InvitationPollStatus.idle;

  @override
  Future<void> refresh() async {
    state = InvitationPollStatus(
      phase: InvitationPollPhase.checking,
      total: settled.slots.length,
      slots: [for (final _ in settled.slots) RelayRingSlotState.checking],
    );
    await release.future;
    release = Completer<void>();
    state = InvitationPollStatus(
      phase: InvitationPollPhase.checking,
      total: settled.slots.length,
      slots: settled.slots,
    );
    state = settled;
  }
}

InvitationPollStatus _settled(
  InvitationPollOutcome outcome, {
  int refused = 0,
  int notSaved = 0,
  List<RelayRingSlotState> slots = const [
    RelayRingSlotState.error,
    RelayRingSlotState.ok,
  ],
}) => InvitationPollStatus(
  phase: InvitationPollPhase.settled,
  total: slots.length,
  refused: refused,
  notSaved: notSaved,
  slots: slots,
  outcome: outcome,
);

/// The page with the real list provider over [circle] and a fixed refresh
/// status, plus what Relay settings needs to open without the FFI.
Widget _buildNoticeApp({
  required InvitationPollStatusNotifier status,
  MockCircleService? circle,
}) => ProviderScope(
  overrides: [
    invitationPollStatusProvider.overrideWith(() => status),
    profileServiceProvider.overrideWithValue(MockProfileService()),
    circleServiceProvider.overrideWithValue(circle ?? MockCircleService()),
    identityProvider.overrideWith((ref) async => null),
    relayPreferencesServiceProvider.overrideWith(
      (ref) async => MockRelayPreferencesService(),
    ),
    relayServiceProvider.overrideWithValue(MockRelayService()),
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
      // Stub the refresh status so the page's refresh has no side effects.
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

    testWidgets('a failed read is an error with Retry, never the empty '
        'state, and Retry reads again', (tester) async {
      final circle = MockCircleService()
        ..getPendingInvitationsThrows = StateError('ffi');
      await tester.pumpWidget(
        _buildNoticeApp(
          status: _FixedPollStatus(InvitationPollStatus.idle),
          circle: circle,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load invitations'), findsOneWidget);
      expect(find.text('No Invitations'), findsNothing);
      final reads = circle.methodCalls
          .where((c) => c == 'getPendingInvitations')
          .length;

      circle.getPendingInvitationsThrows = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(
        circle.methodCalls.where((c) => c == 'getPendingInvitations'),
        hasLength(reads + 1),
      );
      expect(find.text('No Invitations'), findsOneWidget);
    });
  });

  group('InvitationsPage inbox notice', () {
    testWidgets('a refresh that read every relay shows no notice', (
      tester,
    ) async {
      for (final outcome in [
        InvitationPollOutcome.upToDate,
        InvitationPollOutcome.newInvites,
        InvitationPollOutcome.noInbox,
        null,
      ]) {
        await tester.pumpWidget(
          _buildNoticeApp(
            status: _FixedPollStatus(
              outcome == null
                  ? InvitationPollStatus.idle
                  : _settled(outcome),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(WidgetKeys.invitationsInboxNotice),
          findsNothing,
          reason: '$outcome',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a refused relay is told, counted, and Relay settings opens; '
        'coming back reads the inbox again', (tester) async {
      final status = _FixedPollStatus(
        _settled(InvitationPollOutcome.refused, refused: 1),
      );
      await tester.pumpWidget(_buildNoticeApp(status: status));
      await tester.pumpAndSettle();
      final opened = status.refreshes;

      expect(find.byKey(WidgetKeys.invitationsInboxNotice), findsOneWidget);
      expect(
        find.text(
          "1 inbox relay didn't let Haven read your invitations, so an "
          "invitation sent only there won't reach you. In Relay settings, "
          'remove it or add another relay.',
        ),
        findsOneWidget,
      );
      // Shown above the empty state, not in place of it.
      expect(find.text('No Invitations'), findsOneWidget);

      await tester.tap(find.text('Relay settings'));
      await tester.pumpAndSettle();
      expect(find.byType(RelaySettingsPage), findsOneWidget);
      expect(status.refreshes, opened, reason: 'not before the user is back');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(RelaySettingsPage), findsNothing);
      expect(status.refreshes, opened + 1);
    });

    testWidgets('an unfinished read is told, and Relay settings opens', (
      tester,
    ) async {
      final status = _FixedPollStatus(
        _settled(InvitationPollOutcome.incomplete),
      );
      await tester.pumpWidget(_buildNoticeApp(status: status));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Haven couldn't finish checking all your inbox relays, so some "
          'invitations may not show up yet.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Relay settings'));
      await tester.pumpAndSettle();
      expect(find.byType(RelaySettingsPage), findsOneWidget);
    });

    testWidgets('offline and not-saved are told, and Try Again reads the '
        'inbox again', (tester) async {
      for (final (status, text) in [
        (
          _settled(InvitationPollOutcome.offline),
          "Haven couldn't reach your inbox relays, so new invitations can't "
              'show up yet.',
        ),
        (
          _settled(InvitationPollOutcome.notSaved, notSaved: 2),
          "2 invitations arrived but couldn't be saved on this device.",
        ),
      ]) {
        final notifier = _FixedPollStatus(status);
        await tester.pumpWidget(_buildNoticeApp(status: notifier));
        await tester.pumpAndSettle();
        final opened = notifier.refreshes;

        expect(find.text(text), findsOneWidget);
        await tester.tap(find.text('Try Again'));
        await tester.pump();
        expect(notifier.refreshes, opened + 1, reason: text);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the notice is one container a screen reader moves through '
        'in words, with a decorative icon, no live region and no relay '
        'named', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _buildNoticeApp(
          status: _FixedPollStatus(
            _settled(InvitationPollOutcome.refused, refused: 2),
          ),
        ),
      );
      await tester.pumpAndSettle();

      const message =
          "2 inbox relays didn't let Haven read your invitations, so an "
          "invitation sent only there won't reach you. In Relay settings, "
          'remove them or add another relay.';
      final node = tester.getSemantics(find.text(message));
      expect(node.label, message);
      expect(node.flagsCollection.isLiveRegion, isFalse);
      expect(
        find.bySemanticsLabel(RegExp(r'wss://|\.example|\.com')),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.descendant(
            of: find.byKey(WidgetKeys.invitationsInboxNotice),
            matching: find.byIcon(LucideIcons.triangleAlert),
          ),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
        reason: 'the icon repeats the words; it is not read',
      );
      expect(
        find.descendant(
          of: find.byKey(WidgetKeys.invitationsInboxNotice),
          matching: find.byType(TextButton),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });

  group('InvitationsPage inbox notice announcement', () {
    const ok = RelayRingSlotState.ok;
    const error = RelayRingSlotState.error;
    const refusedText =
        "1 inbox relay didn't let Haven read your invitations, so an "
        "invitation sent only there won't reach you. In Relay settings, "
        'remove it or add another relay.';
    const notSavedText =
        "2 invitations arrived but couldn't be saved on this device.";

    testWidgets('a refresh that was refused or could not save an invitation '
        'says so once as it settles, after the ring, and again only at the '
        'next settle', (tester) async {
      for (final (settled, ring, notice) in [
        (
          _settled(InvitationPollOutcome.refused, refused: 1),
          'Invitations checked on 1 of 2 relays',
          refusedText,
        ),
        (
          // Every relay served the read, so the ring speaks of success: the
          // notice is the only place the lost invitation is told.
          _settled(
            InvitationPollOutcome.notSaved,
            notSaved: 2,
            slots: const [ok, ok],
          ),
          'Invitations checked on every relay',
          notSavedText,
        ),
      ]) {
        final announced = captureAccessibilityAnnouncements(tester);
        final status = _ScriptedPollStatus(settled);
        await tester.pumpWidget(_buildNoticeApp(status: status));
        await tester.pump();
        expect(announced, isEmpty, reason: notice);

        status.release.complete();
        await tester.pump();
        expect(announced, [ring, notice]);

        // Rebuilds of a settled page say nothing more.
        tester.element(find.byType(InvitationsPage)).markNeedsBuild();
        await tester.pumpAndSettle();
        expect(announced, [ring, notice]);

        await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
        await tester.pump();
        status.release.complete();
        await tester.pump();
        expect(announced, [ring, notice, 'Checking relays', ring, notice]);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a refresh that lost no invitation leaves the ring to speak '
        'alone', (tester) async {
      for (final (settled, ring) in [
        (
          _settled(InvitationPollOutcome.upToDate, slots: const [ok, ok]),
          ['Invitations checked on every relay'],
        ),
        (
          _settled(InvitationPollOutcome.newInvites, slots: const [ok, ok]),
          ['Invitations checked on every relay'],
        ),
        (
          _settled(InvitationPollOutcome.offline, slots: const [error, error]),
          ["Couldn't check invitations on any relay"],
        ),
        (
          _settled(InvitationPollOutcome.incomplete),
          ['Invitations checked on 1 of 2 relays'],
        ),
        (
          _settled(InvitationPollOutcome.noInbox, slots: const []),
          <String>[],
        ),
      ]) {
        final announced = captureAccessibilityAnnouncements(tester);
        final status = _ScriptedPollStatus(settled);
        await tester.pumpWidget(_buildNoticeApp(status: status));
        await tester.pump();
        status.release.complete();
        await tester.pumpAndSettle();
        expect(announced, ring, reason: '${settled.outcome}');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a real refresh one relay refused is told after the ring '
        'counts it', (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async => [
          RelayGiftWrapFetch(
            relayUrl: relays.single,
            read: relays.single == 'wss://a.example.com'
                ? InboxRead.refused
                : InboxRead.served,
            events: const [],
          ),
        ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pendingInvitationsProvider.overrideWith((ref) async => []),
            profileServiceProvider.overrideWithValue(MockProfileService()),
            circleServiceProvider.overrideWithValue(MockCircleService()),
            identityProvider.overrideWith(
              (ref) async => Identity(
                pubkeyHex: 'ab' * 32,
                npub: 'npub1test',
                createdAt: DateTime(2024),
              ),
            ),
            relayServiceProvider.overrideWithValue(relay),
            inboxRelaysProvider.overrideWith(
              () => _StubInboxRelays(const [
                'wss://a.example.com',
                'wss://b.example.com',
              ]),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: InvitationsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(refusedText), findsOneWidget);
      expect(announced, ['Invitations checked on 1 of 2 relays', refusedText]);
    });
  });

  group('InvitationsPage responsiveness', () {
    testWidgets('a tap on the ring while a refresh runs starts a new one, '
        'and its result is what settles', (tester) async {
      // The first refresh's read parks; the tap must not wait for it.
      final firstRead = Completer<void>();
      var reads = 0;
      final relay = MockRelayService()
        ..fetchGiftWrapsPerRelayHandler = (relays) async {
          final mine = ++reads;
          if (mine == 1) {
            await firstRead.future;
            return [
              RelayGiftWrapFetch(
                relayUrl: relays.single,
                read: InboxRead.unreached,
                events: const [],
              ),
            ];
          }
          return [
            RelayGiftWrapFetch(
              relayUrl: relays.single,
              read: InboxRead.served,
              events: const [],
            ),
          ];
        };
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pendingInvitationsProvider.overrideWith((ref) async => []),
            profileServiceProvider.overrideWithValue(MockProfileService()),
            circleServiceProvider.overrideWithValue(MockCircleService()),
            identityProvider.overrideWith(
              (ref) async => Identity(
                pubkeyHex: 'ab' * 32,
                npub: 'npub1test',
                createdAt: DateTime(2024),
              ),
            ),
            relayServiceProvider.overrideWithValue(relay),
            inboxRelaysProvider.overrideWith(
              () => _StubInboxRelays(const ['wss://inbox.example.com']),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: InvitationsPage(),
            ),
          ),
        ),
      );
      // The page reads the inbox as it opens; that read is now parked.
      await tester.pump();
      await tester.pump();
      expect(reads, 1);
      expect(find.bySemanticsLabel('0 of 1 relay checked'), findsOneWidget);

      await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
      await tester.pump();
      await tester.pump();

      expect(reads, 2, reason: 'the tap took effect while the first ran');
      expect(
        find.bySemanticsLabel('Invitations checked on the relay'),
        findsOneWidget,
      );

      // The superseded read answering late changes nothing.
      firstRead.complete();
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel("Couldn't check invitations on any relay"),
        findsNothing,
      );
      semantics.dispose();
    });
  });
}

/// Inbox-relay notifier stub returning a fixed list.
class _StubInboxRelays extends InboxRelaysNotifier {
  _StubInboxRelays(this._relays);

  final List<String> _relays;

  @override
  Future<List<String>> build() async => _relays;
}
