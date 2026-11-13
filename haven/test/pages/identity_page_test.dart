/// Tests for IdentityPage.
///
/// The substantive widget-level tests for the photo header, display-name
/// card, and QR page live in their own files; this file keeps the cheap
/// `NpubQrCode` value checks plus a smoke test that locks the consolidated
/// Identity-page structure (photo header, the combined public-profile
/// disclosure notice, display name, and the QR / Photo-sharing / Advanced
/// subpage entries). Publishing is public-by-default and unconditional
/// (owner-directed 2026-07-16) — there is no Public Profile toggle to test.
///
/// It also holds the page-level proof that the Identity page claims only
/// what the device holds: it renders and announces the same in every publish
/// state (clean, waiting, due, unreadable, mid-sync).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/identity_page.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:haven/src/widgets/identity/identity_photo_header.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';
import 'package:haven/src/widgets/identity/reachability_status_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/accessibility_announcements.dart';
import '../mocks/mock_profile_service.dart';

class _FakeIdentityService implements IdentityService {
  static final _identity = Identity(
    pubkeyHex:
        'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
    npub: 'npub1testtest0001',
    createdAt: DateTime(2024),
  );

  @override
  Future<bool> hasIdentity() async => true;

  @override
  Future<Identity?> getIdentity() async => _identity;

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<String> getPubkeyHex() async => _identity.pubkeyHex;

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() async {}

  @override
  Future<String?> getDisplayName() async => 'Alice';

  @override
  Future<void> setDisplayName(String? name) async {}

  @override
  Future<void> clearCache() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('IdentityPage support types', () {
    testWidgets('NpubQrCode encodes nostr: URI prefix', (tester) async {
      const npub =
          'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5tr';
      const widget = NpubQrCode(npub: npub);
      expect(widget.qrData, equals('nostr:$npub'));
    });

    testWidgets('NpubQrSize enum has expected dimensions', (tester) async {
      expect(NpubQrSize.small.dimension, 150);
      expect(NpubQrSize.medium.dimension, 200);
      expect(NpubQrSize.large.dimension, 280);
    });
  });

  group('IdentityPage structure', () {
    Widget build({
      MockProfileService? profileService,
      List<Override> extraOverrides = const [],
    }) => ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(_FakeIdentityService()),
        // No profile/avatar set — the header shows initials and hides
        // Remove.
        profileServiceProvider.overrideWithValue(
          profileService ?? MockProfileService(),
        ),
        ...extraOverrides,
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: IdentityPage(),
      ),
    );

    testWidgets('renders the photo header and display-name card', (
      tester,
    ) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.byType(IdentityPhotoHeader), findsOneWidget);
      expect(find.byType(DisplayNameCard), findsOneWidget);
    });

    testWidgets(
      'shows the combined public-profile disclosure notice',
      (tester) async {
        await tester.pumpWidget(build());
        await tester.pumpAndSettle();

        expect(find.byType(PublicProfileNotice), findsOneWidget);
        expect(find.text('Profile is public'), findsOneWidget);
      },
    );

    testWidgets(
      'never shows a Public Profile toggle — publishing is unconditional',
      (tester) async {
        await tester.pumpWidget(build());
        await tester.pumpAndSettle();

        expect(find.byType(SwitchListTile), findsNothing);
        expect(find.text('Public Profile'), findsNothing);
      },
    );

    testWidgets('lists the Public Key QR and Advanced entries', (
      tester,
    ) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.text('Public Key QR'), findsOneWidget);
      expect(
        find.text('Photo sharing'),
        findsNothing,
        reason: 'photo-sharing settings were removed',
      );
      expect(find.text('Advanced'), findsOneWidget);
    });

    testWidgets('the Public Key QR entry says whether others can invite you', (
      tester,
    ) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Public Key QR'),
            matching: find.byType(Card),
          ),
          matching: find.byType(ReachabilityStatusRow),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the refresh action in the app bar', (tester) async {
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.identityRefreshButton), findsOneWidget);
    });
  });

  group('IdentityPage — photo header', () {
    Widget build({required MockProfileService profileService}) => ProviderScope(
      overrides: [
        identityServiceProvider.overrideWithValue(_FakeIdentityService()),
        profileServiceProvider.overrideWithValue(profileService),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: IdentityPage(),
      ),
    );

    testWidgets(
      'the photo header being busy (removing) disables the picker actions',
      (tester) async {
        final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
        final gate = Completer<void>();
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: _FakeIdentityService._identity.pubkeyHex,
            pictureBytes: jpegHeader,
            pictureHash: 'mock-hash',
          ),
        )..removeOwnAvatarGate = gate;

        await tester.pumpWidget(build(profileService: svc));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(TextButton, 'Remove'),
          ),
        );
        await tester.pump();

        // Removal is in flight (gated) — the photo header is busy.
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Edit Photo'),
              )
              .onPressed,
          isNull,
          reason: '_busy must disable the picker actions while removing',
        );

        gate.complete();
        await tester.pumpAndSettle();
      },
    );
  });

  group('IdentityPage — publish state is never rendered', () {
    Widget build(MockProfileService profileService) => ProviderScope(
      key: UniqueKey(),
      overrides: [
        identityServiceProvider.overrideWithValue(_FakeIdentityService()),
        profileServiceProvider.overrideWithValue(profileService),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: IdentityPage(),
      ),
    );

    /// What each semantics node SHOWS, in traversal order. Node ids are left
    /// out on purpose: they change between pumps.
    List<String> semanticsOf(WidgetTester tester) {
      final out = <String>[];
      void walk(SemanticsNode node) {
        final data = node.getSemanticsData();
        out.add(
          '${data.label}|${data.value}|${data.hint}|'
          '${data.flagsCollection.toStrings()}|${data.actions}',
        );
        node
            .debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)
            .forEach(walk);
      }

      final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
      walk(owner.rootSemanticsNode!);
      return out;
    }

    /// Everything the page puts on screen that a publish state could change:
    /// text, icons and progress indicators.
    List<String> visibleOf(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        'text:${t.data ?? t.textSpan?.toPlainText()}',
      for (final i in tester.widgetList<Icon>(find.byType(Icon)))
        'icon:${i.icon?.fontFamily}:${i.icon?.codePoint}',
      'circular:${find.byType(CircularProgressIndicator).evaluate().length}',
      'linear:${find.byType(LinearProgressIndicator).evaluate().length}',
    ];

    testWidgets(
      'the Identity page renders identically in every publish state',
      (tester) async {
        final semanticsHandle = tester.ensureSemantics();

        // Each arm asks the controller about the state it is in, exactly as
        // a cold start or resume would, so the state is read, not ignored.
        final states = <String, ProfilePendingState?>{
          'clean': const ProfilePendingState(pending: false, retryDue: false),
          'pending, not due': const ProfilePendingState(
            pending: true,
            retryDue: false,
            nextRetryInSecs: 120,
          ),
          'pending, due': const ProfilePendingState(
            pending: true,
            retryDue: true,
          ),
          'unreadable (fails closed)': const ProfilePendingState(
            pending: true,
            retryDue: false,
          ),
          // A sync running right now: the state the old status line
          // rendered as "Syncing…".
          'sync in flight': null,
        };

        final visible = <String, List<String>>{};
        final semantics = <String, List<String>>{};
        for (final MapEntry(key: name, value: pendingState) in states.entries) {
          // Set before mount so a surface reading the state at mount would
          // differ across arms.
          final svc = MockProfileService();
          if (pendingState != null) svc.nextPendingState = pendingState;
          final gate = Completer<void>();
          final announcements = captureAccessibilityAnnouncements(tester);
          await tester.pumpWidget(build(svc));
          await tester.pumpAndSettle();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(IdentityPage)),
          );
          final controller = container.read(ownProfileSyncProvider.notifier);

          if (pendingState == null) {
            svc.syncOwnProfileGate = gate;
            unawaited(controller.sync());
            await tester.pumpAndSettle();
            expect(
              svc.syncOwnProfileCalls,
              1,
              reason: 'anti-vacuity: $name has a sync held in flight',
            );
            expect(gate.isCompleted, isFalse);
          } else {
            await controller.retryIfPending();
            await tester.pumpAndSettle();
            expect(
              svc.pendingSyncStateCalls,
              greaterThanOrEqualTo(1),
              reason: 'anti-vacuity: the controller read the $name state',
            );
          }

          visible[name] = visibleOf(tester);
          semantics[name] = semanticsOf(tester);
          expect(
            tester
                .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Edit Photo'),
                )
                .onPressed,
            isNotNull,
            reason: 'a publish state ($name) must never disable picking a '
                'new photo',
          );

          if (!gate.isCompleted) gate.complete();
          await tester.pumpAndSettle();
          expect(
            announcements,
            isEmpty,
            reason: 'a publish state ($name), or a sync finishing, must '
                'never be spoken',
          );
          await tester.pumpWidget(const SizedBox());
        }

        final baseline = states.keys.first;
        expect(visible[baseline], contains('text:Profile is public'));
        expect(
          semantics[baseline]!.length,
          greaterThan(5),
          reason: 'anti-vacuity: the page has a semantics tree to compare',
        );
        for (final name in states.keys.skip(1)) {
          expect(
            visible[name],
            visible[baseline],
            reason: 'what the page shows differs between "$baseline" and '
                '"$name"',
          );
          expect(
            semantics[name],
            semantics[baseline],
            reason: 'what a screen reader hears differs between "$baseline" '
                'and "$name"',
          );
        }
        // Not addTearDown: that runs after the end-of-test handle check.
        semanticsHandle.dispose();
      },
    );
  });
}
