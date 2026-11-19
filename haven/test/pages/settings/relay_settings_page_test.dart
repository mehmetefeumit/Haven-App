/// Widget tests for the editable [`RelaySettingsPage`].
///
/// Cover section presence, edit affordances, the explanation panels, the
/// per-item status symbols that follow the maintenance passes, the
/// announcements, the page-open pass, input that lands while something
/// moves, accessibility, and (for the local-only Profile category) the
/// advisory contamination warning and underflow banner.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/models/own_relay_board.dart';
import 'package:haven/src/pages/settings/relay_info_sheet.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/pages/settings/relay_status_cell.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/relay_status_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/fake_board_source.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_preferences_service.dart';
import '../../mocks/mock_relay_service.dart';

Identity _stubIdentity() => Identity(
  pubkeyHex: '0' * 64,
  npub: 'npub1stub',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

const _inbox = 'wss://inbox.example.com';
const _kp = 'wss://kp.example.com';

/// The status cell for [kind] inside [section], optionally for one relay.
Finder cellIn(String section, RelayKind kind, {String? url}) => find.descendant(
  of: find.byKey(WidgetKeys.relaySettingsSection(section)),
  matching: find.byWidgetPredicate(
    (w) =>
        w is RelayKindStatusCell &&
        w.kind == kind &&
        (url == null || w.relayUrl == url),
  ),
);

/// Every status cell inside [section].
Finder cellsIn(String section) => find.descendant(
  of: find.byKey(WidgetKeys.relaySettingsSection(section)),
  matching: find.byType(RelayKindStatusCell),
);

/// [text] inside [section].
Finder textIn(String section, String text) => find.descendant(
  of: find.byKey(WidgetKeys.relaySettingsSection(section)),
  matching: find.text(text),
);

OwnRelayStatus _ownStatusOf(KindPresence p) => switch (p) {
  KindPresence.checking => OwnRelayStatus.checking,
  KindPresence.publishing => OwnRelayStatus.publishing,
  KindPresence.current => OwnRelayStatus.current,
  KindPresence.missing => OwnRelayStatus.missing,
  KindPresence.outdated => OwnRelayStatus.outdated,
  KindPresence.refused => OwnRelayStatus.refused,
  KindPresence.unconfirmed => OwnRelayStatus.unconfirmed,
  KindPresence.noAnswer => OwnRelayStatus.noAnswer,
  KindPresence.notChecked ||
  KindPresence.held => throw ArgumentError('not a cell state: $p'),
};

/// A board on which every expected item of [_inbox], [_kp] and the lookup
/// relays reads [p].
OwnRelayBoard boardAll(KindPresence p) {
  if (p == KindPresence.notChecked) return const OwnRelayBoard();
  if (p == KindPresence.held) {
    const held = OwnKindBoard(
      hold: OwnPublishHold.awaitingResetAcknowledgement,
    );
    return const OwnRelayBoard(
      keyPackage: held,
      relayList: held,
      inboxRelayList: held,
    );
  }
  List<OwnRelayCell> cells(List<String> urls) => [
    for (final url in urls)
      OwnRelayCell(relayUrl: url, status: _ownStatusOf(p)),
  ];
  return OwnRelayBoard(
    lookupRelays: fallbackDiscoveryRelays,
    keyPackage: OwnKindBoard(cells: cells(const [_kp])),
    relayList: OwnKindBoard(cells: cells([_kp, ...fallbackDiscoveryRelays])),
    inboxRelayList: OwnKindBoard(
      cells: cells([_inbox, ...fallbackDiscoveryRelays]),
    ),
  );
}

/// A board with one item of [_kp] in [p] and everything else current.
OwnRelayBoard boardWithKeyPackage(KindPresence p) {
  final base = boardAll(KindPresence.current);
  return OwnRelayBoard(
    lookupRelays: base.lookupRelays,
    keyPackage: switch (p) {
      KindPresence.notChecked => const OwnKindBoard(),
      KindPresence.held => const OwnKindBoard(
        hold: OwnPublishHold.awaitingResetAcknowledgement,
      ),
      _ => OwnKindBoard(
        cells: [OwnRelayCell(relayUrl: _kp, status: _ownStatusOf(p))],
      ),
    },
    relayList: base.relayList,
    inboxRelayList: base.inboxRelayList,
  );
}

/// Grows the test surface so every section is laid out at once.
void tallSurface(WidgetTester tester, {Size size = const Size(800, 3200)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _RouteLog extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  List<Override> appOverrides({
    required MockRelayPreferencesService mock,
    Identity? identity,
    Future<RelayPreferencesService> Function()? openService,
    MockRelayService? relay,
    FakeBoardSource? board,
    List<Override> extra = const [],
  }) => [
    ...extra,
    maintenanceServiceProvider.overrideWithValue(board ?? FakeBoardSource()),
    appForegroundProvider.overrideWith((_) => true),
    identityProvider.overrideWith((ref) async => identity ?? _stubIdentity()),
    relayPreferencesServiceProvider.overrideWith(
      (ref) async => openService == null ? mock : await openService(),
    ),
    // disconnect_relay routes through RelayService now; tests don't
    // exercise the persistent FFI client, but the page still calls
    // it on remove and would otherwise hit production NostrRelayService.
    relayServiceProvider.overrideWithValue(relay ?? MockRelayService()),
    // Removing/restoring a relay invalidates `keyPackagePublisherProvider`
    // downstream (`InboxRelaysNotifier._invalidateDownstream`), which now
    // resolves a real `CircleManagerFfi` via `maintenanceServiceProvider`
    // (Dark Matter DM-4). Without this override the default provider
    // constructs a real `NostrCircleService`, which reaches the native
    // keyring plugin in this pure widget-test sandbox — a slow, flaky
    // real-async round trip that can settle after `pumpAndSettle` gives
    // up, surfacing as an unhandled exception "after the test had
    // completed". A non-`NostrCircleService` fake makes
    // `maintenanceServiceProvider`'s `circleManagerFactory` fail fast and
    // synchronously (`StateError`, caught by
    // `MaintenanceService._withSecret`) instead.
    circleServiceProvider.overrideWithValue(MockCircleService()),
  ];

  const page = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: RelaySettingsPage(),
  );

  Widget buildApp({
    required MockRelayPreferencesService mock,
    Identity? identity,
    Future<RelayPreferencesService> Function()? openService,
    MockRelayService? relay,
    FakeBoardSource? board,
    List<Override> extra = const [],
    ThemeData? theme,
    Locale? locale,
    TextScaler? textScaler,
    bool reduceMotion = false,
    List<NavigatorObserver> observers = const [],
  }) => ProviderScope(
    overrides: appOverrides(
      mock: mock,
      identity: identity,
      openService: openService,
      relay: relay,
      board: board,
      extra: extra,
    ),
    child: MaterialApp(
      theme: theme,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: observers,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: textScaler, disableAnimations: reduceMotion),
        child: child!,
      ),
      home: const RelaySettingsPage(),
    ),
  );

  MockRelayPreferencesService seededMock() => MockRelayPreferencesService(
    initialRelays: const {
      RelayCategory.inbox: ['wss://inbox.example.com'],
      RelayCategory.keyPackage: ['wss://kp.example.com'],
      RelayCategory.profile: ['wss://profile.example.com'],
    },
  );

  group('RelaySettingsPage', () {
    testWidgets('renders three relay sections', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      expect(find.text('My Inbox Relays'), findsOneWidget);
      expect(find.text('My KeyPackage Relays'), findsOneWidget);
      expect(find.text('My Profile Relays'), findsOneWidget);
      expect(find.text('inbox.example.com'), findsOneWidget);
      expect(find.text('kp.example.com'), findsOneWidget);
      expect(find.text('profile.example.com'), findsOneWidget);
      for (final section in RelaySettingsSection.values) {
        expect(
          find.byKey(WidgetKeys.relaySettingsInfoButton(section.name)),
          findsOneWidget,
        );
      }
    });

    testWidgets('offers no manual refresh or republish', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.actions ?? const <Widget>[], isEmpty);
      // The only buttons with a label are the lists' own Add and Restore...
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is OutlinedButton ||
              w is TextButton ||
              w is FilledButton ||
              w is ElevatedButton,
        ),
        findsNWidgets(6),
        reason: 'three Add relay and three Restore defaults, nothing else',
      );
      // ...and every icon button is a section's question mark or a row's
      // remove button.
      final allowed = {
        WidgetKeys.relaySettingsRemoveRelay,
        for (final s in RelaySettingsSection.values)
          WidgetKeys.relaySettingsInfoButton(s.name),
      };
      for (final e in find.byType(IconButton).evaluate()) {
        expect(allowed, contains(e.widget.key));
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets("the lookup list is Haven's: nothing in its section edits it", (
      tester,
    ) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      Finder inSection(String section, Finder matching) => find.descendant(
        of: find.byKey(WidgetKeys.relaySettingsSection(section)),
        matching: matching,
      );
      final lookup = RelaySettingsSection.lookup.name;
      expect(
        cellsIn(lookup),
        findsNWidgets(fallbackDiscoveryRelays.length * 2),
        reason: 'non-vacuity: every built-in lookup relay has its row',
      );
      final iconButtons = inSection(lookup, find.byType(IconButton));
      expect(iconButtons, findsOneWidget, reason: 'its question mark alone');
      expect(
        tester.widget<IconButton>(iconButtons).key,
        WidgetKeys.relaySettingsInfoButton(lookup),
      );
      expect(
        inSection(
          lookup,
          find.byWidgetPredicate(
            (w) =>
                w is OutlinedButton ||
                w is TextButton ||
                w is FilledButton ||
                w is ElevatedButton,
          ),
        ),
        findsNothing,
        reason: 'no Add relay or Restore defaults',
      );
      expect(
        inSection('inbox', find.byKey(WidgetKeys.relaySettingsRemoveRelay)),
        findsOneWidget,
        reason: "the user's own list keeps its remove control",
      );
    });

    testWidgets('shows a short caption, not the long explainer', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // Enough framing survives to make the section headers meaningful...
      final caption = find.textContaining('no server of its own');
      await tester.scrollUntilVisible(caption, 300);
      expect(caption, findsOneWidget);

      // ...but not the 450-word explainer. A second copy of it here is what
      // let the two drift apart before.
      expect(find.text('How this works'), findsNothing);
      expect(find.textContaining('forward secrecy'), findsNothing);
      expect(find.textContaining('are your mailbox'), findsNothing);
    });

    testWidgets('renders Add relay buttons for each category', (tester) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // One Add button per category — now 3 with Profile added.
      expect(find.text('Add relay'), findsNWidgets(3));
    });

    testWidgets('renders Restore defaults buttons for each category', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      expect(find.text('Restore defaults'), findsNWidgets(3));
    });

    testWidgets('shows empty-identity state when no identity', (tester) async {
      final mock = MockRelayPreferencesService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((ref) async => null),
            relayPreferencesServiceProvider.overrideWith((ref) async => mock),
            relayServiceProvider.overrideWithValue(MockRelayService()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RelaySettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Identity'), findsOneWidget);
    });

    testWidgets('strips wss:// prefix in relay row display', (tester) async {
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://nice.example.com'],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      // Display strips wss:// for compactness.
      expect(find.text('nice.example.com'), findsOneWidget);
      expect(find.text('wss://nice.example.com'), findsNothing);
    });

    testWidgets('removes a relay via the trash icon', (tester) async {
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: [
            'wss://keep.example.com',
            'wss://drop.example.com',
          ],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
        },
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      // Tap the trash icon for the relay we want to drop. The tooltip
      // is "Remove <displayUrl>" — see _EditableRelayRow.
      await tester.tap(find.byTooltip('Remove drop.example.com'));
      await tester.pumpAndSettle();

      expect(find.text('drop.example.com'), findsNothing);
      expect(find.text('keep.example.com'), findsOneWidget);
    });

    // -------------------------------------------------------------------
    // Profile section: the curated pool is not user-removable.
    //
    // `usable_profile_relays()` unions `profile_relay_pool_default()` back in
    // on every resolution, so deleting a curated row shortened the list on
    // screen without shortening the set Haven dials — proved in
    // `haven-core/tests/profile_curated_pool_removal.rs`. The page therefore
    // offers no remove control for those rows, and tops the stored list back
    // up so an install upgraded from a build that DID offer one stops showing
    // a short list.
    // -------------------------------------------------------------------

    /// Grows the test surface so all three sections plus their controls are
    /// laid out. Same reason as the Add-relay and underflow-banner cases
    /// below: at 800x600 a widget far down this page may never be inflated.
    void useTallSurface(WidgetTester tester) {
      final originalSize = tester.view.physicalSize;
      final originalRatio = tester.view.devicePixelRatio;
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.physicalSize = originalSize;
        tester.view.devicePixelRatio = originalRatio;
      });
    }

    testWidgets(
      'offers no remove control for a curated Profile relay, but keeps one '
      "for the user's own addition",
      (tester) async {
        useTallSurface(tester);
        expect(
          fallbackDefaultProfileRelays,
          isNotEmpty,
          reason:
              'non-vacuity: an empty curated pool would make the '
              'suppressed-control assertion below unreachable',
        );
        final curated = fallbackDefaultProfileRelays.first;
        final mock = MockRelayPreferencesService(
          initialRelays: {
            RelayCategory.inbox: const ['wss://inbox.example.com'],
            RelayCategory.keyPackage: const ['wss://kp.example.com'],
            RelayCategory.profile: [curated, 'wss://mine.example.com'],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        // Both rows render...
        final curatedHost = curated.replaceFirst('wss://', '');
        expect(find.text(curatedHost), findsOneWidget);
        expect(find.text('mine.example.com'), findsOneWidget);

        // ...but only the user's own addition can be removed. Offering it on
        // the curated row would be offering an action Haven ignores.
        expect(find.byTooltip('Remove $curatedHost'), findsNothing);
        expect(find.byTooltip('Remove mine.example.com'), findsOneWidget);
      },
    );

    testWidgets(
      'suppresses the curated Profile remove control across URL spelling '
      'variants',
      (tester) async {
        useTallSurface(tester);
        // The fail-open this guards: a stored row that differs from the
        // curated constant only by case or a trailing slash would compare
        // unequal, the trash icon would come back, and tapping it would once
        // again shorten the list without shortening what Haven dials — the
        // same normalization trap `exclusion_matches_across_url_normalization`
        // exists for on the Rust side.
        final curated = fallbackDefaultProfileRelays.first;
        final host = curated.replaceFirst('wss://', '');
        final variant = 'wss://${host.toUpperCase()}/';
        // A companion user-owned row, same as the case above: pairing the
        // negative assertion below with a positive on the SAME tooltip
        // pattern (rather than asserting `findsNothing` alone) is what rules
        // out the row never rendering, the section failing to inflate, or
        // the tooltip's English having drifted out from under the finder.
        final mock = MockRelayPreferencesService(
          initialRelays: {
            RelayCategory.inbox: const ['wss://inbox.example.com'],
            RelayCategory.keyPackage: const ['wss://kp.example.com'],
            RelayCategory.profile: [variant, 'wss://mine.example.com'],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        expect(find.text('${host.toUpperCase()}/'), findsOneWidget);
        expect(find.text('mine.example.com'), findsOneWidget);

        expect(
          find.byTooltip('Remove ${host.toUpperCase()}/'),
          findsNothing,
          reason: 'a case/slash variant of a curated relay is still curated',
        );
        expect(find.byTooltip('Remove mine.example.com'), findsOneWidget);
      },
    );

    testWidgets('still offers removal for the same URL in the Inbox category', (
      tester,
    ) async {
      useTallSurface(tester);
      // The rule is about the profile plane's curated pool, not about the
      // URL: the Inbox list is genuinely user-owned, and removal there
      // really does take effect. Scoping the suppression to the Profile
      // section is what keeps this true.
      final curated = fallbackDefaultProfileRelays.first;
      final curatedHost = curated.replaceFirst('wss://', '');
      final mock = MockRelayPreferencesService(
        initialRelays: {
          RelayCategory.inbox: [curated, 'wss://second.example.com'],
          RelayCategory.keyPackage: const ['wss://kp.example.com'],
          RelayCategory.profile: const ['wss://mine.example.com'],
        },
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove $curatedHost'), findsOneWidget);
    });

    testWidgets(
      'tops the Profile list back up on open, and only that category',
      (tester) async {
        useTallSurface(tester);
        // An install upgraded from a build that offered the (inert) remove
        // control can hold a Profile list shorter than the set Haven dials,
        // and no other affordance on this page repairs it without also
        // discarding the user's own additions.
        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: ['wss://mine.example.com'],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        // The user's own addition survives the top-up...
        expect(find.text('mine.example.com'), findsOneWidget);
        // ...and the missing default is back on screen. The mock's Profile
        // defaults are a string family distinct from the Inbox/KeyPackage
        // ones (mirrors `seedDefaultsIfUnseeded`/`restoreDefaultProfileRelays`
        // below), so a top-up wired to the wrong category cannot satisfy this
        // assertion by coincidence of shared fixture strings.
        expect(
          find.text('profile-default-a'),
          findsOneWidget,
          reason: 'the Profile list on screen must be the list Haven uses',
        );
        expect(
          find.text('default-a'),
          findsNothing,
          reason:
              'the generic (non-profile) default must never land in the '
              'Profile pool — that is the plane-crossing this test exists '
              'to catch',
        );
        // Exactly `profile`: the Inbox and KeyPackage lists are the user's
        // to shorten, so a top-up must not touch them at all — not even as
        // a no-op call. Two positive assertions above already prove nothing
        // was dropped from those two lists; this proves nothing was ADDED
        // to them either, which the mock returning the same defaults for
        // every category would otherwise let slip through unnoticed.
        expect(
          mock.log.where((entry) => entry.startsWith('restore:')).toList(),
          ['restore:profile'],
        );
      },
    );

    testWidgets(
      "sequences the top-up after the Profile notifier's own build(), so a "
      'slow initial read cannot silently undo it',
      (tester) async {
        useTallSurface(tester);
        // This mock's async methods otherwise resolve in a fixed microtask
        // order, which would let an unsequenced top-up pass by coincidence.
        // Gating build()'s own first read forces the two chains to actually
        // interleave, the way a real slow storage read could.
        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: ['wss://mine.example.com'],
          },
        );
        final gate = Completer<void>();
        mock.profileListRelaysGate = gate;

        await tester.pumpWidget(buildApp(mock: mock));
        // Let every chain that does not depend on the gated read run to
        // completion — on unsequenced code, that includes the top-up's own
        // write-then-read-then-state-assignment.
        await tester.pump();
        await tester.pump();

        // Release the gated build() read. On unsequenced code this is where
        // the bug bites: build()'s snapshot (captured before the top-up
        // wrote) resolves last and overwrites the correct state.
        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('mine.example.com'), findsOneWidget);
        expect(
          find.text('profile-default-a'),
          findsOneWidget,
          reason:
              "the top-up must win even when the notifier's own "
              'initial read is slow to resolve',
        );
      },
    );

    // -------------------------------------------------------------------
    // Profile section: advisory contamination warning (task requirement).
    // -------------------------------------------------------------------

    testWidgets(
      'shows a contamination warning on a Profile relay that also carries '
      'inbox traffic, and not on a clean Profile relay',
      (tester) async {
        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: [
              'wss://inbox.example.com',
              'wss://clean-profile.example.com',
            ],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        // Exactly one of the two Profile relays overlaps the inbox list, so
        // exactly one warning icon renders.
        expect(
          find.byTooltip('Also carries other Haven traffic'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows a contamination warning on a Profile relay that overlaps a '
      "circle's own relay, not just the inbox list",
      (tester) async {
        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: ['wss://circle-only.example.com'],
          },
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((ref) async => _stubIdentity()),
              relayPreferencesServiceProvider.overrideWith((ref) async => mock),
              relayServiceProvider.overrideWithValue(MockRelayService()),
              circleServiceProvider.overrideWithValue(
                MockCircleService(
                  circles: [
                    TestCircleFactory.createCircle(
                      relays: const ['wss://circle-only.example.com'],
                    ),
                  ],
                ),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: RelaySettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byTooltip('Also carries other Haven traffic'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows a contamination warning on a Profile relay that overlaps the '
      'KeyPackage list',
      (tester) async {
        // The Rust ledger records the KeyPackage category
        // (`ContaminationSource::KeyPackage`, written on every
        // seed/add/restore) and `usable_profile_relays()` silently subtracts
        // it, so a Profile row carrying the same URL is configured but dead.
        // Before this case was covered the Dart advisory unioned only the
        // circle + inbox lists, so that row rendered with NO warning at all.
        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp-only.example.com'],
            RelayCategory.profile: [
              'wss://kp-only.example.com',
              'wss://clean-profile.example.com',
            ],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        // Exactly one of the two Profile rows overlaps the KeyPackage list.
        expect(
          find.byTooltip('Also carries other Haven traffic'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows a contamination warning on a Profile relay that is also a '
      'discovery-plane relay',
      (tester) async {
        // The discovery plane serves this account's KeyPackage / NIP-65
        // lookups of OTHER users — a stronger co-membership signal than a
        // kind-0 lookup — so Rust records it
        // (`ContaminationSource::Discovery`, folded in by
        // `refresh_contamination_ledger`) and excludes it from the pool.
        expect(
          discoveryRelays,
          isNotEmpty,
          reason:
              'non-vacuity: an empty discovery plane would make the '
              'warning assertion below unreachable',
        );
        final mock = MockRelayPreferencesService(
          initialRelays: {
            RelayCategory.inbox: const ['wss://inbox.example.com'],
            RelayCategory.keyPackage: const ['wss://kp.example.com'],
            RelayCategory.profile: [
              discoveryRelays.first,
              'wss://clean-profile.example.com',
            ],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        expect(
          find.byTooltip('Also carries other Haven traffic'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'does not warn on the Inbox/KeyPackage sections even when a relay '
      'is shared between them',
      (tester) async {
        // Both categories share the same URL — the contamination warning is
        // Profile-only, so this must render zero warning icons even though
        // the same "overlap" condition would trigger one on a Profile row.
        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://shared.example.com'],
            RelayCategory.keyPackage: ['wss://shared.example.com'],
            RelayCategory.profile: ['wss://profile.example.com'],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        expect(
          find.byTooltip('Also carries other Haven traffic'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'still adds an overlapping relay to Profile — advisory only, never '
      'blocks',
      (tester) async {
        // Three sections plus the Add/Restore controls no longer fit the
        // default 800x600 test surface. Grow it so every "Add relay" button
        // is actually laid out (and hit-testable) without a fragile
        // scroll-then-tap — `scrollUntilVisible` only guarantees a widget is
        // built (inside the cache extent), not that it is on-screen, which
        // makes `tap` flaky the moment a page has this much content.
        final originalSize = tester.view.physicalSize;
        final originalRatio = tester.view.devicePixelRatio;
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.physicalSize = originalSize;
          tester.view.devicePixelRatio = originalRatio;
        });

        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: ['wss://clean-profile.example.com'],
          },
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        // Open the Profile section's Add-relay sheet (the 3rd "Add relay"
        // button: Inbox, KeyPackage, then Profile).
        final addButtons = find.text('Add relay');
        await tester.tap(addButtons.last);
        await tester.pumpAndSettle();

        // Paste a URL that already carries this account's inbox traffic —
        // the contaminated case — and submit via the paste-then-Add flow
        // (bypasses the typing debounce; mirrors add_relay_sheet_test.dart).
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': 'wss://inbox.example.com'};
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
        await tester.tap(find.byTooltip('Paste from clipboard'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();

        // The add succeeded (no error snackbar, and the service recorded
        // it) despite the overlap — proving the warning is advisory only.
        expect(mock.log, contains('add:profile:wss://inbox.example.com'));
        expect(find.text('Failed to add relay.'), findsNothing);
        expect(
          find.byTooltip('Also carries other Haven traffic'),
          findsOneWidget,
        );
      },
    );

    // -------------------------------------------------------------------
    // Profile section: pool-underflow warning banner (task requirement).
    // -------------------------------------------------------------------

    ProfilePoolStatus underflowedStatus() => const ProfilePoolStatus(
      configured: 8,
      excluded: 6,
      usable: 2,
      isUnderflow: true,
    );

    testWidgets('shows the profile-pool-underflow banner when the pool has '
        'underflowed', (tester) async {
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://inbox.example.com'],
          RelayCategory.keyPackage: ['wss://kp.example.com'],
          RelayCategory.profile: ['wss://profile.example.com'],
        },
        poolStatus: underflowedStatus(),
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      final title = find.text('Profile lookups paused');
      await tester.scrollUntilVisible(title, 300);
      expect(title, findsOneWidget);
      expect(
        find.text(
          "Too few Profile relays remain, so members' names and photos "
          'will stop updating.',
        ),
        findsOneWidget,
      );
      expect(find.text('Restore default profile relays'), findsOneWidget);
    });

    testWidgets(
      'hides the profile-pool-underflow banner when the pool is healthy',
      (tester) async {
        // seededMock() defaults to a healthy (non-underflow) pool.
        await tester.pumpWidget(buildApp(mock: seededMock()));
        await tester.pumpAndSettle();

        expect(find.text('Profile lookups paused'), findsNothing);
        expect(find.text('Restore default profile relays'), findsNothing);
      },
    );

    testWidgets(
      "tapping the underflow banner's Restore button calls the recovery "
      'action and clears the banner',
      (tester) async {
        // Grow the surface (see the "still adds an overlapping relay to
        // Profile" test above for why): the banner sits inside the Profile
        // section, the 3rd of three, and `scrollUntilVisible` only
        // guarantees the button is *built*, not on-screen and hit-testable,
        // at the default 800x600 test viewport.
        final originalSize = tester.view.physicalSize;
        final originalRatio = tester.view.devicePixelRatio;
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.physicalSize = originalSize;
          tester.view.devicePixelRatio = originalRatio;
        });

        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: ['wss://profile.example.com'],
          },
          poolStatus: underflowedStatus(),
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        final restoreButton = find.text('Restore default profile relays');
        await tester.scrollUntilVisible(restoreButton, 300);
        await tester.tap(restoreButton);
        await tester.pumpAndSettle();

        expect(mock.restoreDefaultProfileRelaysCalls, 1);
        // The mock's recovery action clears `isUnderflow`, exactly like the
        // real one, so the banner disappears without a manual refresh.
        expect(find.text('Profile lookups paused'), findsNothing);
        expect(find.text('Defaults restored.'), findsOneWidget);
      },
    );

    testWidgets(
      'shows an error snackbar and keeps the banner when the underflow '
      'recovery action fails',
      (tester) async {
        final originalSize = tester.view.physicalSize;
        final originalRatio = tester.view.devicePixelRatio;
        tester.view.physicalSize = const Size(800, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.physicalSize = originalSize;
          tester.view.devicePixelRatio = originalRatio;
        });

        final mock = MockRelayPreferencesService(
          initialRelays: const {
            RelayCategory.inbox: ['wss://inbox.example.com'],
            RelayCategory.keyPackage: ['wss://kp.example.com'],
            RelayCategory.profile: ['wss://profile.example.com'],
          },
          poolStatus: underflowedStatus(),
          restoreDefaultProfileRelaysThrows: const RelayPreferencesException(
            'boom',
          ),
        );
        await tester.pumpWidget(buildApp(mock: mock));
        await tester.pumpAndSettle();

        final restoreButton = find.text('Restore default profile relays');
        await tester.scrollUntilVisible(restoreButton, 300);
        await tester.tap(restoreButton);
        await tester.pumpAndSettle();

        expect(find.text('Failed to restore defaults.'), findsOneWidget);
        // The underlying status never changed, so the banner stays put.
        expect(find.text('Profile lookups paused'), findsOneWidget);
      },
    );
  });

  // While the Android MLS handoff holds, every manager open fails closed, and
  // the relay providers cache that as an `AsyncError` with no previous value.
  // Reading such a value with `.value` throws, and a release build paints the
  // throwing widget as a grey box filling the page.
  group('RelaySettingsPage when the relay providers failed to load', () {
    void growSurface(WidgetTester tester) {
      final originalSize = tester.view.physicalSize;
      final originalRatio = tester.view.devicePixelRatio;
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.physicalSize = originalSize;
        tester.view.devicePixelRatio = originalRatio;
      });
    }

    testWidgets('renders every section instead of an error box', (
      tester,
    ) async {
      growSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          openService: () async => throw StateError('handoff'),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('My Inbox Relays'), findsOneWidget);
      expect(find.text('My KeyPackage Relays'), findsOneWidget);
      expect(find.text('My Profile Relays'), findsOneWidget);
      expect(find.text('Failed to load relays.'), findsNWidgets(3));
      expect(find.text('Add relay'), findsNWidgets(3));
    });

    testWidgets('lists the relays once they load, each item not checked yet', (
      tester,
    ) async {
      growSurface(tester);
      final mock = seededMock();
      var failing = true;
      await tester.pumpWidget(
        buildApp(
          mock: mock,
          openService: () async {
            if (failing) throw StateError('handoff');
            return mock;
          },
        ),
      );
      await tester.pumpAndSettle();

      // The handoff ends and the lists are rebuilt (as MapShell's resume
      // heal does); the relay status follows the lists it watches.
      failing = false;
      ProviderScope.containerOf(tester.element(find.byType(RelaySettingsPage)))
        ..invalidate(relayPreferencesServiceProvider)
        ..invalidate(inboxRelaysProvider)
        ..invalidate(keyPackageRelaysProvider)
        ..invalidate(profileRelaysProvider);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('inbox.example.com'), findsOneWidget);
      expect(find.text('kp.example.com'), findsOneWidget);
      expect(find.text('profile.example.com'), findsOneWidget);
      // One symbol per kind each list publishes there, none checked yet.
      for (final (section, kind) in [
        ('inbox', RelayKind.inboxRelayList),
        ('keyPackage', RelayKind.keyPackage),
        ('keyPackage', RelayKind.relayList),
      ]) {
        expect(
          tester.widget<RelayKindStatusCell>(cellIn(section, kind)).status,
          KindPresence.notChecked,
          reason: '$section $kind',
        );
      }
    });

    testWidgets(
      'opening the page loads the KeyPackage and Profile lists that failed '
      'before it was opened, beside an Inbox list that did not',
      (tester) async {
        growSurface(tester);
        final mock = seededMock();
        var failing = true;
        final container = ProviderContainer(
          overrides: appOverrides(
            mock: mock,
            openService: () async {
              if (failing) throw StateError('handoff');
              return mock;
            },
          ),
        );
        addTearDown(container.dispose);
        // The field report's state: the KeyPackage and Profile lists were read
        // while the manager could not be opened, and cached that failure; the
        // manager came back and the Inbox list, read after, loaded.
        await expectLater(
          container.read(keyPackageRelaysProvider.future),
          throwsA(anything),
        );
        await expectLater(
          container.read(profileRelaysProvider.future),
          throwsA(anything),
        );
        failing = false;
        container.invalidate(relayPreferencesServiceProvider);
        await container.read(inboxRelaysProvider.future);

        await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: page),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Failed to load relays.'), findsNothing);
        expect(find.text('inbox.example.com'), findsOneWidget);
        expect(find.text('kp.example.com'), findsOneWidget);
        expect(find.text('profile.example.com'), findsOneWidget);

        // This container outlives the page; its own end stops the board
        // poll before the test's timer check.
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      },
    );

    testWidgets(
      'opening the page loads every list over a service that failed earlier, '
      'when the KeyPackage and Profile lists were never read',
      (tester) async {
        growSurface(tester);
        final mock = seededMock();
        var failing = true;
        final container = ProviderContainer(
          overrides: appOverrides(
            mock: mock,
            openService: () async {
              if (failing) throw StateError('handoff');
              return mock;
            },
          ),
        );
        addTearDown(container.dispose);
        // Only the Inbox list was read while the manager could not be opened;
        // the KeyPackage and Profile lists are first built by the page itself,
        // on its first frame, over the service's cached failure.
        await expectLater(
          container.read(inboxRelaysProvider.future),
          throwsA(anything),
        );
        await container.read(identityProvider.future);
        failing = false;

        await tester.pumpWidget(
          UncontrolledProviderScope(container: container, child: page),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Failed to load relays.'), findsNothing);
        expect(find.text('inbox.example.com'), findsOneWidget);
        expect(find.text('kp.example.com'), findsOneWidget);
        expect(find.text('profile.example.com'), findsOneWidget);

        // This container outlives the page; its own end stops the board
        // poll before the test's timer check.
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      },
    );

    testWidgets('Restore defaults still opens its confirmation', (
      tester,
    ) async {
      growSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          openService: () async => throw StateError('handoff'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Restore defaults').first);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Restore default relays?'), findsOneWidget);
    });
  });

  group('RelaySettingsPage — the page-open pass', () {
    Future<int> runsOnOpen(WidgetTester tester, OwnRelayBoard? board) async {
      var runs = 0;
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(board: board),
          extra: [
            keyPackagePublisherProvider.overrideWith((ref) async {
              runs++;
              return const KeyPackageMaintenanceFailed(
                KeyPackageFailureKind.tickErrored,
              );
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return runs;
    }

    OwnKindBoard checked(int secs) => OwnKindBoard(checkedSecsAgo: secs);

    testWidgets('runs a pass when no pass has finished in this session', (
      tester,
    ) async {
      expect(await runsOnOpen(tester, const OwnRelayBoard()), 1);
    });

    testWidgets('runs no pass while no session is open', (tester) async {
      expect(await runsOnOpen(tester, null), 0);
    });

    testWidgets('runs a pass when a kind was checked over ten minutes ago', (
      tester,
    ) async {
      expect(
        await runsOnOpen(
          tester,
          OwnRelayBoard(
            keyPackage: checked(30),
            relayList: checked(601),
            inboxRelayList: checked(30),
          ),
        ),
        1,
      );
    });

    testWidgets('runs no pass when every kind was checked within ten '
        'minutes', (tester) async {
      expect(
        await runsOnOpen(
          tester,
          OwnRelayBoard(
            keyPackage: checked(600),
            relayList: checked(30),
            inboxRelayList: checked(30),
          ),
        ),
        0,
      );
    });

    testWidgets('runs no pass while one is running or queued', (tester) async {
      expect(await runsOnOpen(tester, const OwnRelayBoard(running: true)), 0);
    });
  });

  group('RelaySettingsPage — status symbols', () {
    (IconData, Color) glyphOf(WidgetTester tester, Finder cell) {
      final icon = tester.widget<Icon>(
        find.descendant(of: cell, matching: find.byType(Icon)),
      );
      return (icon.icon!, icon.color!);
    }

    testWidgets('every state has its shape, colour, exact words and tooltip', (
      tester,
    ) async {
      tallSurface(tester);
      final semantics = tester.ensureSemantics();
      final scheme = ThemeData().colorScheme;
      final expected = <KindPresence, (IconData, Color)>{
        KindPresence.notChecked: (
          LucideIcons.circleDashed,
          scheme.onSurfaceVariant,
        ),
        KindPresence.checking: (
          LucideIcons.circleDashed,
          scheme.onSurfaceVariant,
        ),
        KindPresence.publishing: (
          LucideIcons.circleArrowUp,
          scheme.onSurfaceVariant,
        ),
        KindPresence.current: (
          LucideIcons.circleCheck,
          HavenSecurityColors.encrypted,
        ),
        KindPresence.missing: (LucideIcons.circleX, HavenSecurityColors.danger),
        KindPresence.outdated: (
          LucideIcons.circleX,
          HavenSecurityColors.danger,
        ),
        KindPresence.refused: (LucideIcons.circleX, HavenSecurityColors.danger),
        KindPresence.unconfirmed: (
          LucideIcons.circleX,
          HavenSecurityColors.danger,
        ),
        KindPresence.noAnswer: (
          Icons.question_mark,
          HavenSecurityColors.warning,
        ),
        KindPresence.held: (LucideIcons.circlePause, scheme.onSurfaceVariant),
      };
      // Spelled out, not read back from the page's own mapping: each word is
      // the state the legend and the board give it.
      final words = <KindPresence, String>{
        KindPresence.notChecked: l10n.relaySettingsStatusNotChecked,
        KindPresence.checking: l10n.relaySettingsStatusChecking,
        KindPresence.publishing: l10n.relaySettingsPresencePublishing,
        KindPresence.current: l10n.relaySettingsPresencePublished,
        KindPresence.missing: l10n.relaySettingsPresenceMissing,
        KindPresence.outdated: l10n.relaySettingsPresenceOutdated,
        KindPresence.refused: l10n.relaySettingsPresenceRefused,
        KindPresence.unconfirmed: l10n.relaySettingsPresenceUnconfirmed,
        KindPresence.noAnswer: l10n.relaySettingsPresenceNoAnswer,
        KindPresence.held: l10n.relaySettingsPresenceHeld,
      };
      expect(words.keys, unorderedEquals(KindPresence.values));
      expect(
        words.values.toSet(),
        hasLength(KindPresence.values.length),
        reason: 'every state is told apart in words',
      );
      for (final p in KindPresence.values) {
        expect(kindPresenceLabel(l10n, p), words[p], reason: '$p');
      }

      for (final p in KindPresence.values) {
        await tester.pumpWidget(
          buildApp(
            mock: seededMock(),
            board: FakeBoardSource(board: boardWithKeyPackage(p)),
            reduceMotion: true,
          ),
        );
        await tester.pumpAndSettle();

        final cell = cellIn('keyPackage', RelayKind.keyPackage);
        expect(tester.widget<RelayKindStatusCell>(cell).status, p);
        expect(glyphOf(tester, cell), expected[p], reason: '$p');
        expect(
          tester
              .widget<Tooltip>(
                find.descendant(of: cell, matching: find.byType(Tooltip)),
              )
              .message,
          words[p],
        );
        expect(
          tester.getSemantics(cell).label,
          contains(
            l10n.relaySettingsKindLine(
              l10n.relaySettingsKindKeyPackage,
              words[p]!,
            ),
          ),
          reason: '$p is said in words, never by colour alone',
        );
        await tester.pumpWidget(const SizedBox());
      }
      semantics.dispose();
    });

    testWidgets('one shape per meaning: red for every not-there state, a '
        'dashed circle for not checked and checking', (tester) async {
      tallSurface(tester);
      final shapes = <KindPresence, IconData>{};
      for (final p in KindPresence.values) {
        await tester.pumpWidget(
          buildApp(
            mock: seededMock(),
            board: FakeBoardSource(board: boardWithKeyPackage(p)),
            reduceMotion: true,
          ),
        );
        await tester.pumpAndSettle();
        shapes[p] = tester
            .widget<Icon>(
              find.descendant(
                of: cellIn('keyPackage', RelayKind.keyPackage),
                matching: find.byType(Icon),
              ),
            )
            .icon!;
        await tester.pumpWidget(const SizedBox());
      }
      final red = [
        KindPresence.missing,
        KindPresence.outdated,
        KindPresence.refused,
        KindPresence.unconfirmed,
      ];
      expect(red.map((p) => shapes[p]).toSet(), hasLength(1));
      expect(shapes[KindPresence.notChecked], shapes[KindPresence.checking]);
      expect(
        {
          shapes[KindPresence.checking],
          shapes[KindPresence.publishing],
          shapes[KindPresence.current],
          shapes[KindPresence.missing],
          shapes[KindPresence.noAnswer],
          shapes[KindPresence.held],
        },
        hasLength(6),
        reason: 'colour is never the only difference',
      );
    });

    testWidgets('the publishing ring turns inside its fixed box, and stands '
        'still under reduced motion', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(
        board: boardWithKeyPackage(KindPresence.publishing),
      );
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pump();
      await tester.pump();

      final cell = cellIn('keyPackage', RelayKind.keyPackage);
      final ring = find.descendant(
        of: cell,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(ring, findsOneWidget);
      expect(
        tester.getSize(
          find.descendant(of: cell, matching: find.byType(RelayStatusGlyph)),
        ),
        const Size.square(kRelayStatusGlyphBox),
      );
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'it turns');

      // Published: the ring is gone.
      board.board = boardWithKeyPackage(KindPresence.current);
      await tester.pump(const Duration(milliseconds: 500));
      expect(ring, findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(
            board: boardWithKeyPackage(KindPresence.publishing),
          ),
          reduceMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('publishing turns into published on its own', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(
        board: boardWithKeyPackage(KindPresence.publishing),
      );
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pump();
      await tester.pump();
      final cell = cellIn('keyPackage', RelayKind.keyPackage);
      expect(
        tester.widget<RelayKindStatusCell>(cell).status,
        KindPresence.publishing,
      );

      board.board = boardWithKeyPackage(KindPresence.current);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.widget<RelayKindStatusCell>(cell).status,
        KindPresence.current,
      );
    });

    testWidgets('a KeyPackage row stacks KeyPackage above Relay list at the '
        'end of the row, after the address, in either direction', (
      tester,
    ) async {
      tallSurface(tester);
      for (final locale in const [Locale('en'), Locale('ar')]) {
        await tester.pumpWidget(
          buildApp(
            mock: seededMock(),
            board: FakeBoardSource(board: boardAll(KindPresence.current)),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        final kp = tester.getRect(cellIn('keyPackage', RelayKind.keyPackage));
        final list = tester.getRect(cellIn('keyPackage', RelayKind.relayList));
        final address = tester.getRect(textIn('keyPackage', 'kp.example.com'));
        expect(kp.top, lessThan(list.top), reason: '$locale');
        if (locale.languageCode == 'ar') {
          expect(kp.right, lessThanOrEqualTo(address.left));
          expect(list.right, lessThanOrEqualTo(address.left));
        } else {
          expect(kp.left, greaterThanOrEqualTo(address.right));
          expect(list.left, greaterThanOrEqualTo(address.right));
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('each section shows only what that role needs', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(board: boardAll(KindPresence.current)),
        ),
      );
      await tester.pumpAndSettle();

      Set<RelayKind> kinds(String section) => {
        for (final e in cellsIn(section).evaluate())
          (e.widget as RelayKindStatusCell).kind,
      };
      expect(kinds('inbox'), {RelayKind.inboxRelayList});
      expect(kinds('keyPackage'), {RelayKind.keyPackage, RelayKind.relayList});
      expect(kinds('profile'), isEmpty);
      expect(
        kinds('lookup'),
        {RelayKind.relayList, RelayKind.inboxRelayList},
        reason: 'a lookup relay is never a KeyPackage destination',
      );
      expect(
        cellsIn('lookup'),
        findsNWidgets(fallbackDiscoveryRelays.length * 2),
      );
    });

    testWidgets('a row reads as one sentence; the remove button is its own '
        'control, and no symbol is read alone', (tester) async {
      tallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(
            board: boardWithKeyPackage(KindPresence.refused),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final label = tester
          .getSemantics(textIn('keyPackage', 'kp.example.com'))
          .label;
      final kpLine = l10n.relaySettingsKindLine(
        l10n.relaySettingsKindKeyPackage,
        l10n.relaySettingsPresenceRefused,
      );
      final listLine = l10n.relaySettingsKindLine(
        l10n.relaySettingsKindRelayList,
        l10n.relaySettingsPresencePublished,
      );
      expect(label, contains('kp.example.com'));
      expect(label.indexOf(kpLine), greaterThan(label.indexOf('kp.example')));
      expect(label.indexOf(listLine), greaterThan(label.indexOf(kpLine)));
      expect(
        tester.getSemantics(find.byTooltip('Remove kp.example.com')).label,
        isNot(contains(kpLine)),
      );
      expect(
        find.bySemanticsLabel(l10n.relaySettingsPresenceRefused),
        findsNothing,
      );
      semantics.dispose();
    });

    testWidgets('no symbol leads the row: the address comes first', (
      tester,
    ) async {
      tallSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(board: boardAll(KindPresence.missing)),
        ),
      );
      await tester.pumpAndSettle();

      for (final (section, host) in const [
        ('inbox', 'inbox.example.com'),
        ('keyPackage', 'kp.example.com'),
      ]) {
        final address = tester.getRect(textIn(section, host));
        final row = find.ancestor(
          of: textIn(section, host),
          matching: find.byType(ConstrainedBox),
        );
        final icons = find
            .descendant(of: row.first, matching: find.byType(Icon))
            .evaluate();
        expect(icons, isNotEmpty);
        for (final icon in icons) {
          final box = icon.renderObject! as RenderBox;
          expect(
            box.localToGlobal(Offset.zero).dx,
            greaterThanOrEqualTo(address.right),
          );
        }
      }
    });

    testWidgets('a tap on a symbol shows its exact state', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(
            board: boardWithKeyPackage(KindPresence.unconfirmed),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.relaySettingsPresenceUnconfirmed), findsNothing);

      await tester.tap(
        find.descendant(
          of: cellIn('keyPackage', RelayKind.keyPackage),
          matching: find.byType(RelayStatusGlyph),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(l10n.relaySettingsPresenceUnconfirmed), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });

    testWidgets('the page renders whole on its first frame, before the board '
        'answers anything', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      var frames = 0;
      while (find.text('My Inbox Relays').evaluate().isEmpty && frames < 10) {
        await tester.pump();
        frames++;
      }

      expect(find.text('inbox.example.com'), findsOneWidget);
      expect(find.text('kp.example.com'), findsOneWidget);
      expect(
        cellsIn('lookup'),
        findsNWidgets(fallbackDiscoveryRelays.length * 2),
      );
      for (final e in find.byType(RelayKindStatusCell).evaluate()) {
        expect(
          (e.widget as RelayKindStatusCell).status,
          KindPresence.notChecked,
          reason: 'nothing read is nothing known: never a fabricated answer',
        );
      }
    });

    testWidgets('a state change never moves the row or its remove button', (
      tester,
    ) async {
      tallSurface(tester);
      final board = FakeBoardSource(board: boardAll(KindPresence.notChecked));
      await tester.pumpWidget(
        buildApp(mock: seededMock(), board: board, reduceMotion: true),
      );
      await tester.pumpAndSettle();
      final remove = find.byTooltip('Remove kp.example.com');
      final address = textIn('keyPackage', 'kp.example.com');
      final removeAt = tester.getRect(remove);
      final addressAt = tester.getRect(address);

      for (final p in KindPresence.values) {
        board.board = boardAll(p);
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.getRect(remove), removeAt, reason: '$p');
        expect(tester.getRect(address), addressAt, reason: '$p');
      }
    });

    test('coloured symbols keep 3:1 against the card in light and dark', () {
      for (final theme in [HavenTheme.light(), HavenTheme.dark()]) {
        for (final colour in const [
          HavenSecurityColors.encrypted,
          HavenSecurityColors.danger,
          HavenSecurityColors.warning,
        ]) {
          expect(
            _contrast(colour, theme.cardTheme.color!),
            greaterThanOrEqualTo(3),
            reason: '$colour on ${theme.brightness}',
          );
        }
        expect(
          _contrast(theme.colorScheme.onSurfaceVariant, theme.cardTheme.color!),
          greaterThanOrEqualTo(3),
        );
      }
    });

    testWidgets('a long address wraps instead of being cut', (tester) async {
      tallSurface(tester, size: const Size(360, 3200));
      const host =
          'a-very-long-relay-host-name-that-keeps-going.example-relays.org';
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: ['wss://$host'],
          RelayCategory.keyPackage: [_kp],
        },
      );
      await tester.pumpWidget(buildApp(mock: mock));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text(host));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNull);
      expect(
        tester.getSize(find.text(host)).height,
        greaterThan(tester.getSize(find.text('kp.example.com')).height * 1.5),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('RelaySettingsPage — hold notes', () {
    testWidgets('while the reset notice is unanswered the note says why from '
        'the first frame, below every list the user edits', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(board: boardAll(KindPresence.held)),
        ),
      );
      var frames = 0;
      while (find.text('My Inbox Relays').evaluate().isEmpty && frames < 10) {
        await tester.pump();
        frames++;
      }
      expect(
        find.byKey(WidgetKeys.relaySettingsHeldNote),
        findsOneWidget,
        reason: 'there in the frame the lists first appear, never later',
      );
      expect(find.text(l10n.relaySettingsPublishingHeld), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(WidgetKeys.relaySettingsHeldNote)).top,
        greaterThan(
          tester
              .getRect(find.byKey(WidgetKeys.relaySettingsAddRelay('profile')))
              .bottom,
        ),
      );
      expect(
        tester
            .widget<RelayKindStatusCell>(
              cellIn('keyPackage', RelayKind.keyPackage),
            )
            .status,
        KindPresence.held,
      );
    });

    testWidgets('each hold has its own note, and none shows without one', (
      tester,
    ) async {
      tallSurface(tester);
      for (final (hold, text) in [
        (OwnPublishHold.noRelaysConfigured, l10n.relaySettingsHeldNoRelays),
        (
          OwnPublishHold.publishingSuppressed,
          l10n.relaySettingsHeldNotYetPublished,
        ),
      ]) {
        await tester.pumpWidget(
          buildApp(
            mock: seededMock(),
            board: FakeBoardSource(
              board: OwnRelayBoard(keyPackage: OwnKindBoard(hold: hold)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget, reason: '$hold');
        await tester.pumpWidget(const SizedBox());
      }

      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(board: boardAll(KindPresence.current)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(WidgetKeys.relaySettingsHeldNote), findsNothing);
    });

    testWidgets('both lists empty show the no-relays note once', (
      tester,
    ) async {
      tallSurface(tester);
      const empty = OwnKindBoard(hold: OwnPublishHold.noRelaysConfigured);
      await tester.pumpWidget(
        buildApp(
          mock: seededMock(),
          board: FakeBoardSource(
            board: const OwnRelayBoard(
              keyPackage: empty,
              relayList: empty,
              inboxRelayList: empty,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.relaySettingsHeldNoRelays), findsOneWidget);
    });
  });

  group('RelaySettingsPage — input while something moves', () {
    testWidgets('a status change landing mid-tap does not cancel the remove', (
      tester,
    ) async {
      tallSurface(tester);
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: [
            'wss://keep.example.com',
            'wss://drop.example.com',
          ],
          RelayCategory.keyPackage: [_kp],
        },
      );
      final board = FakeBoardSource(board: const OwnRelayBoard());
      await tester.pumpWidget(
        buildApp(
          mock: mock,
          board: board,
          // A read lands well inside a tap, never as long as a long press.
          extra: [
            relayBoardPollIntervalProvider.overrideWithValue(
              const Duration(milliseconds: 100),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Remove drop.example.com')),
      );
      board.board = const OwnRelayBoard(
        inboxRelayList: OwnKindBoard(
          cells: [
            OwnRelayCell(
              relayUrl: 'wss://drop.example.com',
              status: OwnRelayStatus.checking,
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<RelayKindStatusCell>(
              cellIn(
                'inbox',
                RelayKind.inboxRelayList,
                url: 'wss://drop.example.com',
              ),
            )
            .status,
        KindPresence.checking,
        reason: 'premise: the row changed under the finger',
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(mock.log, contains('remove:inbox:wss://drop.example.com'));
      expect(find.text('drop.example.com'), findsNothing);
    });

    testWidgets('a hold note that appears mid-tap moves no control and does '
        'not cancel the remove', (tester) async {
      tallSurface(tester);
      final mock = seededMock();
      final board = FakeBoardSource(board: boardAll(KindPresence.current));
      await tester.pumpWidget(
        buildApp(
          mock: mock,
          board: board,
          extra: [
            relayBoardPollIntervalProvider.overrideWithValue(
              const Duration(milliseconds: 100),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final remove = find.byTooltip('Remove profile.example.com');
      final before = tester.getRect(remove);

      final gesture = await tester.startGesture(tester.getCenter(remove));
      board.board = boardAll(KindPresence.held);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(WidgetKeys.relaySettingsHeldNote),
        findsOneWidget,
        reason: 'premise: the note appeared under the finger',
      );
      expect(tester.getRect(remove), before);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(mock.log, contains('remove:profile:wss://profile.example.com'));
    });

    testWidgets('a relay added while a symbol is publishing appears at once, '
        'not checked yet', (tester) async {
      tallSurface(tester);
      final mock = seededMock();
      await tester.pumpWidget(
        buildApp(
          mock: mock,
          board: FakeBoardSource(
            board: boardWithKeyPackage(KindPresence.publishing),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'wss://added.example.com'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(WidgetKeys.relaySettingsAddRelay('inbox')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('Paste from clipboard'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(mock.log, contains('add:inbox:wss://added.example.com'));
      expect(textIn('inbox', 'added.example.com'), findsOneWidget);
      expect(
        tester
            .widget<RelayKindStatusCell>(
              cellIn(
                'inbox',
                RelayKind.inboxRelayList,
                url: 'wss://added.example.com',
              ),
            )
            .status,
        KindPresence.notChecked,
      );
    });
  });

  group('RelaySettingsPage — announcements', () {
    OwnRelayBoard running(OwnRelayBoard board, {bool running = true}) =>
        OwnRelayBoard(
          running: running,
          lookupRelays: board.lookupRelays,
          keyPackage: board.keyPackage,
          relayList: board.relayList,
          inboxRelayList: board.inboxRelayList,
        );

    /// Every item current, plus the inbox item of `added.example.com` in
    /// [status] (absent, so not checked, when `null`).
    OwnRelayBoard withAdded(OwnRelayStatus? status, {bool running = false}) {
      final base = boardAll(KindPresence.current);
      return OwnRelayBoard(
        running: running,
        lookupRelays: base.lookupRelays,
        keyPackage: base.keyPackage,
        relayList: base.relayList,
        inboxRelayList: OwnKindBoard(
          cells: [
            ...base.inboxRelayList.cells,
            if (status != null)
              OwnRelayCell(relayUrl: 'wss://added.example.com', status: status),
          ],
        ),
      );
    }

    /// Adds `wss://added.example.com` to the Inbox list through the sheet,
    /// on a board with nothing moving, and clears what was said meanwhile.
    Future<void> addInboxRelay(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'wss://added.example.com'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(WidgetKeys.relaySettingsAddRelay('inbox')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Paste from clipboard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(textIn('inbox', 'added.example.com'), findsOneWidget);
      tester.takeAnnouncements();
    }

    testWidgets('one announcement when a pass settles, however many symbols '
        'changed on the way', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(board: boardAll(KindPresence.checking));
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pump();
      await tester.pump();
      tester.takeAnnouncements();

      board.board = boardAll(KindPresence.publishing);
      await tester.pump(const Duration(milliseconds: 500));
      board.board = boardAll(KindPresence.current);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeAnnouncements().map((a) => a.message), [
        l10n.relaySettingsCheckSettled(0),
      ]);
    });

    testWidgets('a pass with no symbol moving is not announced until the '
        'board says it ended, and then once', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(
        board: running(boardAll(KindPresence.checking)),
      );
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pump();
      await tester.pump();
      tester.takeAnnouncements();

      // Judged missing, the KeyPackage being made: nothing checks or
      // publishes, but the pass goes on.
      board.board = running(boardWithKeyPackage(KindPresence.missing));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.takeAnnouncements(),
        isEmpty,
        reason: 'the pass has not ended',
      );

      board.board = running(boardWithKeyPackage(KindPresence.publishing));
      await tester.pump(const Duration(milliseconds: 500));
      // Every item settled, the pass still winding up.
      board.board = running(boardAll(KindPresence.current));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeAnnouncements(), isEmpty);

      board.board = boardAll(KindPresence.current);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeAnnouncements().map((a) => a.message), [
        l10n.relaySettingsCheckSettled(0),
      ]);
    });

    testWidgets('the settled announcement counts the relays not confirmed up '
        'to date, and names none', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(
        board: boardWithKeyPackage(KindPresence.publishing),
      );
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pump();
      await tester.pump();
      tester.takeAnnouncements();

      board.board = boardWithKeyPackage(KindPresence.refused);
      await tester.pump(const Duration(milliseconds: 500));

      final said = tester.takeAnnouncements().map((a) => a.message).toList();
      expect(said, [l10n.relaySettingsCheckSettled(1)]);
      expect(said.single, isNot(contains('example')));
    });

    testWidgets('a relay the user just added is announced once its own '
        'check settles', (tester) async {
      tallSurface(tester);
      final mock = seededMock();
      final board = FakeBoardSource(board: boardAll(KindPresence.current));
      await tester.pumpWidget(buildApp(mock: mock, board: board));
      await tester.pumpAndSettle();
      await addInboxRelay(tester);

      board.board = withAdded(OwnRelayStatus.checking);
      await tester.pump(const Duration(milliseconds: 500));
      board.board = withAdded(OwnRelayStatus.current);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(l10n.relaySettingsAddedRelayUpToDate('added.example.com')),
      );
    });

    testWidgets('an added relay whose check ends between two reads is still '
        'announced, once, when the pass ends', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(board: boardAll(KindPresence.current));
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pumpAndSettle();
      await addInboxRelay(tester);

      // No read saw it checking: the wrong address failed at once. The other
      // kind's pass is still going.
      board.board = withAdded(OwnRelayStatus.noAnswer, running: true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeAnnouncements(), isEmpty);

      board.board = withAdded(OwnRelayStatus.noAnswer);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(l10n.relaySettingsAddedRelayNotUpToDate('added.example.com')),
      );

      // A later pass over it says nothing more of the added relay.
      board.board = withAdded(OwnRelayStatus.checking, running: true);
      await tester.pump(const Duration(milliseconds: 500));
      board.board = withAdded(OwnRelayStatus.current);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeAnnouncements().map((a) => a.message), [
        l10n.relaySettingsCheckSettled(0),
      ]);
    });

    testWidgets('a pass that ends without judging the added relay leaves it '
        'to the count, and no later pass names it', (tester) async {
      tallSurface(tester);
      final board = FakeBoardSource(board: boardAll(KindPresence.current));
      await tester.pumpWidget(buildApp(mock: seededMock(), board: board));
      await tester.pumpAndSettle();
      await addInboxRelay(tester);

      // The pass failed before it judged the added relay.
      board.board = withAdded(null, running: true);
      await tester.pump(const Duration(milliseconds: 500));
      board.board = withAdded(null);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeAnnouncements().map((a) => a.message), [
        l10n.relaySettingsCheckSettled(1),
      ]);

      board.board = withAdded(OwnRelayStatus.checking, running: true);
      await tester.pump(const Duration(milliseconds: 500));
      board.board = withAdded(OwnRelayStatus.current);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeAnnouncements().map((a) => a.message), [
        l10n.relaySettingsCheckSettled(0),
      ]);
    });
  });

  group('RelaySettingsPage — explanation panels', () {
    Future<void> openPanel(
      WidgetTester tester,
      RelaySettingsSection section,
    ) async {
      final button = find.byKey(
        WidgetKeys.relaySettingsInfoButton(section.name),
      );
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(button);
      await tester.pump();
      // The legend's publishing ring turns: never settle while it shows.
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> closePanel(WidgetTester tester) async {
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets("each section's question mark opens its explanation over the "
        'page, never as a page of its own', (tester) async {
      tallSurface(tester);
      final routes = _RouteLog();
      await tester.pumpWidget(
        buildApp(mock: seededMock(), observers: [routes]),
      );
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();

      for (final section in RelaySettingsSection.values) {
        final before = routes.pushed.length;
        await openPanel(tester, section);

        expect(routes.pushed, hasLength(before + 1));
        expect(routes.pushed.last, isA<ModalBottomSheetRoute<void>>());
        expect(find.byType(RelaySettingsPage), findsOneWidget);
        final heading = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(relaySectionTitle(l10n, section)),
        );
        expect(heading, findsOneWidget);
        expect(tester.getSemantics(heading), isSemantics(isHeader: true));
        await closePanel(tester);
      }
      semantics.dispose();
    });

    testWidgets('the panel never reaches past half the screen', (tester) async {
      for (final size in const [
        Size(360, 640),
        Size(412, 915),
        Size(800, 400),
      ]) {
        for (final scale in const [1.0, 2.0]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            buildApp(mock: seededMock(), textScaler: TextScaler.linear(scale)),
          );
          await tester.pumpAndSettle();
          for (final section in RelaySettingsSection.values) {
            await openPanel(tester, section);
            final sheet = tester.getRect(find.byType(BottomSheet));
            expect(
              sheet.height,
              lessThanOrEqualTo(size.height / 2),
              reason: '$size × $scale, $section',
            );
            expect(sheet.bottom, size.height);
            await closePanel(tester);
          }
          await tester.pumpWidget(const SizedBox());
        }
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    testWidgets('the whole explanation is reachable inside the panel at 200% '
        'text', (tester) async {
      tallSurface(tester, size: const Size(360, 640));
      await tester.pumpWidget(
        buildApp(mock: seededMock(), textScaler: const TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();

      for (final section in RelaySettingsSection.values) {
        await openPanel(tester, section);
        final scrollable = find.descendant(
          of: find.byKey(WidgetKeys.relaySettingsInfoSheet),
          matching: find.byType(Scrollable),
        );
        final last = section == RelaySettingsSection.profile
            ? find.byKey(WidgetKeys.relaySettingsInfoTechnical)
            : find.text(l10n.relaySettingsLegendHeld);
        final position = tester.state<ScrollableState>(scrollable).position;
        expect(
          position.maxScrollExtent,
          greaterThan(0),
          reason: 'premise: at 200% the explanation is taller than the panel',
        );
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        final sheet = tester.getRect(find.byType(BottomSheet));
        final target = tester.getRect(last);
        // Its end is in view inside the panel: nothing is out of reach.
        expect(target.bottom, greaterThan(sheet.top), reason: '$section');
        expect(target.bottom, lessThanOrEqualTo(sheet.bottom + 0.5));
        expect(tester.takeException(), isNull);
        await closePanel(tester);
      }
    });

    testWidgets('the question mark is a labelled 48 dp button just after its '
        'title, in either direction', (tester) async {
      tallSurface(tester);
      for (final locale in const [Locale('en'), Locale('ar')]) {
        final strings = lookupAppLocalizations(locale);
        await tester.pumpWidget(buildApp(mock: seededMock(), locale: locale));
        await tester.pumpAndSettle();
        for (final section in RelaySettingsSection.values) {
          final button = find.byKey(
            WidgetKeys.relaySettingsInfoButton(section.name),
          );
          final title = relaySectionTitle(strings, section);
          final size = tester.getSize(button);
          expect(size.width, greaterThanOrEqualTo(48));
          expect(size.height, greaterThanOrEqualTo(48));
          expect(
            tester.widget<IconButton>(button).tooltip,
            strings.relaySettingsInfoTooltip(title),
          );
          final titleRect = tester.getRect(
            find.descendant(
              of: find.byKey(WidgetKeys.relaySettingsSection(section.name)),
              matching: find.text(title),
            ),
          );
          final buttonRect = tester.getRect(button);
          if (locale.languageCode == 'ar') {
            expect(buttonRect.right, lessThanOrEqualTo(titleRect.left + 0.5));
          } else {
            expect(
              buttonRect.left,
              greaterThanOrEqualTo(titleRect.right - 0.5),
            );
          }
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a panel for a section with symbols explains each one with '
        "the rows' own glyph; the Profile panel has no legend", (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      for (final section in RelaySettingsSection.values) {
        await openPanel(tester, section);
        final legend = find.byKey(WidgetKeys.relaySettingsLegend);
        if (section == RelaySettingsSection.profile) {
          expect(legend, findsNothing);
        } else {
          final shown = {
            for (final e
                in find
                    .descendant(
                      of: legend,
                      matching: find.byType(RelayStatusGlyph),
                    )
                    .evaluate())
              (e.widget as RelayStatusGlyph).status,
          };
          expect(shown, {
            KindPresence.current,
            KindPresence.publishing,
            KindPresence.checking,
            KindPresence.missing,
            KindPresence.noAnswer,
            KindPresence.held,
          }, reason: 'one line per symbol a row can show');
          for (final (status, text) in [
            (KindPresence.current, l10n.relaySettingsLegendCurrent),
            (KindPresence.publishing, l10n.relaySettingsLegendPublishing),
            (KindPresence.checking, l10n.relaySettingsLegendChecking),
            (KindPresence.missing, l10n.relaySettingsLegendNotOnRelay),
            (KindPresence.noAnswer, l10n.relaySettingsLegendNoAnswer),
            (KindPresence.held, l10n.relaySettingsLegendHeld),
          ]) {
            final line = find.descendant(of: legend, matching: find.text(text));
            expect(line, findsOneWidget);
            final row = find.ancestor(of: line, matching: find.byType(Row));
            expect(
              tester
                  .widget<RelayStatusGlyph>(
                    find.descendant(
                      of: row.first,
                      matching: find.byType(RelayStatusGlyph),
                    ),
                  )
                  .status,
              status,
              reason: 'each line sits beside the symbol it explains: $text',
            );
          }
        }
        await closePanel(tester);
      }
    });

    testWidgets('no explanation is shown on the page until it is asked for', (
      tester,
    ) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      for (final paragraph in [
        l10n.relaySettingsInboxInfoWhat,
        l10n.relaySettingsKeyPackageInfoWhat,
        l10n.relaySettingsProfileInfoWhat,
        l10n.relaySettingsLookupInfoWhat,
        l10n.relaySettingsLegendTitle,
      ]) {
        expect(find.text(paragraph), findsNothing);
      }
    });

    testWidgets('a tap on the scrim while the panel is still opening closes '
        'it', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.relaySettingsInfoButton('inbox')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tapAt(const Offset(400, 20));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a tap on another question mark while a panel is closing '
        'opens that one', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();
      await openPanel(tester, RelaySettingsSection.inbox);

      await tester.tapAt(const Offset(400, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(
        find.byKey(WidgetKeys.relaySettingsInfoButton('keyPackage')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(l10n.relaySettingsKeyPackageTitle),
        ),
        findsOneWidget,
      );
    });
  });

  group('RelaySettingsPage — accessibility', () {
    OwnRelayBoard mixed() => OwnRelayBoard(
      lookupRelays: fallbackDiscoveryRelays,
      keyPackage: const OwnKindBoard(
        cells: [OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.publishing)],
      ),
      relayList: OwnKindBoard(
        cells: [
          const OwnRelayCell(relayUrl: _kp, status: OwnRelayStatus.refused),
          for (final (i, url) in fallbackDiscoveryRelays.indexed)
            OwnRelayCell(
              relayUrl: url,
              status: OwnRelayStatus.values[i % OwnRelayStatus.values.length],
            ),
        ],
      ),
      inboxRelayList: const OwnKindBoard(
        hold: OwnPublishHold.awaitingResetAcknowledgement,
      ),
    );

    testWidgets('the page meets the tap-target, label and text-contrast '
        'guidelines in light and dark, with a panel open too', (tester) async {
      tallSurface(tester);
      final semantics = tester.ensureSemantics();
      final mock = MockRelayPreferencesService(
        initialRelays: const {
          RelayCategory.inbox: [_inbox],
          RelayCategory.keyPackage: [_kp],
          RelayCategory.profile: [_inbox, 'wss://profile.example.com'],
        },
      );
      for (final theme in [HavenTheme.light(), HavenTheme.dark()]) {
        await tester.pumpWidget(
          buildApp(
            mock: mock,
            board: FakeBoardSource(board: mixed()),
            theme: theme,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        Future<void> meetsAll() async {
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        }

        await meetsAll();
        await tester.tap(
          find.byKey(WidgetKeys.relaySettingsInfoButton('keyPackage')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await meetsAll();
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpWidget(const SizedBox());
      }
      semantics.dispose();
    });

    testWidgets('section titles are headings', (tester) async {
      tallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      for (final section in RelaySettingsSection.values) {
        expect(
          tester.getSemantics(
            textIn(section.name, relaySectionTitle(l10n, section)),
          ),
          isSemantics(isHeader: true),
        );
      }
      semantics.dispose();
    });

    testWidgets('the legend title in a panel is a heading', (tester) async {
      tallSurface(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WidgetKeys.relaySettingsInfoButton('inbox')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.getSemantics(find.text(l10n.relaySettingsLegendTitle)),
        isSemantics(isHeader: true),
      );
      semantics.dispose();
    });

    testWidgets('200% text on a 320 dp phone: nothing overflows, in any '
        'state', (tester) async {
      tallSurface(tester, size: const Size(320, 6000));
      for (final p in KindPresence.values) {
        await tester.pumpWidget(
          buildApp(
            mock: MockRelayPreferencesService(
              initialRelays: const {
                RelayCategory.inbox: [
                  _inbox,
                  'wss://a-rather-long-relay-address.example-operator.net/x',
                ],
                RelayCategory.keyPackage: [_kp],
              },
            ),
            board: FakeBoardSource(board: boardAll(p)),
            textScaler: const TextScaler.linear(2),
            reduceMotion: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$p');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Arabic: addresses keep their spelling, aligned to the start '
        'of the row', (tester) async {
      tallSurface(tester);
      await tester.pumpWidget(
        buildApp(
          mock: MockRelayPreferencesService(
            initialRelays: const {
              RelayCategory.inbox: ['wss://relay.example.com/x'],
              RelayCategory.keyPackage: [_kp],
            },
          ),
          locale: const Locale('ar'),
        ),
      );
      await tester.pumpAndSettle();

      final address = textIn('inbox', 'relay.example.com/x');
      expect(address, findsOneWidget);
      expect(tester.widget<Text>(address).textDirection, TextDirection.ltr);
      final cell = tester.getRect(cellIn('inbox', RelayKind.inboxRelayList));
      expect(cell.right, lessThanOrEqualTo(tester.getRect(address).left));
    });
  });
}
