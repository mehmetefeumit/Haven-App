/// Widget tests for the invite picker's result list.
///
/// The promise under test is R1(cached)/R2/R4: open the invite screen and see
/// people you already share circles with, by name and face, filterable as you
/// type — with the npub always on screen beside the name, because a name is
/// attacker-chosen and this screen's output is live location sharing.
///
/// Every state the list can be in is rendered and asserted here; a state
/// without a test is a state nobody has looked at.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/member_avatar.dart';
import 'package:haven/src/widgets/circles/member_picker.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../mocks/mock_member_directory_service.dart';
import '../../mocks/mock_profile_service.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _aliceHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';
const _bobHex =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _bobNpub =
    'npub1kzcqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpkksrcdwkr';
const _carolHex =
    'ca401000000000000000000000000000000000000000000000000000000beef0';
const _carolNpub =
    'npub1efqpqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqtamcqhprsfg';
const _selfHex =
    '5e1f0000000000000000000000000000000000000000000000000000000000ff';
const _selfNpub =
    'npub1tc0sqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql7pytwqgs';

/// A complete, syntactically valid (per [NpubValidator]) npub for nobody in
/// [_threePeople] — the D2 typed-stranger fixture. `NpubValidator` checks
/// only the prefix, length and bech32 charset (no checksum), so this need
/// not be a genuine bech32-encoded key to reach the network-resolve path.
const _strangerNpub =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5';
const _strangerHex =
    'de1e00000000000000000000000000000000000000000000000000000000fac3';

/// A SECOND, distinct stranger npub — used only by the stale-in-flight test,
/// where the query changes from [_strangerNpub] to this one mid-resolve.
const _stranger2Npub =
    'npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxspcd5';

final _identity = Identity(
  pubkeyHex: _selfHex,
  npub: _selfNpub,
  createdAt: DateTime(2024),
);

/// A 1x1 PNG — enough for [HavenAvatar] to take the image branch.
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

DirectoryEntry _entry(
  String hex,
  String npub, {
  DirectoryTier tier = DirectoryTier.current,
}) => DirectoryEntry(pubkeyHex: hex, npub: npub, tier: tier);

/// Builds a directory from the given directory rows, folding names with a
/// plain lower-case: `RustLib` is not initialised in a `flutter test`
/// process, so the real bridge fold degrades — injecting the same fold both
/// sides keeps this suite about the LIST, not about Unicode.
MemberDirectory _directory(
  List<DirectoryEntry> entries, {
  Map<String, Profile> profiles = const {},
  Map<String, String> petnames = const {},
  Map<String, List<String>> circleNamesByPubkey = const {},
}) {
  return buildDirectory(
    entries: entries,
    profiles: profiles,
    petnames: petnames,
    circleNamesByPubkey: circleNamesByPubkey,
    fold: (value) => value.toLowerCase(),
  );
}

MemberDirectory _threePeople() => _directory(
  [
    _entry(_aliceHex, _aliceNpub),
    _entry(_bobHex, _bobNpub),
    _entry(_carolHex, _carolNpub),
  ],
  profiles: const {
    _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alice Aardvark'),
    _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Bob Badger'),
    _carolHex: Profile(pubkeyHex: _carolHex, displayName: 'Carol Coyote'),
  },
);

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Hosts the picker the way a page does — one CustomScrollView — and lets a
/// test drive the query without a text field in the way.
class _PickerHost extends StatefulWidget {
  const _PickerHost({
    this.stagedNpubs = const {},
    this.circleMemberPubkeysHex = const {},
    this.circleMemberNpubs = const {},
    this.onSelected,
    this.onStrangerSelected,
  });

  final Set<String> stagedNpubs;
  final Set<String> circleMemberPubkeysHex;
  final Set<String> circleMemberNpubs;
  final void Function(MemberCandidate)? onSelected;
  final void Function(String)? onStrangerSelected;

  @override
  State<_PickerHost> createState() => _PickerHostState();
}

class _PickerHostState extends State<_PickerHost> {
  String query = '';

  void type(String value) => setState(() => query = value);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: CustomScrollView(
          slivers: [
            MemberPickerResults(
              query: query,
              stagedNpubs: widget.stagedNpubs,
              circleMemberPubkeysHex: widget.circleMemberPubkeysHex,
              circleMemberNpubs: widget.circleMemberNpubs,
              onSelected: widget.onSelected ?? (_) {},
              onStrangerSelected: widget.onStrangerSelected ?? (_) {},
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required MockMemberDirectoryService directoryService,
  MockProfileService? profileService,
  Set<String> stagedNpubs = const {},
  Set<String> circleMemberPubkeysHex = const {},
  Set<String> circleMemberNpubs = const {},
  void Function(MemberCandidate)? onSelected,
  void Function(String)? onStrangerSelected,
  Identity? identity,
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        memberDirectoryServiceProvider.overrideWithValue(directoryService),
        profileServiceProvider.overrideWithValue(
          profileService ?? MockProfileService(),
        ),
        identityProvider.overrideWith((_) async => identity ?? _identity),
        circlesProvider.overrideWith((ref) => Future.value(const <Circle>[])),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: HavenTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: _PickerHost(
          stagedNpubs: stagedNpubs,
          circleMemberPubkeysHex: circleMemberPubkeysHex,
          circleMemberNpubs: circleMemberNpubs,
          onSelected: onSelected,
          onStrangerSelected: onStrangerSelected,
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String value) async {
  tester.state<_PickerHostState>(find.byType(_PickerHost)).type(value);
  await tester.pump();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(_PickerHost)));

String _short(String npub) => NpubValidator.shortenForDisplay(npub);

/// U+2068 FIRST STRONG ISOLATE / U+2069 POP DIRECTIONAL ISOLATE, matching
/// how the row wraps a remote-supplied collision circle name before it
/// shares a paragraph with app text (same convention as
/// `invitation_card_test.dart`'s `_isolated`).
String _isolated(String name) => '\u2068$name\u2069';

/// Every non-empty label in the compiled semantics tree — where Flutter's
/// node merging has already happened — rather than the widget tree.
List<String> _announcedLabels(WidgetTester tester) {
  final labels = <String>[];
  void walk(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return labels;
}

void main() {
  // -------------------------------------------------------------------------
  // Every state the list can be in
  // -------------------------------------------------------------------------
  group('MemberPickerResults — states', () {
    testWidgets('S1. while the directory is being read, says so and lists '
        'nobody', (tester) async {
      final service = MockMemberDirectoryService(directory: _threePeople())
        ..loadGate = Completer<void>();

      await _pumpPicker(
        tester,
        directoryService: service,
        settle: false,
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(MemberCandidateTile), findsNothing);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .semanticsLabel,
        _l10n(tester).memberPickerLoading,
      );

      service.loadGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(MemberCandidateTile), findsNWidgets(3));
    });

    testWidgets('S2. an empty query offers everyone, under a heading that '
        'claims only roster membership', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      final l10n = _l10n(tester);
      expect(find.text(l10n.memberPickerSectionRoster), findsOneWidget);
      expect(find.byType(MemberCandidateTile), findsNWidgets(3));
      expect(find.text('Alice Aardvark'), findsOneWidget);
      expect(find.text('Bob Badger'), findsOneWidget);
      expect(find.text('Carol Coyote'), findsOneWidget);
    });

    testWidgets('S3. a fresh install renders no list and no heading', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(),
      );

      expect(
        find.text(_l10n(tester).memberPickerSectionRoster),
        findsNothing,
      );
      expect(find.byType(MemberCandidateTile), findsNothing);
      expect(
        find.text(_l10n(tester).memberPickerNoMatches),
        findsNothing,
        reason:
            '"No matches" answers a query. Someone who shares no circles yet '
            'has not asked one — the page\'s own guidance is the answer.',
      );
    });

    testWidgets(
      'S42. a directory that fails to load renders a message '
      'distinguishable from both "no matches" and a fresh install\'s '
      'silence (plan F2)',
      (tester) async {
        final service = MockMemberDirectoryService()
          ..shouldThrowOnLoadDirectory = true;
        await _pumpPicker(tester, directoryService: service);

        final l10n = _l10n(tester);
        expect(
          find.text(l10n.memberPickerDirectoryUnavailable),
          findsOneWidget,
          reason: 'a failed read is not "you know nobody" — it must say so, '
              'not stay blank like S3\'s fresh install',
        );
        expect(find.text(l10n.memberPickerNoMatches), findsNothing);
        expect(find.byType(MemberCandidateTile), findsNothing);
      },
    );

    testWidgets('S4. typing narrows to the matches, in the same frame', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      // One pump, no clock advanced: a debounced filter would still be
      // showing all three.
      await _type(tester, 'badger');

      expect(find.byType(MemberCandidateTile), findsOneWidget);
      expect(find.text('Bob Badger'), findsOneWidget);
      expect(find.text('Alice Aardvark'), findsNothing);
    });

    testWidgets('S5. a query nobody matches says so and drops the heading', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      await _type(tester, 'zzzz');

      final l10n = _l10n(tester);
      expect(find.byType(MemberCandidateTile), findsNothing);
      expect(find.text(l10n.memberPickerNoMatches), findsOneWidget);
      expect(find.text(l10n.memberPickerSectionRoster), findsNothing);
    });

    testWidgets('S6. a complete npub that IS known resolves to that person', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      await _type(tester, _bobNpub);

      expect(find.byType(MemberCandidateTile), findsOneWidget);
      expect(find.text('Bob Badger'), findsOneWidget);
      expect(find.text(_short(_bobNpub)), findsOneWidget);
    });

    testWidgets(
      'S7. a complete npub that is NOT known locally is offered as a '
      'typed-stranger row, never as a MemberCandidateTile with a name '
      'nothing local vouched for (D2 — the network resolve itself is '
      'covered by its own group below)',
      (tester) async {
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
        );

        await _type(tester, _strangerNpub);
        await tester.pumpAndSettle();

        expect(find.byType(MemberCandidateTile), findsNothing);
        expect(find.text(_l10n(tester).memberPickerNoMatches), findsNothing);
        expect(find.text(_short(_strangerNpub)), findsOneWidget);
      },
    );

    testWidgets('S8. malformed input matches nobody and raises nothing', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      await _type(tester, 'npub1!!! not a key ###');

      expect(find.byType(MemberCandidateTile), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('S9. a partial key prefix never enumerates the directory', (
      tester,
    ) async {
      // Every npub starts `npub1`, so a plain prefix rule would return
      // everyone for "n" — keystroke one of "Nadia".
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      await _type(tester, 'npub1');

      expect(find.byType(MemberCandidateTile), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Who cannot be picked, and why
  // -------------------------------------------------------------------------
  group('MemberPickerResults — refusals', () {
    testWidgets('S10. someone already staged is shown, disabled, with the '
        'reason', (tester) async {
      var picked = 0;
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        stagedNpubs: const {_bobNpub},
        onSelected: (_) => picked++,
      );

      final l10n = _l10n(tester);
      // Shown, not hidden: hiding the person being searched for is worse
      // than showing why they cannot be picked.
      expect(find.text('Bob Badger'), findsOneWidget);
      expect(find.text(l10n.memberSearchAlreadyAdded), findsOneWidget);

      await tester.tap(find.text('Bob Badger'));
      await tester.pump();
      expect(picked, 0);
    });

    testWidgets('S11. someone already in the target circle is shown, '
        'disabled, with a DIFFERENT reason', (tester) async {
      var picked = 0;
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        circleMemberPubkeysHex: const {_carolHex},
        onSelected: (_) => picked++,
      );

      final l10n = _l10n(tester);
      expect(find.text('Carol Coyote'), findsOneWidget);
      expect(find.text(l10n.addMemberAlreadyInCircle), findsOneWidget);
      expect(find.text(l10n.memberSearchAlreadyAdded), findsNothing);

      await tester.tap(find.text('Carol Coyote'));
      await tester.pump();
      expect(picked, 0);
    });

    testWidgets('S12. the user is never offered themselves, even by a '
        'directory that hands them over', (tester) async {
      // The shipped directory excludes self. This pins the promise at the
      // RENDER layer, so it survives independently of the layer that builds
      // the list — the create-circle screen had no identity read at all.
      var picked = 0;
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_selfHex, _selfNpub), _entry(_aliceHex, _aliceNpub)],
            profiles: const {
              _selfHex: Profile(pubkeyHex: _selfHex, displayName: 'Me'),
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
            },
          ),
        ),
        onSelected: (_) => picked++,
      );

      final l10n = _l10n(tester);
      expect(find.text(l10n.memberPickerReasonSelf), findsOneWidget);

      await tester.tap(find.text('Me'));
      await tester.pump();
      expect(picked, 0);

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pump();
      expect(picked, 1);
    });

    testWidgets('S13. a pickable row hands back the whole candidate', (
      tester,
    ) async {
      final picks = <MemberCandidate>[];
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        onSelected: picks.add,
      );

      await tester.tap(find.text('Alice Aardvark'));
      await tester.pump();

      expect(picks.single.npub, _aliceNpub);
      expect(picks.single.pubkeyHex, _aliceHex);
    });
  });

  // -------------------------------------------------------------------------
  // What a row shows
  // -------------------------------------------------------------------------
  group('MemberCandidateTile — a row identifies a person', () {
    testWidgets('S14. a name never appears without the key beside it', (
      tester,
    ) async {
      // Names are attacker-chosen and this screen\'s output is live location
      // sharing, so a name-only row must not exist.
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      for (final npub in [_aliceNpub, _bobNpub, _carolNpub]) {
        expect(find.text(_short(npub)), findsOneWidget);
      }
    });

    testWidgets('S15. someone with no resolved name is identified by the key '
        'alone, not hidden', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory([_entry(_aliceHex, _aliceNpub)]),
        ),
      );

      expect(find.byType(MemberCandidateTile), findsOneWidget);
      expect(find.text(_short(_aliceNpub)), findsOneWidget);
    });

    testWidgets('S16. the key is never clipped', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      final npub = tester.widget<Text>(find.text(_short(_aliceNpub)));
      expect(
        npub.maxLines,
        isNull,
        reason:
            'clipping the tail drops the bech32 checksum, taking an '
            'impersonation from ~2^65 back to ~2^35',
      );
      expect(npub.overflow, isNull);
      expect(npub.textDirection, TextDirection.ltr);
    });

    testWidgets('S17. a local petname wins over the published name', (
      tester,
    ) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
            },
            petnames: const {_aliceHex: 'Mum'},
          ),
        ),
      );

      expect(find.text('Mum'), findsOneWidget);
      expect(find.text('Alice Aardvark'), findsNothing);
    });

    testWidgets('S18. a cached picture becomes the row\'s face', (
      tester,
    ) async {
      final profiles = MockProfileService(
        memberProfiles: {
          _aliceHex: Profile(
            pubkeyHex: _aliceHex,
            displayName: 'Alice Aardvark',
            pictureBytes: _pngBytes,
            pictureHash: 'hash',
          ),
        },
      );

      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
                pictureHash: 'hash',
              ),
            },
          ),
        ),
        profileService: profiles,
      );

      expect(find.byType(HavenAvatar), findsOneWidget);
      expect(
        profiles.methodCalls.where((c) => c.method == 'getMemberProfile'),
        isNotEmpty,
      );
    });

    testWidgets('S19. no picture falls back to a grapheme-safe initial, with '
        'no shimmer', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub)],
            petnames: const {_aliceHex: '🌸 Blossom'},
          ),
        ),
      );

      expect(find.byType(MemberAvatar), findsOneWidget);
      expect(find.byType(HavenAvatar), findsNothing);
      expect(
        find.text('🌸'),
        findsOneWidget,
        reason:
            'a shimmer where a face is about to appear tells a bystander a '
            'picture is incoming; the initial must be a whole grapheme',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Accessibility
  // -------------------------------------------------------------------------
  group('MemberPickerResults — accessibility', () {
    testWidgets('S20. every row repeats the tier, because a reader swiping '
        'row by row never hears the heading', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      final l10n = _l10n(tester);
      expect(
        find.bySemanticsLabel(
          RegExp('Alice Aardvark.*${RegExp.escape(l10n.memberPickerTierRoster)}'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('S21. a refused row carries its reason and is not a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        stagedNpubs: const {_bobNpub},
      );

      final l10n = _l10n(tester);
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Bob Badger.*')),
      );
      expect(node.label, contains(l10n.memberSearchAlreadyAdded));
      expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
      handle.dispose();
    });

    testWidgets('S22. the key is spoken by an action whose LABEL is a '
        'constant', (tester) async {
      // Flutter interns CustomSemanticsAction on (label, hint, action) in
      // static maps with no prune path, so a per-person label would keep
      // identifier text for the life of the process — outside SQLCipher and
      // unreachable by the logout wipe.
      final handle = tester.ensureSemantics();
      final announcements = captureAccessibilityAnnouncements(tester);
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      final l10n = _l10n(tester);
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Alice Aardvark.*')),
      );
      final actions = node.getSemanticsData().customSemanticsActionIds!;
      final labels = actions
          .map((id) => CustomSemanticsAction.getAction(id)!.label)
          .toList();

      expect(labels, contains(l10n.memberPickerReadPublicKey));
      for (final label in labels) {
        expect(
          label,
          isNot(contains('npub1')),
          reason: 'an npub in an action label is interned forever',
        );
      }

      final readId = actions.firstWhere(
        (id) =>
            CustomSemanticsAction.getAction(id)!.label ==
            l10n.memberPickerReadPublicKey,
      );
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.customAction,
        readId,
      );
      await tester.pumpAndSettle();

      expect(announcements, hasLength(1));
      expect(
        announcements.single.replaceAll(' ', ''),
        _short(_aliceNpub),
        reason: 'spoken in chunks, but the same characters',
      );
      handle.dispose();
    });

    testWidgets(
      'S43. the spoken key keeps its elision as its own audible unit, '
      'never fused to an adjacent checksum character (plan F5)',
      (tester) async {
        final handle = tester.ensureSemantics();
        final announcements = captureAccessibilityAnnouncements(tester);
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
        );

        final l10n = _l10n(tester);
        final node = tester.getSemantics(
          find.bySemanticsLabel(RegExp('Alice Aardvark.*')),
        );
        final actions = node.getSemanticsData().customSemanticsActionIds!;
        final readId = actions.firstWhere(
          (id) =>
              CustomSemanticsAction.getAction(id)!.label ==
              l10n.memberPickerReadPublicKey,
        );
        tester.binding.pipelineOwner.semanticsOwner!.performAction(
          node.id,
          SemanticsAction.customAction,
          readId,
        );
        await tester.pumpAndSettle();

        expect(announcements, hasLength(1));
        final tokens = announcements.single.split(' ');
        expect(
          tokens,
          contains('...'),
          reason: 'the elision must be its own token, so no TTS engine can '
              'drop it silently into an adjacent chunk',
        );
        for (final token in tokens) {
          expect(
            token == '...' || !token.contains('.'),
            isTrue,
            reason: 'no chunk may mix elision dots with real key '
                'characters: "$token"',
          );
        }
        // The existing round-trip promise (S22) must still hold.
        expect(
          announcements.single.replaceAll(' ', ''),
          _short(_aliceNpub),
        );
        handle.dispose();
      },
    );

    testWidgets('S23. a settled search is announced once, and only when the '
        'result set changed', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );
      final announcements = captureAccessibilityAnnouncements(tester);
      final l10n = _l10n(tester);

      await _type(tester, 'b');
      await _type(tester, 'ba');
      await _type(tester, 'bad');
      expect(
        announcements,
        isEmpty,
        reason: 'nothing is said mid-typing; visual filtering is already 0 ms',
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect(announcements, [l10n.memberPickerMatchesAnnouncement(1)]);

      // Another keystroke that does not change the result set says nothing.
      await _type(tester, 'badg');
      await tester.pump(const Duration(milliseconds: 400));
      expect(announcements, hasLength(1));
    });

    testWidgets('S24. zero results is announced exactly once', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );
      final announcements = captureAccessibilityAnnouncements(tester);
      final l10n = _l10n(tester);

      await _type(tester, 'zzz');
      await tester.pump(const Duration(milliseconds: 400));
      expect(announcements, [l10n.memberPickerNoMatches]);

      await _type(tester, 'zzzz');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        announcements,
        hasLength(1),
        reason: 'still nobody — repeating it is noise, not information',
      );
    });

    testWidgets('S25. opening the picker announces nothing', (tester) async {
      final service = MockMemberDirectoryService(directory: _threePeople())
        ..loadGate = Completer<void>();
      await _pumpPicker(
        tester,
        directoryService: service,
        settle: false,
      );
      final announcements = captureAccessibilityAnnouncements(tester);

      service.loadGate!.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        announcements,
        isEmpty,
        reason: 'a list appearing is not the answer to a question anyone asked',
      );
    });

    testWidgets(
      'S39. a query typed while the directory is still loading is not '
      'announced as "no matches" — the real answer follows once the '
      'directory settles, with no further keystroke (plan F1)',
      (tester) async {
        final service = MockMemberDirectoryService(directory: _threePeople())
          ..loadGate = Completer<void>();
        await _pumpPicker(tester, directoryService: service, settle: false);
        await tester.pump();
        final announcements = captureAccessibilityAnnouncements(tester);

        await _type(tester, 'badger');
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          announcements,
          isEmpty,
          reason: 'the on-device read has not finished — speech must not '
              'claim an answer the screen itself does not have yet',
        );

        service.loadGate!.complete();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));

        final l10n = _l10n(tester);
        expect(
          announcements,
          [l10n.memberPickerMatchesAnnouncement(1)],
          reason: 'the query never changed, so nothing but the directory '
              'settling could have re-armed this announcement',
        );
      },
    );

    testWidgets(
      'S40. typing on a fresh install (an empty directory) is never '
      'announced as "no matches" — matching the visible branch\'s silence '
      '(S3, plan F1)',
      (tester) async {
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(),
        );
        final announcements = captureAccessibilityAnnouncements(tester);

        await _type(tester, 'zzz');
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          announcements,
          isEmpty,
          reason: '"No matches" answers a query; someone who shares no '
              'circles yet has not asked one, on screen or in speech',
        );
      },
    );

    testWidgets(
      'S41. a directory that fails to load is announced as unavailable once '
      'a query is typed — never silently, and never as "no matches" (plan '
      'F2; closes the gap an independent reviewer found: `_announce` used '
      'to early-return on the null `valueOrNull` an error produces, leaving '
      'a screen-reader user who types a query and hits a read failure '
      'hearing nothing)',
      (tester) async {
        final service = MockMemberDirectoryService()
          ..shouldThrowOnLoadDirectory = true;
        await _pumpPicker(tester, directoryService: service);
        final announcements = captureAccessibilityAnnouncements(tester);
        final l10n = _l10n(tester);

        await _type(tester, 'zzz');
        await tester.pump(const Duration(milliseconds: 400));

        expect(announcements, [l10n.memberPickerDirectoryUnavailable]);

        // A further keystroke against the SAME (still-failed) directory
        // must not repeat it — the same de-dup contract S24 pins for "no
        // matches", now proven for this third spoken outcome too.
        await _type(tester, 'zzzz');
        await tester.pump(const Duration(milliseconds: 400));
        expect(announcements, hasLength(1));
      },
    );

    testWidgets(
      'S44. opening the picker straight into a failed directory read, with '
      'no query typed, announces nothing — an error appearing on open is '
      'not, by itself, the answer to a question anyone asked (mirrors S25)',
      (tester) async {
        final service = MockMemberDirectoryService()
          ..shouldThrowOnLoadDirectory = true
          ..loadGate = Completer<void>();
        await _pumpPicker(tester, directoryService: service, settle: false);
        final announcements = captureAccessibilityAnnouncements(tester);

        service.loadGate!.complete();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));

        expect(announcements, isEmpty);
      },
    );

    testWidgets(
      'S45. a query typed while the directory is still loading is not '
      'announced at all — the unavailable answer follows once the read '
      'settles into failure, with no further keystroke needed (plan F1/F2)',
      (tester) async {
        final service = MockMemberDirectoryService()
          ..shouldThrowOnLoadDirectory = true
          ..loadGate = Completer<void>();
        await _pumpPicker(tester, directoryService: service, settle: false);
        await tester.pump();
        final announcements = captureAccessibilityAnnouncements(tester);

        await _type(tester, 'zzz');
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          announcements,
          isEmpty,
          reason: 'the on-device read has not finished — speech must not '
              'claim an answer the screen itself does not have yet',
        );

        service.loadGate!.complete();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));

        final l10n = _l10n(tester);
        expect(
          announcements,
          [l10n.memberPickerDirectoryUnavailable],
          reason: 'the query never changed, so nothing but the directory '
              'settling into failure could have re-armed this announcement',
        );
      },
    );

    testWidgets(
      'S46. the unavailable-directory message is reachable in the semantics '
      'tree under its own text, with the same string a sighted user reads — '
      'a screen-reader user who swipes onto the row hears it even before, '
      'or without, the active announcement above',
      (tester) async {
        final handle = tester.ensureSemantics();
        final service = MockMemberDirectoryService()
          ..shouldThrowOnLoadDirectory = true;
        await _pumpPicker(tester, directoryService: service);

        final l10n = _l10n(tester);
        expect(
          _announcedLabels(tester),
          contains(l10n.memberPickerDirectoryUnavailable),
        );
        handle.dispose();
      },
    );

    testWidgets('S26. the list is not a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      // A liveRegion re-announces its WHOLE subtree on every rebuild, which
      // for this list is a roster of names read out on each keystroke.
      var live = 0;
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().hasFlag(SemanticsFlag.isLiveRegion)) {
          live++;
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
      expect(live, 0);
      handle.dispose();
    });

    testWidgets(
      'S27. an offered typed-stranger row is announced as a match, never '
      'as "no matches" (D2)',
      (tester) async {
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
        );
        final announcements = captureAccessibilityAnnouncements(tester);
        final l10n = _l10n(tester);

        await _type(tester, _strangerNpub);
        await tester.pump(const Duration(milliseconds: 400));

        expect(announcements, [l10n.memberPickerMatchesAnnouncement(1)]);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Two tiers (P3, plan §7.2)
  // -------------------------------------------------------------------------
  group('MemberPickerResults — two tiers', () {
    testWidgets('T1. tier-1 people render under a distinct heading, below '
        'tier 0', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [
              _entry(_aliceHex, _aliceNpub),
              _entry(_bobHex, _bobNpub, tier: DirectoryTier.recent),
            ],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Bob Badger'),
            },
          ),
        ),
      );

      final l10n = _l10n(tester);
      expect(find.text(l10n.memberPickerSectionRoster), findsOneWidget);
      expect(find.text(l10n.memberPickerSectionRecent), findsOneWidget);

      // Built in one literal order — tier 0's heading, tier 0's row, tier
      // 1's heading, tier 1's row — so their vertical positions are already
      // sorted top to bottom.
      final order = [
        tester.getTopLeft(find.text(l10n.memberPickerSectionRoster)).dy,
        tester.getTopLeft(find.text('Alice Aardvark')).dy,
        tester.getTopLeft(find.text(l10n.memberPickerSectionRecent)).dy,
        tester.getTopLeft(find.text('Bob Badger')).dy,
      ];
      expect(order, orderedEquals(List<double>.of(order)..sort()));
    });

    testWidgets('T2. a tier with no matches for the query is omitted, '
        'header and all', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [
              _entry(_aliceHex, _aliceNpub),
              _entry(_bobHex, _bobNpub, tier: DirectoryTier.recent),
            ],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Bob Badger'),
            },
          ),
        ),
      );

      await _type(tester, 'aardvark');

      final l10n = _l10n(tester);
      expect(find.text(l10n.memberPickerSectionRoster), findsOneWidget);
      expect(find.text(l10n.memberPickerSectionRecent), findsNothing);
      expect(find.text('Bob Badger'), findsNothing);
    });

    testWidgets('T3. a directory with only tier-1 people shows no tier-0 '
        'heading', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub, tier: DirectoryTier.recent)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
            },
          ),
        ),
      );

      final l10n = _l10n(tester);
      expect(find.text(l10n.memberPickerSectionRoster), findsNothing);
      expect(find.text(l10n.memberPickerSectionRecent), findsOneWidget);
    });

    testWidgets('T4. a tier-1 row\'s semantics label carries the recent '
        'tier phrase, never the roster one', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub, tier: DirectoryTier.recent)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
            },
          ),
        ),
      );

      final l10n = _l10n(tester);
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Alice Aardvark.*')),
      );
      expect(node.label, contains(l10n.memberPickerTierRecent));
      expect(node.label, isNot(contains(l10n.memberPickerTierRoster)));
      handle.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Nickname provenance (plan §7.2)
  // -------------------------------------------------------------------------
  group('MemberCandidateTile — nickname provenance', () {
    testWidgets('N1. a local petname is marked with a nickname note, '
        'visually and in the semantics label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
            },
            petnames: const {_aliceHex: 'Mum'},
          ),
        ),
      );

      final l10n = _l10n(tester);
      expect(find.byTooltip(l10n.memberPickerNicknameNote), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp('Mum.*')));
      expect(node.label, contains(l10n.memberPickerNicknameNote));
      handle.dispose();
    });

    testWidgets('N2. a published name with no local override carries no '
        'nickname note', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
      );

      expect(
        find.byTooltip(_l10n(tester).memberPickerNicknameNote),
        findsNothing,
      );
    });

    testWidgets('N3. the nickname note is announced exactly once — the mark '
        'icon\'s own node never doubles it', (tester) async {
      // Pins the BEHAVIOUR behind the mark sitting inside the row's
      // `excludeSemantics` subtree: `_semanticsLabel` already speaks the
      // note once for the whole row, so nothing else may also speak it,
      // however a future edit reaches that outcome.
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
            },
            petnames: const {_aliceHex: 'Mum'},
          ),
        ),
      );

      final l10n = _l10n(tester);
      final occurrences = _announcedLabels(
        tester,
      ).where((label) => label.contains(l10n.memberPickerNicknameNote)).length;
      expect(occurrences, 1);
      handle.dispose();
    });

    testWidgets(
      'N4. the nickname mark\'s long-press target meets the 24dp WCAG 2.2 '
      'minimum at default text scale, though its glyph stays 14dp (plan '
      'F6)',
      (tester) async {
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _directory(
              [_entry(_aliceHex, _aliceNpub)],
              profiles: const {
                _aliceHex: Profile(
                  pubkeyHex: _aliceHex,
                  displayName: 'Alice Aardvark',
                ),
              },
              petnames: const {_aliceHex: 'Mum'},
            ),
          ),
        );

        final l10n = _l10n(tester);
        final hitTarget = tester.renderObject<RenderBox>(
          find.byTooltip(l10n.memberPickerNicknameNote),
        );
        expect(hitTarget.size.width, greaterThanOrEqualTo(24));
        expect(hitTarget.size.height, greaterThanOrEqualTo(24));

        final glyph = tester.renderObject<RenderBox>(
          find.byIcon(LucideIcons.tag),
        );
        expect(
          glyph.size.width,
          lessThan(24),
          reason: 'the fix pads the HIT REGION, not the glyph — this pins '
              'that the glyph itself did not just get bigger',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Display-name collision (plan §7.2)
  // -------------------------------------------------------------------------
  group('MemberCandidateTile — display-name collision', () {
    testWidgets('C1. two co-members with the same resolved name are both '
        'marked with the circle that disambiguates them', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
            profiles: const {
              _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alex'),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Alex'),
            },
            circleNamesByPubkey: const {
              _aliceHex: ['Family'],
              _bobHex: ['Work Trip'],
            },
          ),
        ),
      );

      final l10n = _l10n(tester);
      // The circle name is remote-supplied (chosen by whoever created the
      // group), so the RENDERED copy is bidi-isolated — see C4/C5 below.
      expect(
        find.text(l10n.memberPickerCollisionCircleLabel(_isolated('Family'))),
        findsOneWidget,
      );
      expect(
        find.text(
          l10n.memberPickerCollisionCircleLabel(_isolated('Work Trip')),
        ),
        findsOneWidget,
      );
      expect(find.text('Alex'), findsNWidgets(2));
    });

    testWidgets('C2. no circle name is shown when nobody collides, even if '
        'a circle name is available', (tester) async {
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
            profiles: const {
              _aliceHex: Profile(
                pubkeyHex: _aliceHex,
                displayName: 'Alice Aardvark',
              ),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Bob Badger'),
            },
            circleNamesByPubkey: const {
              _aliceHex: ['Family'],
              _bobHex: ['Family'],
            },
          ),
        ),
      );

      expect(find.text('Family'), findsNothing);
      expect(
        find.text(_l10n(tester).memberPickerCollisionCircleLabel('Family')),
        findsNothing,
      );
    });

    testWidgets('C3. a collision note is included in each colliding row\'s '
        'semantics label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
            profiles: const {
              _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alex'),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Alex'),
            },
            circleNamesByPubkey: const {
              _aliceHex: ['Family'],
              _bobHex: ['Work Trip'],
            },
          ),
        ),
      );

      expect(find.bySemanticsLabel(RegExp('Alex.*Family')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Alex.*Work Trip')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('C4. a bidi override embedded in the collision circle name '
        'is contained by the isolate, not left to reorder the row', (
      tester,
    ) async {
      // Unterminated — no matching PDF — the same shape a real attacker
      // would publish, since the circle name is remote-supplied
      // (`haven-core/src/circle/manager.rs`), not typed by the local user.
      const maliciousName = 'Zoo\u202Eoo Z';
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
            profiles: const {
              _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alex'),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Alex'),
            },
            circleNamesByPubkey: const {
              _aliceHex: [maliciousName],
              _bobHex: ['Work Trip'],
            },
          ),
        ),
      );

      final l10n = _l10n(tester);
      final isolatedLine = l10n.memberPickerCollisionCircleLabel(
        _isolated(maliciousName),
      );
      // The isolate does not strip the override, only confines it: the
      // rendered line is the template wrapped around the still-malicious
      // name.
      expect(find.text(isolatedLine), findsOneWidget);

      // Structural containment: the override appears on exactly the ONE
      // Text whose data is that isolated line, and nowhere else — an
      // unterminated override that escaped its isolate would show up on
      // another widget's rendered string too (separate widgets cannot
      // interact, but a leak within the SAME string would not be caught by
      // that alone).
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .where((s) => s.contains('\u202E'))
          .toList();
      expect(rendered, [isolatedLine]);
    });

    testWidgets('C5. the collision note in a row\'s semantics label carries '
        'no bidi isolate of its own — only the rendered line does', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
            profiles: const {
              _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alex'),
              _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Alex'),
            },
            circleNamesByPubkey: const {
              _aliceHex: ['Family'],
              _bobHex: ['Work Trip'],
            },
          ),
        ),
      );

      final l10n = _l10n(tester);
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Alex.*Family')),
      );
      // An isolated collision note would NOT match this exact (un-isolated)
      // substring — a label is spoken/brailled, never laid out, so nothing
      // here needs the protection the rendered line above needs.
      expect(
        node.label,
        contains(l10n.memberPickerCollisionCircleLabel('Family')),
      );
      handle.dispose();
    });

    testWidgets(
      'C6. two colliding rows sharing their only circle have NO '
      'disambiguating note, yet still produce DIFFERENT semantics labels '
      '— the npub joins the label when nothing else does (plan F3)',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _directory(
              [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
              profiles: const {
                _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alex'),
                _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Alex'),
              },
              // The ONLY circle each of them has is the one they share, so
              // `_distinguishingCircleName` has nothing unique to offer
              // either row — same setup C2 uses to prove no note renders.
              circleNamesByPubkey: const {
                _aliceHex: ['Family'],
                _bobHex: ['Family'],
              },
            ),
          ),
        );

        final l10n = _l10n(tester);
        expect(
          find.text(l10n.memberPickerCollisionCircleLabel('Family')),
          findsNothing,
          reason: 'no circle is unique to either row, so neither may show '
              'the collision note (same claim as C2)',
        );

        final alexLabels = _announcedLabels(
          tester,
        ).where((label) => label.contains('Alex')).toList();
        expect(alexLabels, hasLength(2));
        expect(
          alexLabels[0],
          isNot(equals(alexLabels[1])),
          reason: 'two rows read aloud as the identical string are '
              'indistinguishable to a listener, even though the npub tells '
              'them apart on screen',
        );
        // Each row's OWN chunked key, not the other's — proves the
        // difference is the mechanism this fix adds, not an accident of
        // some other clause. `singleWhere` throws unless EXACTLY one label
        // matches, which is the assertion itself.
        expect(
          () => alexLabels.singleWhere(
            (l) => l.replaceAll(' ', '').contains(_short(_aliceNpub)),
          ),
          returnsNormally,
          reason: "Alice's own chunked key must appear in exactly one label",
        );
        expect(
          () => alexLabels.singleWhere(
            (l) => l.replaceAll(' ', '').contains(_short(_bobNpub)),
          ),
          returnsNormally,
          reason: "Bob's own chunked key must appear in exactly one label",
        );
        handle.dispose();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------
  group('MemberPickerResults — layout under a squeeze', () {
    Future<void> pumpNarrow(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _directory(
            [_entry(_aliceHex, _aliceNpub)],
            petnames: const {_aliceHex: 'Rechtsschutzversicherung'},
          ),
        ),
        locale: locale,
        textScaler: const TextScaler.linear(2),
      );
    }

    /// The npub wrapped rather than being cut: its laid-out box is narrower
    /// than the one line it would need, and nothing was dropped off the end.
    void expectNpubWrappedNotClipped(WidgetTester tester) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(_short(_aliceNpub)),
      );
      expect(
        paragraph.size.width,
        lessThan(paragraph.getMaxIntrinsicWidth(double.infinity)),
        reason: 'at 2x on 320dp the key cannot fit on one line',
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(find.text(_short(_aliceNpub)), findsOneWidget);
    }

    testWidgets('L1. at 2x on a 320dp phone the key wraps and the row does '
        'not overflow', (tester) async {
      await pumpNarrow(tester);

      expect(tester.takeException(), isNull);
      expectNpubWrappedNotClipped(tester);
    });

    testWidgets('L2. the same holds in a long-word locale', (tester) async {
      await pumpNarrow(tester, locale: const Locale('de'));

      expect(tester.takeException(), isNull);
      expectNpubWrappedNotClipped(tester);
    });

    testWidgets('L3. the same holds in RTL, and the key still reads LTR', (
      tester,
    ) async {
      await pumpNarrow(tester, locale: const Locale('ar'));

      expect(tester.takeException(), isNull);
      expectNpubWrappedNotClipped(tester);
      expect(
        Directionality.of(tester.element(find.byType(_PickerHost))),
        TextDirection.rtl,
        reason: 'the locale really did mirror the page',
      );
      expect(
        tester
            .renderObject<RenderParagraph>(find.text(_short(_aliceNpub)))
            .textDirection,
        TextDirection.ltr,
        reason:
            'a bech32 key read right-to-left is a different string to the '
            'eye than the one the user was handed',
      );
    });

    testWidgets(
      'L4. a colliding pair with a long circle name does not overflow at '
      '2x in a long-word locale (plan F7 — this page has overflowed CI '
      'once before, and the collision label is the one element on the row '
      'with no maxLines)',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(320, 568);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const longCircleNameA = 'Rechtsschutzversicherungsgesellschaften';
        const longCircleNameB = 'Bundesausbildungsförderungsgesetzentwurf';

        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _directory(
              [_entry(_aliceHex, _aliceNpub), _entry(_bobHex, _bobNpub)],
              profiles: const {
                _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alex'),
                _bobHex: Profile(pubkeyHex: _bobHex, displayName: 'Alex'),
              },
              circleNamesByPubkey: const {
                _aliceHex: [longCircleNameA],
                _bobHex: [longCircleNameB],
              },
            ),
          ),
          locale: const Locale('de'),
          textScaler: const TextScaler.linear(2),
        );

        expect(tester.takeException(), isNull);
        final l10n = _l10n(tester);
        expect(
          find.text(
            l10n.memberPickerCollisionCircleLabel(_isolated(longCircleNameA)),
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            l10n.memberPickerCollisionCircleLabel(_isolated(longCircleNameB)),
          ),
          findsOneWidget,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Typed-stranger resolve (D2, plan §10) — the ONE new outbound request
  // this feature adds, and the three caller-side gates that must ALL hold
  // before it is ever fired.
  // -------------------------------------------------------------------------
  group('MemberPickerResults — typed-stranger resolve (D2)', () {
    bool resolvedStranger(MockProfileService service) => service.methodCalls
        .any((c) => c.method == 'resolveTypedStrangerProfile');

    testWidgets('S28. a partial npub prefix never triggers a network '
        'resolve', (tester) async {
      final profileService = MockProfileService();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        profileService: profileService,
      );

      await _type(tester, _strangerNpub.substring(0, 20));
      await tester.pumpAndSettle();

      expect(resolvedStranger(profileService), isFalse);
    });

    testWidgets('S29. an npub already known locally never triggers a '
        'network resolve', (tester) async {
      final profileService = MockProfileService();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        profileService: profileService,
      );

      await _type(tester, _bobNpub);
      await tester.pumpAndSettle();

      expect(resolvedStranger(profileService), isFalse);
    });

    testWidgets(
      "S30. the user's own npub never triggers a network resolve",
      (tester) async {
        final profileService = MockProfileService();
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
          profileService: profileService,
        );

        await _type(tester, _selfNpub);
        await tester.pumpAndSettle();

        expect(resolvedStranger(profileService), isFalse);
      },
    );

    testWidgets('S31. an npub already staged on this screen never triggers '
        'a network resolve', (tester) async {
      final profileService = MockProfileService();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        profileService: profileService,
        stagedNpubs: const {_strangerNpub},
      );

      await _type(tester, _strangerNpub);
      await tester.pumpAndSettle();

      expect(resolvedStranger(profileService), isFalse);
    });

    testWidgets('S32. an npub already in the target circle never triggers '
        'a network resolve', (tester) async {
      final profileService = MockProfileService();
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        profileService: profileService,
        circleMemberNpubs: const {_strangerNpub},
      );

      await _type(tester, _strangerNpub);
      await tester.pumpAndSettle();

      expect(resolvedStranger(profileService), isFalse);
    });

    testWidgets('S33. a resolved stranger renders their published name '
        'beside the npub', (tester) async {
      final profileService = MockProfileService()
        ..strangerProfiles[_strangerNpub] = const Profile(
          pubkeyHex: _strangerHex,
          displayName: 'Distant Cousin',
        );
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        profileService: profileService,
      );

      await _type(tester, _strangerNpub);
      await tester.pumpAndSettle();

      expect(find.text('Distant Cousin'), findsOneWidget);
      expect(find.text(_short(_strangerNpub)), findsOneWidget);
      expect(
        profileService.methodCalls
            .where((c) => c.method == 'resolveTypedStrangerProfile')
            .single
            .args['npub'],
        _strangerNpub,
      );
    });

    testWidgets(
      'S34. a bounded spinner shows while the resolve is in flight, then '
      'the resolved name replaces it',
      (tester) async {
        final gate = Completer<void>();
        final profileService = MockProfileService()
          ..resolveTypedStrangerProfileGate = gate
          ..strangerProfiles[_strangerNpub] = const Profile(
            pubkeyHex: _strangerHex,
            displayName: 'Distant Cousin',
          );
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
          profileService: profileService,
        );

        await _type(tester, _strangerNpub);

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Distant Cousin'), findsNothing);

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Distant Cousin'), findsOneWidget);
      },
    );

    testWidgets(
      'S35. nothing resolving falls back to npub-only rendering, without '
      "leaking the mock service's raw error text (Security Rule 8)",
      (tester) async {
        final profileService = MockProfileService()
          ..shouldThrowOnResolveTypedStrangerProfile = true;
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
          profileService: profileService,
        );

        await _type(tester, _strangerNpub);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(_short(_strangerNpub)), findsOneWidget);
        expect(find.textContaining('generic'), findsNothing);
        expect(find.textContaining('ProfileServiceException'), findsNothing);
      },
    );

    testWidgets(
      'S36. a stale in-flight resolve for an abandoned npub never renders '
      'once the query has moved to a different npub',
      (tester) async {
        final gate = Completer<void>();
        final profileService = MockProfileService()
          ..resolveTypedStrangerProfileGate = gate
          ..strangerProfiles[_strangerNpub] = const Profile(
            pubkeyHex: _strangerHex,
            displayName: 'First Candidate',
          )
          ..strangerProfiles[_stranger2Npub] = const Profile(
            pubkeyHex: _strangerHex,
            displayName: 'Second Candidate',
          );
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
          profileService: profileService,
        );

        // Type the FIRST stranger npub — its resolve starts, held open by
        // the gate.
        await _type(tester, _strangerNpub);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Abandon it for a SECOND, distinct npub before the gate ever opens.
        await _type(tester, _stranger2Npub);
        expect(
          find.text('First Candidate'),
          findsNothing,
          reason: 'changing the query must drop the FIRST npub row '
              'immediately, without waiting for its in-flight resolve',
        );

        // Let both holds through the shared gate resolve.
        gate.complete();
        await tester.pumpAndSettle();

        expect(
          find.text('First Candidate'),
          findsNothing,
          reason: 'the abandoned resolve must never render even once it '
              'eventually completes — nothing is watching it any more',
        );
        expect(find.text('Second Candidate'), findsOneWidget);
      },
    );

    testWidgets('S37. tapping the typed-stranger row stages the npub', (
      tester,
    ) async {
      final staged = <String>[];
      await _pumpPicker(
        tester,
        directoryService: MockMemberDirectoryService(
          directory: _threePeople(),
        ),
        onStrangerSelected: staged.add,
      );

      await _type(tester, _strangerNpub);
      await tester.pumpAndSettle();

      await tester.tap(find.text(_short(_strangerNpub)));
      await tester.pump();

      expect(staged, [_strangerNpub]);
    });

    testWidgets(
      "S38. the typed-stranger row's key is also spoken by an action whose "
      'LABEL is a constant',
      (tester) async {
        final handle = tester.ensureSemantics();
        final announcements = captureAccessibilityAnnouncements(tester);
        final profileService = MockProfileService()
          ..strangerProfiles[_strangerNpub] = const Profile(
            pubkeyHex: _strangerHex,
            displayName: 'Distant Cousin',
          );
        await _pumpPicker(
          tester,
          directoryService: MockMemberDirectoryService(
            directory: _threePeople(),
          ),
          profileService: profileService,
        );

        await _type(tester, _strangerNpub);
        await tester.pumpAndSettle();

        final l10n = _l10n(tester);
        final node = tester.getSemantics(
          find.bySemanticsLabel(RegExp('Distant Cousin.*')),
        );
        final actions = node.getSemanticsData().customSemanticsActionIds!;
        final labels = actions
            .map((id) => CustomSemanticsAction.getAction(id)!.label)
            .toList();

        expect(labels, contains(l10n.memberPickerReadPublicKey));
        for (final label in labels) {
          expect(
            label,
            isNot(contains('npub1')),
            reason: 'an npub in an action label is interned forever',
          );
        }

        final readId = actions.firstWhere(
          (id) =>
              CustomSemanticsAction.getAction(id)!.label ==
              l10n.memberPickerReadPublicKey,
        );
        tester.binding.pipelineOwner.semanticsOwner!.performAction(
          node.id,
          SemanticsAction.customAction,
          readId,
        );
        await tester.pumpAndSettle();

        expect(announcements, hasLength(1));
        expect(
          announcements.single.replaceAll(' ', ''),
          _short(_strangerNpub),
          reason: 'spoken in chunks, but the same characters',
        );
        handle.dispose();
      },
    );
  });

  // -------------------------------------------------------------------------
  // The pure gating function the widget group above exercises end to end.
  // Direct, fast, isolated coverage of its own logic (ordering, edge cases)
  // beyond what a full widget pump incidentally covers.
  // -------------------------------------------------------------------------
  group('eligibleStrangerNpub', () {
    MemberCandidate localCandidate(String npub) => MemberCandidate(
      pubkeyHex: 'irrelevant-for-this-gate',
      npub: npub,
      nameKey: '',
      searchKeys: const [],
    );

    test('a complete, valid, unknown, selectable npub is eligible', () {
      expect(
        eligibleStrangerNpub(
          _strangerNpub,
          localResults: const [],
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        _strangerNpub,
      );
    });

    test('gate 1: a partial prefix is never eligible', () {
      expect(
        eligibleStrangerNpub(
          _strangerNpub.substring(0, 20),
          localResults: const [],
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        isNull,
      );
    });

    test(
      'gate 1: an npub embedded inside a longer pasted string is never '
      'eligible — only an exact match',
      () {
        expect(
          eligibleStrangerNpub(
            'nostr:$_strangerNpub',
            localResults: const [],
            stagedNpubs: const {},
            circleMemberNpubs: const {},
            selfNpub: _selfNpub,
          ),
          isNull,
        );
      },
    );

    test('gate 2: an npub already found in the local results is never '
        'eligible', () {
      expect(
        eligibleStrangerNpub(
          _strangerNpub,
          localResults: [localCandidate(_strangerNpub)],
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        isNull,
      );
    });

    test("gate 3: the user's own npub is never eligible", () {
      expect(
        eligibleStrangerNpub(
          _selfNpub,
          localResults: const [],
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        isNull,
      );
    });

    test('gate 3: an already-staged npub is never eligible', () {
      expect(
        eligibleStrangerNpub(
          _strangerNpub,
          localResults: const [],
          stagedNpubs: const {_strangerNpub},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        isNull,
      );
    });

    test('gate 3: an npub already in the target circle is never eligible', () {
      expect(
        eligibleStrangerNpub(
          _strangerNpub,
          localResults: const [],
          stagedNpubs: const {},
          circleMemberNpubs: const {_strangerNpub},
          selfNpub: _selfNpub,
        ),
        isNull,
      );
    });

    test(
      'an unresolved identity (null selfNpub) does not block eligibility',
      () {
        expect(
          eligibleStrangerNpub(
            _strangerNpub,
            localResults: const [],
            stagedNpubs: const {},
            circleMemberNpubs: const {},
            selfNpub: null,
          ),
          _strangerNpub,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // The pure grouping function C6 exercises end to end (plan F3). Direct,
  // isolated coverage of the same edge cases `_markCollidingNames`
  // (member_directory_service.dart) has to get right, since this function
  // must walk the identical population to stay consistent with it.
  // -------------------------------------------------------------------------
  group('collidingDisplayNames', () {
    MemberCandidate candidate(
      String pubkeyHex, {
      String? displayName,
      DirectoryTier tier = DirectoryTier.current,
    }) => MemberCandidate(
      pubkeyHex: pubkeyHex,
      npub: 'irrelevant-for-this-gate',
      nameKey: '',
      searchKeys: const [],
      displayName: displayName,
      tier: tier,
    );

    test('two current-tier entries with the same name collide', () {
      expect(
        collidingDisplayNames([
          candidate(_aliceHex, displayName: 'Alex'),
          candidate(_bobHex, displayName: 'Alex'),
        ]),
        {'Alex'},
      );
    });

    test('a lone name never collides', () {
      expect(
        collidingDisplayNames([candidate(_aliceHex, displayName: 'Alex')]),
        isEmpty,
      );
    });

    test('an unnamed entry never collides, and is never confused with '
        'another unnamed entry', () {
      expect(
        collidingDisplayNames([
          candidate(_aliceHex),
          candidate(_bobHex),
        ]),
        isEmpty,
      );
    });

    test(
      'a recent-tier (tier-1) name-sharer does not create a collision — '
      'a tier-1 person is no longer a co-member of anything',
      () {
        expect(
          collidingDisplayNames([
            candidate(_aliceHex, displayName: 'Alex'),
            candidate(
              _bobHex,
              displayName: 'Alex',
              tier: DirectoryTier.recent,
            ),
          ]),
          isEmpty,
        );
      },
    );

    test('three-way collisions are still reported once', () {
      expect(
        collidingDisplayNames([
          candidate(_aliceHex, displayName: 'Alex'),
          candidate(_bobHex, displayName: 'Alex'),
          candidate(_carolHex, displayName: 'Alex'),
        ]),
        {'Alex'},
      );
    });
  });
}
