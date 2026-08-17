/// Tests for [NostrRelayPreferencesService], the production
/// [RelayPreferencesService] backed by `CircleManagerFfi`.
///
/// `CircleManagerFfi` is declared `abstract` in the generated bindings (see
/// `lib/src/rust/api.dart`), so — unlike the identity/circle/relay services
/// documented as FFI-unmockable in their own test files — this one CAN be
/// unit tested with a hand-written fake, no native library required.
///
/// These tests verify the promises the class's own doc comment makes:
///   * category routing never mismaps ([RelayCategory.keyPackage] MUST route
///     to [RelayTypeFfi.nip65] — the Dark Matter kind-10002 migration; a
///     silent mismap here would misfile every KeyPackage-relay operation);
///   * every FFI failure is caught and rethrown as a typed, generic
///     exception whose message is safe to show a user (Security Rule 8 — the
///     raw FFI error text, which could carry hex-encoded MLS state, MUST
///     NEVER reach the thrown exception's message);
///   * `_mapStorageError`'s validation-substring matching turns specific Rust
///     validation failures into specific, actionable [RelayValidationError]s;
///   * FFI response objects are mapped field-for-field into their Dart-side
///     counterparts, including the `suppressed` (privacy-toggle-off) case,
///     where the caller MUST NOT publish anything.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_preferences_service.dart';
import 'package:haven/src/services/relay_preferences_service.dart';

/// A hand-written fake for the (large, generated) `CircleManagerFfi`
/// interface — mirrors the `_FakeEngine implements LiveSyncFfi` convention in
/// `nostr_subscription_service_test.dart`. Only the ~15 methods
/// [NostrRelayPreferencesService] actually calls are overridden; anything
/// else routes to [noSuchMethod] and fails the test loudly, which doubles as
/// a proof that the service touches nothing beyond its documented surface.
class _FakeCircleManager implements CircleManagerFfi {
  /// Call log, in order, for assertions that don't need captured arguments.
  final List<String> calls = [];

  /// The [RelayTypeFfi] passed to the most recent call — every method below
  /// takes exactly one, so a single field suffices to catch a mismap.
  RelayTypeFfi? lastRelayType;

  Exception? listUserRelaysThrows;
  List<String> listUserRelaysResult = const [];

  @override
  Future<List<String>> listUserRelays({
    required RelayTypeFfi relayType,
  }) async {
    calls.add('listUserRelays');
    lastRelayType = relayType;
    if (listUserRelaysThrows != null) throw listUserRelaysThrows!;
    return listUserRelaysResult;
  }

  Exception? addUserRelayThrows;
  String? lastAddUrl;

  @override
  Future<void> addUserRelay({
    required String url,
    required RelayTypeFfi relayType,
  }) async {
    calls.add('addUserRelay');
    lastAddUrl = url;
    lastRelayType = relayType;
    if (addUserRelayThrows != null) throw addUserRelayThrows!;
  }

  Exception? removeUserRelayThrows;
  bool removeUserRelayResult = true;
  String? lastRemoveUrl;

  @override
  Future<bool> removeUserRelay({
    required String url,
    required RelayTypeFfi relayType,
  }) async {
    calls.add('removeUserRelay');
    lastRemoveUrl = url;
    lastRelayType = relayType;
    if (removeUserRelayThrows != null) throw removeUserRelayThrows!;
    return removeUserRelayResult;
  }

  Exception? restoreDefaultsForThrows;

  @override
  Future<void> restoreDefaultsFor({required RelayTypeFfi relayType}) async {
    calls.add('restoreDefaultsFor');
    lastRelayType = relayType;
    if (restoreDefaultsForThrows != null) throw restoreDefaultsForThrows!;
  }

  Exception? wipeAndResetDefaultsForThrows;

  @override
  Future<void> wipeAndResetDefaultsFor({
    required RelayTypeFfi relayType,
  }) async {
    calls.add('wipeAndResetDefaultsFor');
    lastRelayType = relayType;
    if (wipeAndResetDefaultsForThrows != null) {
      throw wipeAndResetDefaultsForThrows!;
    }
  }

  Exception? seedRelayDefaultsIfUnseededThrows;

  @override
  Future<bool> seedRelayDefaultsIfUnseeded() async {
    calls.add('seedRelayDefaultsIfUnseeded');
    if (seedRelayDefaultsIfUnseededThrows != null) {
      throw seedRelayDefaultsIfUnseededThrows!;
    }
    return true;
  }

  Exception? getPublishRelayListThrows;
  bool getPublishRelayListResult = true;

  @override
  Future<bool> getPublishRelayList({required RelayTypeFfi relayType}) async {
    calls.add('getPublishRelayList');
    lastRelayType = relayType;
    if (getPublishRelayListThrows != null) throw getPublishRelayListThrows!;
    return getPublishRelayListResult;
  }

  Exception? setPublishRelayListThrows;
  bool? lastSetPublishValue;

  @override
  Future<void> setPublishRelayList({
    required RelayTypeFfi relayType,
    required bool value,
  }) async {
    calls.add('setPublishRelayList');
    lastRelayType = relayType;
    lastSetPublishValue = value;
    if (setPublishRelayListThrows != null) throw setPublishRelayListThrows!;
  }

  Exception? relayPublishTargetsThrows;
  List<String> relayPublishTargetsResult = const [];

  @override
  Future<List<String>> relayPublishTargets({
    required RelayTypeFfi relayType,
  }) async {
    calls.add('relayPublishTargets');
    lastRelayType = relayType;
    if (relayPublishTargetsThrows != null) throw relayPublishTargetsThrows!;
    return relayPublishTargetsResult;
  }

  Exception? buildRelayListPublishThrows;
  BuiltRelayListEventFfi buildRelayListPublishResult =
      const BuiltRelayListEventFfi(targets: [], suppressed: true);
  List<int>? lastBuildRelayListPublishSecret;

  @override
  Future<BuiltRelayListEventFfi> buildRelayListPublish({
    required List<int> identitySecretBytes,
    required RelayTypeFfi relayType,
  }) async {
    calls.add('buildRelayListPublish');
    lastRelayType = relayType;
    lastBuildRelayListPublishSecret = identitySecretBytes;
    if (buildRelayListPublishThrows != null) {
      throw buildRelayListPublishThrows!;
    }
    return buildRelayListPublishResult;
  }

  Exception? recordPublishedRelayListThrows;
  String? lastRecordIdentityPubkeyHex;
  int? lastRecordKind;
  String? lastRecordEventIdHex;
  int? lastRecordPublishedAtSecs;

  @override
  Future<void> recordPublishedRelayList({
    required String identityPubkeyHex,
    required int kind,
    required int publishedAtSecs,
    required String eventIdHex,
  }) async {
    calls.add('recordPublishedRelayList');
    lastRecordIdentityPubkeyHex = identityPubkeyHex;
    lastRecordKind = kind;
    lastRecordEventIdHex = eventIdHex;
    lastRecordPublishedAtSecs = publishedAtSecs;
    if (recordPublishedRelayListThrows != null) {
      throw recordPublishedRelayListThrows!;
    }
  }

  Exception? buildUnpublishRelayListThrows;
  BuiltUnpublishFfi buildUnpublishRelayListResult = const BuiltUnpublishFfi(
    targets: [],
    suppressed: true,
  );

  @override
  Future<BuiltUnpublishFfi> buildUnpublishRelayList({
    required List<int> identitySecretBytes,
    required RelayTypeFfi relayType,
  }) async {
    calls.add('buildUnpublishRelayList');
    lastRelayType = relayType;
    if (buildUnpublishRelayListThrows != null) {
      throw buildUnpublishRelayListThrows!;
    }
    return buildUnpublishRelayListResult;
  }

  Exception? buildRelayRemovalScrubThrows;
  BuiltUnpublishFfi buildRelayRemovalScrubResult = const BuiltUnpublishFfi(
    targets: [],
    suppressed: true,
  );
  List<String>? lastDroppedRelays;

  @override
  Future<BuiltUnpublishFfi> buildRelayRemovalScrub({
    required List<int> identitySecretBytes,
    required RelayTypeFfi relayType,
    required List<String> droppedRelays,
  }) async {
    calls.add('buildRelayRemovalScrub');
    lastRelayType = relayType;
    lastDroppedRelays = droppedRelays;
    if (buildRelayRemovalScrubThrows != null) {
      throw buildRelayRemovalScrubThrows!;
    }
    return buildRelayRemovalScrubResult;
  }

  Exception? profilePoolStatusThrows;
  ProfilePoolStatusFfi profilePoolStatusResult = const ProfilePoolStatusFfi(
    configured: 0,
    excluded: 0,
    usable: 0,
    isUnderflow: false,
  );

  @override
  Future<ProfilePoolStatusFfi> profilePoolStatus() async {
    calls.add('profilePoolStatus');
    if (profilePoolStatusThrows != null) throw profilePoolStatusThrows!;
    return profilePoolStatusResult;
  }

  Exception? restoreDefaultProfileRelaysThrows;

  @override
  Future<void> restoreDefaultProfileRelays() async {
    calls.add('restoreDefaultProfileRelays');
    if (restoreDefaultProfileRelaysThrows != null) {
      throw restoreDefaultProfileRelaysThrows!;
    }
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A raw FFI error string shaped like the redacted-but-still-internal detail
/// Rust can surface — carries an MLS-group-id-looking hex run. No promise
/// under test here is about WHAT Rust redacts (that's `redact_hex_sequences`,
/// tested in haven-core); the promise is that whatever arrives, this Dart
/// wrapper never lets it reach the exception it throws to the UI.
const _sensitiveRawError =
    'internal failure for group deadbeefcafef00ddeadbeefcafef00d';

void main() {
  group('NostrRelayPreferencesService — category routing', () {
    test(
      'RelayCategory.keyPackage routes to RelayTypeFfi.nip65 (Dark Matter '
      'kind-10002 migration)',
      () async {
        final manager = _FakeCircleManager();
        final service = NostrRelayPreferencesService(manager: manager);
        await service.listRelays(RelayCategory.keyPackage);
        expect(manager.lastRelayType, RelayTypeFfi.nip65);
      },
    );

    test('every RelayCategory maps to its documented RelayTypeFfi', () async {
      const expected = {
        RelayCategory.inbox: RelayTypeFfi.inbox,
        RelayCategory.keyPackage: RelayTypeFfi.nip65,
        RelayCategory.profile: RelayTypeFfi.profile,
      };
      for (final category in RelayCategory.values) {
        final manager = _FakeCircleManager();
        final service = NostrRelayPreferencesService(manager: manager);
        await service.listRelays(category);
        expect(
          manager.lastRelayType,
          expected[category],
          reason: '$category must map to ${expected[category]}',
        );
      }
    });
  });

  group('NostrRelayPreferencesService — listRelays', () {
    test('returns the relays the manager reports', () async {
      final manager = _FakeCircleManager()
        ..listUserRelaysResult = const ['wss://a.example', 'wss://b.example'];
      final service = NostrRelayPreferencesService(manager: manager);
      final relays = await service.listRelays(RelayCategory.inbox);
      expect(relays, ['wss://a.example', 'wss://b.example']);
    });

    test(
      'a manager failure surfaces as a generic RelayPreferencesException '
      'that never carries the raw FFI error text (Security Rule 8)',
      () async {
        final manager = _FakeCircleManager()
          ..listUserRelaysThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.listRelays(RelayCategory.inbox),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to load relay list.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — addRelay', () {
    test('forwards the url and category to the manager', () async {
      final manager = _FakeCircleManager();
      final service = NostrRelayPreferencesService(manager: manager);
      await service.addRelay(RelayCategory.keyPackage, 'wss://new.example');
      expect(manager.lastAddUrl, 'wss://new.example');
      expect(manager.lastRelayType, RelayTypeFfi.nip65);
    });

    for (final case_ in [
      (
        raw: 'Use wss:// for this relay',
        expected: 'Use wss:// so traffic to this relay is encrypted.',
      ),
      (
        raw: 'USE WSS:// FOR THIS RELAY',
        expected: 'Use wss:// so traffic to this relay is encrypted.',
      ),
      (
        raw: 'relay url must not contain credentials',
        expected: 'Relay URL must not contain credentials.',
      ),
      (
        raw: 'invalid relay url: not-a-url',
        expected: 'Enter a relay address like wss://relay.example.com.',
      ),
      (
        raw: 'relay url must not be empty',
        expected: 'Enter a relay address like wss://relay.example.com.',
      ),
      (
        raw: 'you need at least one relay',
        expected: 'You need at least one relay so others can reach you.',
      ),
    ]) {
      test(
        'maps the validation failure "${case_.raw}" to a RelayValidationError '
        'with a fixed, presentable message',
        () async {
          final manager = _FakeCircleManager()
            ..addUserRelayThrows = Exception(case_.raw);
          final service = NostrRelayPreferencesService(manager: manager);
          await expectLater(
            service.addRelay(RelayCategory.inbox, 'ws://bad'),
            throwsA(
              isA<RelayValidationError>().having(
                (e) => e.message,
                'message',
                case_.expected,
              ),
            ),
          );
        },
      );
    }

    test(
      'an unrecognized manager failure maps to a generic '
      'RelayPreferencesException, never the raw text',
      () async {
        final manager = _FakeCircleManager()
          ..addUserRelayThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.addRelay(RelayCategory.inbox, 'wss://ok.example'),
          throwsA(
            isA<RelayPreferencesException>()
                .having((e) => e.message, 'message', 'Relay update failed.')
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — removeRelay', () {
    test("returns the manager's removal result", () async {
      final manager = _FakeCircleManager()..removeUserRelayResult = false;
      final service = NostrRelayPreferencesService(manager: manager);
      final removed = await service.removeRelay(
        RelayCategory.inbox,
        'wss://gone.example',
      );
      expect(removed, isFalse);
      expect(manager.lastRemoveUrl, 'wss://gone.example');
    });

    test(
      'maps a "last relay" validation failure to a RelayValidationError',
      () async {
        final manager = _FakeCircleManager()
          ..removeUserRelayThrows = Exception(
            'removal would leave at least one relay required',
          );
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.removeRelay(RelayCategory.inbox, 'wss://only.example'),
          throwsA(
            isA<RelayValidationError>().having(
              (e) => e.message,
              'message',
              'You need at least one relay so others can reach you.',
            ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — defaults + seeding', () {
    test('restoreDefaults delegates to restoreDefaultsFor', () async {
      final manager = _FakeCircleManager();
      final service = NostrRelayPreferencesService(manager: manager);
      await service.restoreDefaults(RelayCategory.profile);
      expect(manager.calls, contains('restoreDefaultsFor'));
      expect(manager.lastRelayType, RelayTypeFfi.profile);
    });

    test('a restoreDefaults failure is generic and never leaks', () async {
      final manager = _FakeCircleManager()
        ..restoreDefaultsForThrows = Exception(_sensitiveRawError);
      final service = NostrRelayPreferencesService(manager: manager);
      await expectLater(
        service.restoreDefaults(RelayCategory.inbox),
        throwsA(
          isA<RelayPreferencesException>()
              .having(
                (e) => e.message,
                'message',
                'Failed to restore defaults.',
              )
              .having(
                (e) => e.toString(),
                'toString()',
                isNot(contains('deadbeef')),
              ),
        ),
      );
    });

    test('wipeAndResetDefaults delegates to wipeAndResetDefaultsFor', () async {
      final manager = _FakeCircleManager();
      final service = NostrRelayPreferencesService(manager: manager);
      await service.wipeAndResetDefaults(RelayCategory.keyPackage);
      expect(manager.calls, contains('wipeAndResetDefaultsFor'));
      expect(manager.lastRelayType, RelayTypeFfi.nip65);
    });

    test('a wipeAndResetDefaults failure is generic and never leaks', () async {
      final manager = _FakeCircleManager()
        ..wipeAndResetDefaultsForThrows = Exception(_sensitiveRawError);
      final service = NostrRelayPreferencesService(manager: manager);
      await expectLater(
        service.wipeAndResetDefaults(RelayCategory.inbox),
        throwsA(
          isA<RelayPreferencesException>()
              .having((e) => e.message, 'message', 'Failed to reset defaults.')
              .having(
                (e) => e.toString(),
                'toString()',
                isNot(contains('deadbeef')),
              ),
        ),
      );
    });

    test(
      'seedDefaultsIfUnseeded delegates and discards the FFI bool',
      () async {
        final manager = _FakeCircleManager();
        final service = NostrRelayPreferencesService(manager: manager);
        // The FFI reports whether it actually seeded (bool); the service's
        // contract is `Future<void>` — this proves the wrapper never
        // surfaces that value as its own return, matching the interface
        // signature.
        await service.seedDefaultsIfUnseeded();
        expect(manager.calls, contains('seedRelayDefaultsIfUnseeded'));
      },
    );

    test(
      'a seedDefaultsIfUnseeded failure is generic and never leaks',
      () async {
        final manager = _FakeCircleManager()
          ..seedRelayDefaultsIfUnseededThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.seedDefaultsIfUnseeded(),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to seed default relays.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — publish toggle', () {
    test('getPublishRelayList returns the manager value', () async {
      final manager = _FakeCircleManager()..getPublishRelayListResult = false;
      final service = NostrRelayPreferencesService(manager: manager);
      expect(await service.getPublishRelayList(RelayCategory.inbox), isFalse);
    });

    test('a getPublishRelayList failure is generic and never leaks', () async {
      final manager = _FakeCircleManager()
        ..getPublishRelayListThrows = Exception(_sensitiveRawError);
      final service = NostrRelayPreferencesService(manager: manager);
      await expectLater(
        service.getPublishRelayList(RelayCategory.inbox),
        throwsA(
          isA<RelayPreferencesException>()
              .having(
                (e) => e.message,
                'message',
                'Failed to read publish setting.',
              )
              .having(
                (e) => e.toString(),
                'toString()',
                isNot(contains('deadbeef')),
              ),
        ),
      );
    });

    test('setPublishRelayList forwards the category and value', () async {
      final manager = _FakeCircleManager();
      final service = NostrRelayPreferencesService(manager: manager);
      await service.setPublishRelayList(RelayCategory.keyPackage, value: false);
      expect(manager.lastRelayType, RelayTypeFfi.nip65);
      expect(manager.lastSetPublishValue, isFalse);
    });

    test('a setPublishRelayList failure is generic and never leaks', () async {
      final manager = _FakeCircleManager()
        ..setPublishRelayListThrows = Exception(_sensitiveRawError);
      final service = NostrRelayPreferencesService(manager: manager);
      await expectLater(
        service.setPublishRelayList(RelayCategory.inbox, value: true),
        throwsA(
          isA<RelayPreferencesException>()
              .having(
                (e) => e.message,
                'message',
                'Failed to update publish setting.',
              )
              .having(
                (e) => e.toString(),
                'toString()',
                isNot(contains('deadbeef')),
              ),
        ),
      );
    });
  });

  group('NostrRelayPreferencesService — publishTargets', () {
    test(
      "returns exactly the manager's targets (no public-default union — "
      'two-plane privacy model)',
      () async {
        final manager = _FakeCircleManager()
          ..relayPublishTargetsResult = const ['wss://only-mine.example'];
        final service = NostrRelayPreferencesService(manager: manager);
        final targets = await service.publishTargets(RelayCategory.inbox);
        expect(targets, ['wss://only-mine.example']);
      },
    );

    test('a publishTargets failure is generic and never leaks', () async {
      final manager = _FakeCircleManager()
        ..relayPublishTargetsThrows = Exception(_sensitiveRawError);
      final service = NostrRelayPreferencesService(manager: manager);
      await expectLater(
        service.publishTargets(RelayCategory.inbox),
        throwsA(
          isA<RelayPreferencesException>()
              .having((e) => e.message, 'message', 'Failed to resolve targets.')
              .having(
                (e) => e.toString(),
                'toString()',
                isNot(contains('deadbeef')),
              ),
        ),
      );
    });
  });

  group('NostrRelayPreferencesService — buildRelayListPublish', () {
    test('maps every field of a non-suppressed FFI response', () async {
      final manager = _FakeCircleManager()
        ..buildRelayListPublishResult = const BuiltRelayListEventFfi(
          suppressed: false,
          eventJson: '{"kind":10002}',
          eventIdHex: 'abc123',
          targets: ['wss://a.example'],
          kind: 10002,
          createdAtSecs: 1700000000,
        );
      final service = NostrRelayPreferencesService(manager: manager);
      final secret = Uint8List.fromList(List<int>.filled(32, 9));
      final result = await service.buildRelayListPublish(
        identitySecretBytes: secret,
        category: RelayCategory.keyPackage,
      );
      expect(result.suppressed, isFalse);
      expect(result.eventJson, '{"kind":10002}');
      expect(result.eventIdHex, 'abc123');
      expect(result.targets, ['wss://a.example']);
      expect(result.kind, 10002);
      expect(result.createdAtSecs, 1700000000);
      expect(manager.lastRelayType, RelayTypeFfi.nip65);
      expect(manager.lastBuildRelayListPublishSecret, secret);
    });

    test(
      'a suppressed FFI response (privacy toggle off) carries no event data '
      '— the caller must not be handed anything publishable',
      () async {
        final manager = _FakeCircleManager()
          ..buildRelayListPublishResult = const BuiltRelayListEventFfi(
            suppressed: true,
            targets: [],
          );
        final service = NostrRelayPreferencesService(manager: manager);
        final result = await service.buildRelayListPublish(
          identitySecretBytes: Uint8List(32),
          category: RelayCategory.inbox,
        );
        expect(result.suppressed, isTrue);
        expect(result.eventJson, isNull);
        expect(result.eventIdHex, isNull);
        expect(result.targets, isEmpty);
      },
    );

    test(
      'a buildRelayListPublish failure is generic and never leaks',
      () async {
        final manager = _FakeCircleManager()
          ..buildRelayListPublishThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.buildRelayListPublish(
            identitySecretBytes: Uint8List(32),
            category: RelayCategory.inbox,
          ),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to build publish request.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — recordPublishedRelayList', () {
    test('forwards every field unchanged to the manager', () async {
      final manager = _FakeCircleManager();
      final service = NostrRelayPreferencesService(manager: manager);
      await service.recordPublishedRelayList(
        identityPubkeyHex: 'deadbeef' * 8,
        kind: 10050,
        eventIdHex: 'cafe' * 16,
        publishedAtSecs: 1700000123,
      );
      expect(manager.lastRecordIdentityPubkeyHex, 'deadbeef' * 8);
      expect(manager.lastRecordKind, 10050);
      expect(manager.lastRecordEventIdHex, 'cafe' * 16);
      expect(manager.lastRecordPublishedAtSecs, 1700000123);
    });

    test(
      'a recordPublishedRelayList failure is generic and never leaks',
      () async {
        final manager = _FakeCircleManager()
          ..recordPublishedRelayListThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.recordPublishedRelayList(
            identityPubkeyHex: 'pk',
            kind: 10050,
            eventIdHex: 'id',
            publishedAtSecs: 1,
          ),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to record publication.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — buildUnpublishRelayList', () {
    test('maps every field of a non-suppressed FFI response', () async {
      final manager = _FakeCircleManager()
        ..buildUnpublishRelayListResult = const BuiltUnpublishFfi(
          suppressed: false,
          replacementEventJson: '{"empty":true}',
          deletionEventJson: '{"kind":5}',
          targets: ['wss://kept.example'],
        );
      final service = NostrRelayPreferencesService(manager: manager);
      final result = await service.buildUnpublishRelayList(
        identitySecretBytes: Uint8List(32),
        category: RelayCategory.inbox,
      );
      expect(result.suppressed, isFalse);
      expect(result.replacementEventJson, '{"empty":true}');
      expect(result.deletionEventJson, '{"kind":5}');
      expect(result.targets, ['wss://kept.example']);
    });

    test(
      'a buildUnpublishRelayList failure is generic and never leaks',
      () async {
        final manager = _FakeCircleManager()
          ..buildUnpublishRelayListThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.buildUnpublishRelayList(
            identitySecretBytes: Uint8List(32),
            category: RelayCategory.inbox,
          ),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to build unpublish request.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — buildRelayRemovalScrub', () {
    test(
      'forwards the dropped relays and maps the scrub-only (no '
      'replacement) response',
      () async {
        final manager = _FakeCircleManager()
          ..buildRelayRemovalScrubResult = const BuiltUnpublishFfi(
            suppressed: false,
            deletionEventJson: '{"kind":5,"scrub":true}',
            targets: ['wss://dropped.example'],
          );
        final service = NostrRelayPreferencesService(manager: manager);
        final result = await service.buildRelayRemovalScrub(
          identitySecretBytes: Uint8List(32),
          category: RelayCategory.inbox,
          droppedRelays: const ['wss://dropped.example'],
        );
        expect(manager.lastDroppedRelays, ['wss://dropped.example']);
        expect(result.suppressed, isFalse);
        expect(result.replacementEventJson, isNull);
        expect(result.deletionEventJson, '{"kind":5,"scrub":true}');
        expect(result.targets, ['wss://dropped.example']);
      },
    );

    test(
      'a buildRelayRemovalScrub failure is generic and never leaks',
      () async {
        final manager = _FakeCircleManager()
          ..buildRelayRemovalScrubThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.buildRelayRemovalScrub(
            identitySecretBytes: Uint8List(32),
            category: RelayCategory.inbox,
            droppedRelays: const ['wss://dropped.example'],
          ),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to build relay removal scrub.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });

  group('NostrRelayPreferencesService — profile pool status', () {
    test('maps counts field-for-field (never a relay URL)', () async {
      final manager = _FakeCircleManager()
        ..profilePoolStatusResult = const ProfilePoolStatusFfi(
          configured: 8,
          excluded: 3,
          usable: 5,
          isUnderflow: false,
        );
      final service = NostrRelayPreferencesService(manager: manager);
      final status = await service.profilePoolStatus();
      expect(status.configured, 8);
      expect(status.excluded, 3);
      expect(status.usable, 5);
      expect(status.isUnderflow, isFalse);
    });

    test('a profilePoolStatus failure is generic and never leaks', () async {
      final manager = _FakeCircleManager()
        ..profilePoolStatusThrows = Exception(_sensitiveRawError);
      final service = NostrRelayPreferencesService(manager: manager);
      await expectLater(
        service.profilePoolStatus(),
        throwsA(
          isA<RelayPreferencesException>()
              .having(
                (e) => e.message,
                'message',
                'Failed to read profile relay status.',
              )
              .having(
                (e) => e.toString(),
                'toString()',
                isNot(contains('deadbeef')),
              ),
        ),
      );
    });

    test('restoreDefaultProfileRelays delegates to the manager', () async {
      final manager = _FakeCircleManager();
      final service = NostrRelayPreferencesService(manager: manager);
      await service.restoreDefaultProfileRelays();
      expect(manager.calls, contains('restoreDefaultProfileRelays'));
    });

    test(
      'a restoreDefaultProfileRelays failure is generic and never leaks',
      () async {
        final manager = _FakeCircleManager()
          ..restoreDefaultProfileRelaysThrows = Exception(_sensitiveRawError);
        final service = NostrRelayPreferencesService(manager: manager);
        await expectLater(
          service.restoreDefaultProfileRelays(),
          throwsA(
            isA<RelayPreferencesException>()
                .having(
                  (e) => e.message,
                  'message',
                  'Failed to restore defaults.',
                )
                .having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(contains('deadbeef')),
                ),
          ),
        );
      },
    );
  });
}
