/// Integration test for [NostrCircleService.removeMember] fail-closed
/// behaviour when circle relays are unavailable.
///
/// ## What this tests
///
/// `NostrCircleService.removeMember` is the admin-side eviction path that
/// publishes a kind-445 RemoveMember commit to the circle's relays. The
/// production guard at `nostr_circle_service.dart:592` says:
///
/// ```dart
/// if (relays == null || relays.isEmpty) {
///   debugPrint('Circle relays unavailable — aborting remove');
///   throw const CircleServiceException('Failed to remove member');
/// }
/// ```
///
/// This guard is critical for **defence-in-depth** privacy: if we ever lost
/// the circle's relay list (storage corruption, unmigrated record, FFI
/// throw), falling back to `DEFAULT_RELAYS` would leak the kind-445 commit
/// (and therefore the `nostr_group_id` h-tag) to relays that have no other
/// reason to know this group exists. That is a relay-level group-membership
/// disclosure. The contract is: **fail closed — never broadcast to a
/// dubious relay set.**
///
/// ## Test strategy
///
/// We exercise the real Rust FFI boundary so the test reflects production
/// reality. Rather than monkey-patching the private `_circleRelays`
/// resolver, we call `removeMember` for a `mlsGroupId` that has no
/// corresponding circle row — `_circleRelays` calls `manager.getCircle(...)`
/// which returns `null`, the resolver returns `null`, and the empty/null
/// guard fires.
///
/// The injected `_RecordingRelayService` is the strongest part of the test:
/// it records every `publishEvent` call. After the throw, we assert the
/// recorder is empty — proving no fallback to `DEFAULT_RELAYS` ever
/// reached the relay layer. The exception alone is necessary but not
/// sufficient; absence of the publish call is what proves "fail closed".
///
/// ## Platform requirements
///
/// `CircleManagerFfi.newInstance` calls `init_keyring_store()` and
/// `get_or_create_circle_db_key()` internally; both require a live platform
/// keyring backend. If unavailable the test skips cleanly.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:integration_test/integration_test.dart';

/// [DataDirectoryProvider] that returns a fixed path provided by the test.
class _FixedDataDirectoryProvider implements DataDirectoryProvider {
  _FixedDataDirectoryProvider(this._path);
  final String _path;

  @override
  Future<String> getDataDirectory() async => _path;
}

/// [RelayService] that records every publish-style call so the test can
/// assert NO relay traffic was attempted on the fail-closed path.
///
/// Read-side methods throw [UnimplementedError] — `removeMember` should
/// not exercise them.
class _RecordingRelayService implements RelayService {
  final List<({String eventJson, List<String> relays})> publishEventCalls = [];
  final List<({String eventJson, List<String> relays})>
  publishFireAndForgetCalls = [];
  final List<GiftWrappedWelcome> publishWelcomeCalls = [];

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishEventCalls.add((eventJson: eventJson, relays: List.of(relays)));
    return const PublishResult(
      eventId: '',
      acceptedBy: [],
      rejectedBy: [],
      failed: [],
    );
  }

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishFireAndForgetCalls.add((
      eventJson: eventJson,
      relays: List.of(relays),
    ));
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    publishWelcomeCalls.add(welcomeEvent);
    return const PublishResult(
      eventId: '',
      acceptedBy: [],
      rejectedBy: [],
      failed: [],
    );
  }

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) => throw UnimplementedError();

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) => throw UnimplementedError();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  group('NostrCircleService.removeMember (fail-closed contract)', () {
    test(
      'throws CircleServiceException and does not fall back to DEFAULT_RELAYS '
      'when the circle has no relays available',
      () async {
        // ----------------------------------------------------------------
        // Skip if platform keyring is unavailable — same pattern used by
        // encryption_pipeline_test.dart.
        // ----------------------------------------------------------------
        try {
          await initKeyringStore();
        } on Object catch (e) {
          debugPrint(
            '[circle_service_remove_member_test] Keyring unavailable, '
            'skipping: ${e.runtimeType}',
          );
          return;
        }

        final dataDir = await Directory.systemTemp.createTemp(
          'haven_remove_member_failclosed_',
        );

        try {
          final relayRecorder = _RecordingRelayService();
          final service = NostrCircleService(
            relayService: relayRecorder,
            dataDirectoryProvider: _FixedDataDirectoryProvider(dataDir.path),
          );

          await service.initialize();

          // Fabricate a non-existent circle ID. `_circleRelays` calls
          // `manager.getCircle(...)` which returns null for any ID we did
          // NOT create — the empty/null guard then fires before any
          // FFI staging or relay publish.
          final missingMlsGroupId = List<int>.generate(32, (i) => i + 1);

          // Any 32-byte hex pubkey will do — we never reach the FFI staging
          // call where pubkey validity matters.
          final memberPubkeyHex = 'aa' * 32;

          // ----------------------------------------------------------------
          // Assertion 1: removeMember must throw the generic
          // CircleServiceException with the redacted message — no FFI
          // detail leakage in the user-facing string.
          // ----------------------------------------------------------------
          await expectLater(
            service.removeMember(
              mlsGroupId: missingMlsGroupId,
              memberPubkeyHex: memberPubkeyHex,
            ),
            throwsA(
              isA<CircleServiceException>().having(
                (e) => e.message,
                'message',
                'Failed to remove member',
              ),
            ),
          );

          // ----------------------------------------------------------------
          // Assertion 2 (the load-bearing one): no relay-publish was
          // attempted. If a regression let `removeMember` fall back to
          // DEFAULT_RELAYS, the recorder would have at least one entry.
          // Empty == fail-closed contract upheld.
          // ----------------------------------------------------------------
          expect(
            relayRecorder.publishEventCalls,
            isEmpty,
            reason:
                'removeMember must NOT fall back to DEFAULT_RELAYS when the '
                'circle relay list is unavailable. publishEvent was called '
                '${relayRecorder.publishEventCalls.length} time(s) — this is '
                'a relay-level group-membership disclosure. See '
                'docs/LOCATION_SHARING_SECURITY_BACKLOG.md.',
          );

          // Defence in depth: the fire-and-forget and welcome paths must
          // also stay untouched on this code path.
          expect(
            relayRecorder.publishFireAndForgetCalls,
            isEmpty,
            reason: 'removeMember must not use fire-and-forget publishing',
          );
          expect(
            relayRecorder.publishWelcomeCalls,
            isEmpty,
            reason:
                'removeMember (eviction) must not invoke welcome publishing',
          );
        } finally {
          // Best-effort cleanup of the temp data directory.
          try {
            await dataDir.delete(recursive: true);
          } on Object catch (_) {
            // Ignore cleanup failures — temp dirs get cleaned by the OS.
          }
        }
      },
    );
  });
}
