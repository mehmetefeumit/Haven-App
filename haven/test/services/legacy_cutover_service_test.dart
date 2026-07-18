/// Tests for [LegacyCutoverService] — the DM-4c once-only Dark Matter
/// cutover guard.
///
/// Covers:
/// (a) marker unset + no identity → no-op, destroy never called
/// (b) marker unset + identity present → destroy called, marker set,
///     explainer owed (`true`)
/// (c) marker unset + identity present + destroy throws → marker stays
///     unset, explainer NOT owed (`false`)
/// (d) marker already set → no-op regardless of identity, destroy never
///     called again
/// (e) marker never stores any secret/id — assert the stored value is a
///     plain bool
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/legacy_cutover_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Sets up fake [SharedPreferences] with the given initial values, then
  /// constructs a [LegacyCutoverService] with an injected destroy function
  /// that records calls and resolves per [destroyBehavior].
  Future<
    ({
      LegacyCutoverService service,
      SharedPreferences prefs,
      int Function() destroyCalls,
    })
  >
  makeService({
    Map<String, Object> prefsValues = const {},
    Future<void> Function()? destroyBehavior,
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final service = LegacyCutoverService(
      prefs: prefs,
      destroyLegacyMls: ({required String dataDir}) async {
        calls++;
        if (destroyBehavior != null) await destroyBehavior();
      },
    );
    return (service: service, prefs: prefs, destroyCalls: () => calls);
  }

  group('isDone', () {
    test('returns false when the marker key is absent', () async {
      final (:service, prefs: _, destroyCalls: _) = await makeService();
      expect(service.isDone, isFalse);
    });

    test('returns false when the marker is explicitly false', () async {
      final (:service, prefs: _, destroyCalls: _) = await makeService(
        prefsValues: {kLegacyCutoverDoneKey: false},
      );
      expect(service.isDone, isFalse);
    });

    test('returns true when the marker is true', () async {
      final (:service, prefs: _, destroyCalls: _) = await makeService(
        prefsValues: {kLegacyCutoverDoneKey: true},
      );
      expect(service.isDone, isTrue);
    });
  });

  group('runIfNeeded', () {
    test(
      'no-ops (does not call destroy) when no identity is present yet',
      () async {
        final (:service, prefs: _, :destroyCalls) = await makeService();

        final showExplainer = await service.runIfNeeded(
          dataDir: '/fake/dir',
          hasIdentity: false,
        );

        expect(showExplainer, isFalse);
        expect(destroyCalls(), 0);
        expect(
          service.isDone,
          isFalse,
          reason: 'a no-identity call must not set the marker either',
        );
      },
    );

    test(
      'calls destroy, sets the marker, and reports the explainer is owed '
      'when an identity is present and the marker is unset',
      () async {
        final (:service, prefs: _, :destroyCalls) = await makeService();

        final showExplainer = await service.runIfNeeded(
          dataDir: '/fake/dir',
          hasIdentity: true,
        );

        expect(showExplainer, isTrue);
        expect(destroyCalls(), 1);
        expect(service.isDone, isTrue);
      },
    );

    test(
      'leaves the marker unset and does not owe the explainer when destroy '
      'throws a genuine failure',
      () async {
        final (:service, prefs: _, :destroyCalls) = await makeService(
          destroyBehavior: () async =>
              throw Exception('locked file / unavailable keyring'),
        );

        final showExplainer = await service.runIfNeeded(
          dataDir: '/fake/dir',
          hasIdentity: true,
        );

        expect(showExplainer, isFalse);
        expect(destroyCalls(), 1);
        expect(
          service.isDone,
          isFalse,
          reason: 'a genuine destroy failure must leave the marker unset so '
              'the next launch retries',
        );
      },
    );

    test(
      'no-ops once the marker is already set, even with an identity present',
      () async {
        final (:service, prefs: _, :destroyCalls) = await makeService(
          prefsValues: {kLegacyCutoverDoneKey: true},
        );

        final showExplainer = await service.runIfNeeded(
          dataDir: '/fake/dir',
          hasIdentity: true,
        );

        expect(showExplainer, isFalse);
        expect(
          destroyCalls(),
          0,
          reason: 'the destructive call must never run a second time',
        );
      },
    );

    test('is idempotent across repeated calls after success', () async {
      final (:service, prefs: _, :destroyCalls) = await makeService();

      final first = await service.runIfNeeded(
        dataDir: '/fake/dir',
        hasIdentity: true,
      );
      final second = await service.runIfNeeded(
        dataDir: '/fake/dir',
        hasIdentity: true,
      );

      expect(first, isTrue);
      expect(second, isFalse, reason: 'the marker is now set — no re-run');
      expect(destroyCalls(), 1);
    });
  });

  group('privacy — marker is boolean-only', () {
    test('the persisted value is a plain bool, never an identifier', () async {
      final (:service, :prefs, destroyCalls: _) = await makeService();

      await service.runIfNeeded(dataDir: '/fake/dir', hasIdentity: true);

      final stored = prefs.get(kLegacyCutoverDoneKey);
      expect(stored, isA<bool>());
      expect(stored, isTrue);
    });
  });
}
