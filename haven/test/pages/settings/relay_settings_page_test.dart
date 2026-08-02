/// Widget tests for the editable [`RelaySettingsPage`].
///
/// The page underwent a full rewrite from a read-only status view into
/// an editable multi-section UI; the prior test suite was dropped because
/// it asserted layout details that no longer exist. Tests here cover
/// the surface that matters for v1: section presence, edit affordances,
/// the privacy callouts, the publish toggles, and (for the local-only
/// Profile category) the advisory contamination warning.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/pages/settings/relay_settings_page.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/legacy_retraction_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';
import 'package:haven/src/widgets/common/refresh_ring/refresh_ring_button.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_relay_preferences_service.dart';
import '../../mocks/mock_relay_service.dart';

Identity _stubIdentity() => Identity(
  pubkeyHex: '0' * 64,
  npub: 'npub1stub',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildApp({
    required MockRelayPreferencesService mock,
    Identity? identity,
  }) {
    return ProviderScope(
      overrides: [
        identityProvider.overrideWith(
          (ref) async => identity ?? _stubIdentity(),
        ),
        relayPreferencesServiceProvider.overrideWith((ref) async => mock),
        // disconnect_relay routes through RelayService now; tests don't
        // exercise the persistent FFI client, but the page still calls
        // it on remove and would otherwise hit production NostrRelayService.
        relayServiceProvider.overrideWithValue(MockRelayService()),
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
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RelaySettingsPage(),
      ),
    );
  }

  MockRelayPreferencesService seededMock() => MockRelayPreferencesService(
    initialRelays: const {
      RelayCategory.inbox: ['wss://inbox.example.com'],
      RelayCategory.keyPackage: ['wss://kp.example.com'],
      RelayCategory.profile: ['wss://profile.example.com'],
    },
  );

  group('RelaySettingsPage', () {
    testWidgets('renders three relay sections', (tester) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      expect(find.text('My Inbox Relays'), findsOneWidget);
      expect(find.text('My KeyPackage Relays'), findsOneWidget);
      expect(find.text('My Profile Relays'), findsOneWidget);
      expect(find.text('inbox.example.com'), findsOneWidget);
      expect(find.text('kp.example.com'), findsOneWidget);
      expect(find.text('profile.example.com'), findsOneWidget);
    });

    testWidgets('uses the refresh ring, not a spinner', (tester) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // The segmented ring replaces the former IconButton/CircularProgress
      // swap; the app bar must never show a spinner while checking.
      expect(find.byType(RefreshRingButton), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
    });

    testWidgets('shows a short caption linking to the Privacy topic', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      // Enough framing survives to make the section headers meaningful...
      final caption = find.textContaining('no server of its own');
      await tester.scrollUntilVisible(caption, 300);
      expect(caption, findsOneWidget);

      // ...but the 450-word explainer moved to Privacy ▸ Relays. Keeping a
      // second copy here is what let the two drift apart before.
      expect(find.text('How this works'), findsNothing);
      expect(find.textContaining('forward secrecy'), findsNothing);
      expect(find.textContaining('are your mailbox'), findsNothing);
    });

    testWidgets('the caption Learn more opens Privacy ▸ Relays', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(mock: seededMock()));
      await tester.pumpAndSettle();

      final learnMore = find.text('Learn more');
      await tester.scrollUntilVisible(learnMore, 300);
      await tester.tap(learnMore);
      await tester.pumpAndSettle();

      final page = tester.widget<PrivacyTopicPage>(
        find.byType(PrivacyTopicPage),
      );
      expect(page.topic, PrivacyTopic.relays);
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
    // DM-4c: the legacy-retraction "pending" note (plan §6 F10b).
    // -------------------------------------------------------------------

    testWidgets(
      'shows the legacy-retraction pending note when the tick has not '
      'completed yet',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((ref) async => _stubIdentity()),
              relayPreferencesServiceProvider.overrideWith(
                (ref) async => seededMock(),
              ),
              relayServiceProvider.overrideWithValue(MockRelayService()),
              circleServiceProvider.overrideWithValue(MockCircleService()),
              legacyRetractionProvider.overrideWith(
                (ref) async => LegacyRetractionUiStatus.pending,
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

        // The note now sits below three sections instead of two, so it can
        // fall outside the default test-viewport + cache-extent window and
        // never get inflated into the element tree until scrolled to (same
        // reason the caption/Learn-more checks below already scroll first).
        final note = find.textContaining('still asking relays to drop');
        await tester.scrollUntilVisible(note, 300);
        expect(note, findsOneWidget);
      },
    );

    testWidgets(
      'hides the legacy-retraction pending note once the tick has '
      'completed',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((ref) async => _stubIdentity()),
              relayPreferencesServiceProvider.overrideWith(
                (ref) async => seededMock(),
              ),
              relayServiceProvider.overrideWithValue(MockRelayService()),
              circleServiceProvider.overrideWithValue(MockCircleService()),
              legacyRetractionProvider.overrideWith(
                (ref) async => LegacyRetractionUiStatus.done,
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
          find.textContaining('still asking relays to drop'),
          findsNothing,
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
              relayPreferencesServiceProvider.overrideWith(
                (ref) async => mock,
              ),
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
          reason: 'non-vacuity: an empty discovery plane would make the '
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

    testWidgets(
      'shows the profile-pool-underflow banner when the pool has '
      'underflowed',
      (tester) async {
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
      },
    );

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
}
