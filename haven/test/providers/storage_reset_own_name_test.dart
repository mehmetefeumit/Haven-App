/// After the storage reset, the user's own name shown on this device comes
/// from their published profile — never from a pre-update edit the network
/// may never have seen.
///
/// The name lives in SharedPreferences, written BEFORE the publish; the reset
/// deleted the publish outbox (`profile_sync_state` in the old `circles.db`),
/// so a pending name would otherwise outlive the reset while the notice says
/// it was removed and the network keeps the old one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/storage_reset_notice_provider.dart';
import 'package:haven/src/rust/api.dart'
    show NostrIdentityManager, PublicIdentity;
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/widgets/identity/display_name_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_profile_service.dart';

final String _pubkeyHex = 'ab' * 32;
final String _nameKey = '$kDisplayNamePrefPrefix$_pubkeyHex';
const _unpublished = 'Unsent Pseudonym';
const _published = 'Quiet Wanderer';

class _FakeIdentityManager implements NostrIdentityManager {
  bool _loaded = false;

  @override
  bool hasIdentity() => _loaded;

  @override
  PublicIdentity? getIdentity() => _loaded
      ? PublicIdentity(pubkeyHex: _pubkeyHex, npub: 'npub1fake', createdAt: 0)
      : null;

  @override
  Future<PublicIdentity> loadFromBytes({required List<int> secretBytes}) async {
    _loaded = true;
    return PublicIdentity(
      pubkeyHex: _pubkeyHex,
      npub: 'npub1fake',
      createdAt: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _MemoryStorage extends FlutterSecureStorage {
  _MemoryStorage(this._value);

  final String _value;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _value;
}

NostrIdentityService _identity() => NostrIdentityService(
  storage: _MemoryStorage(
    base64Encode(Uint8List.fromList(List.filled(32, 7))),
  ),
  wipeTileCache: () async {},
  managerFactory: () async => _FakeIdentityManager(),
);

PublishedOwnProfile _answer({String? displayName, String? name}) =>
    PublishedOwnProfile.answered(
      Profile(pubkeyHex: _pubkeyHex, displayName: displayName, name: name),
    );

Future<void> _clearAfterReset(SharedPreferences prefs) =>
    clearCircleScopedPrefsIfResetOwes(
      prefs,
      'data',
      owed: (_) => true,
      cleared: (_) {},
    );

Future<void> _pumpCard(WidgetTester tester, NostrIdentityService identity) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityServiceProvider.overrideWithValue(identity),
          profileServiceProvider.overrideWithValue(MockProfileService()),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DisplayNameCard()),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a pending pre-update name is not shown after the reset', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_nameKey: _unpublished});
    final identity = _identity();
    await _pumpCard(tester, identity);
    await tester.pumpAndSettle();
    expect(
      find.text(_unpublished),
      findsOneWidget,
      reason: 'anti-vacuity: before the reset the card shows the pending name',
    );

    await _clearAfterReset(await SharedPreferences.getInstance());
    await _pumpCard(tester, _identity());
    await tester.pumpAndSettle();

    expect(find.text(_unpublished), findsNothing);
  });

  group('reseedOwnNameIfOwed', () {
    Future<bool> reseed(
      SharedPreferences prefs, {
      required Future<PublishedOwnProfile> Function() fetchPublished,
      bool profilesEnabled = true,
    }) {
      final identity = _identity();
      return reseedOwnNameIfOwed(
        prefs: prefs,
        fetchPublished: fetchPublished,
        currentName: identity.getDisplayName,
        setName: identity.setDisplayName,
        profilesEnabled: profilesEnabled,
      );
    }

    test('takes the name the published profile carries, once', () async {
      SharedPreferences.setMockInitialValues({_nameKey: _unpublished});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);

      var fetches = 0;
      Future<PublishedOwnProfile> fetch() async {
        fetches++;
        return _answer(displayName: _published);
      }

      expect(await reseed(prefs, fetchPublished: fetch), isTrue);
      expect(await _identity().getDisplayName(), _published);
      expect(await reseed(prefs, fetchPublished: fetch), isFalse);
      expect(fetches, 1, reason: 'no fetch once the name is reseeded');
    });

    test('a name set since the update wins over the published one', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);
      await _identity().setDisplayName('Chosen Since');

      await reseed(
        prefs,
        fetchPublished: () async => _answer(displayName: _published),
      );

      expect(await _identity().getDisplayName(), 'Chosen Since');
      expect(prefs.getBool(kOwnNameReseedOwedKey), isNull);
    });

    test('stays owed while the relays have not settled what is '
        'published', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);

      expect(
        await reseed(
          prefs,
          fetchPublished: () async => const PublishedOwnProfile.unanswered(),
        ),
        isFalse,
      );
      expect(prefs.getBool(kOwnNameReseedOwedKey), isTrue);
      expect(await _identity().getDisplayName(), isNull);
    });

    test('is spent, with no name, once every relay answers that no profile '
        'is published', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);

      var fetches = 0;
      Future<PublishedOwnProfile> fetch() async {
        fetches++;
        return const PublishedOwnProfile.answered(null);
      }

      expect(await reseed(prefs, fetchPublished: fetch), isFalse);
      expect(await _identity().getDisplayName(), isNull);
      expect(prefs.getBool(kOwnNameReseedOwedKey), isNull);
      await reseed(prefs, fetchPublished: fetch);
      expect(fetches, 1, reason: 'the relays are not asked again');
    });

    test('a failed fetch stays owed and logs its type alone', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);
      final logs = LogCapture.install();

      await reseed(
        prefs,
        fetchPublished: () async =>
            throw StateError('kind-0 of $_pubkeyHex from wss://relay.secret'),
      );

      expect(prefs.getBool(kOwnNameReseedOwedKey), isTrue);
      logs
        ..assertContains('own profile not fetched: StateError')
        ..assertNoNeedles([_pubkeyHex, 'wss://relay.secret']);
    });

    test('a blank display name falls through to the name, as Rust resolves '
        'it', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);

      await reseed(
        prefs,
        fetchPublished: () async =>
            _answer(displayName: '  ', name: _published),
      );

      expect(await _identity().getDisplayName(), _published);
    });

    test('a published profile that names nobody — the blank a deletion '
        'leaves — gives no name and is spent', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);

      var fetches = 0;
      Future<PublishedOwnProfile> fetch() async {
        fetches++;
        return _answer();
      }

      expect(await reseed(prefs, fetchPublished: fetch), isFalse);
      expect(await _identity().getDisplayName(), isNull);
      expect(prefs.getBool(kOwnNameReseedOwedKey), isNull);
      await reseed(prefs, fetchPublished: fetch);
      expect(fetches, 1, reason: 'the relays are not asked again');
    });

    test('a build that fetches no public profiles asks nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await _clearAfterReset(prefs);

      var fetches = 0;
      expect(
        await reseed(
          prefs,
          profilesEnabled: false,
          fetchPublished: () async {
            fetches++;
            return _answer(displayName: _published);
          },
        ),
        isFalse,
      );
      expect(fetches, 0, reason: 'no profile relay is dialled');
      expect(prefs.getBool(kOwnNameReseedOwedKey), isTrue);
    });

    test('without a reset it asks nothing', () async {
      SharedPreferences.setMockInitialValues({_nameKey: _published});
      final prefs = await SharedPreferences.getInstance();

      expect(
        await reseed(
          prefs,
          fetchPublished: () async => throw StateError('must not be called'),
        ),
        isFalse,
      );
      expect(await _identity().getDisplayName(), _published);
    });
  });
}
