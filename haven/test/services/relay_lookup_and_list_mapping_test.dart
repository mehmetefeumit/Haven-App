// The FFI-to-service mappings the discoverability fix depends on: an invite
// lookup that could not finish never reads as "no account", a relay-list
// tick never reads as current unless an own relay confirmed it, and a
// KeyPackage tick carries whether this device's package is what is served.
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

const _member = MemberKeyPackageFfi(
  keyPackageJson: '{"kind":30443}',
  inboxRelays: ['wss://inbox.example.com'],
  nip65Relays: ['wss://nip65.example.com'],
  nip65WriteRelays: ['wss://write.example.com'],
  authorNpub: 'npub1verifiedauthor',
);

RelayListCategoryOutcomeFfi _category(
  RelayListActionFfi action, {
  bool ownConfirmed = false,
  int relayErrors = 0,
  int respondersProbed = 0,
}) => RelayListCategoryOutcomeFfi(
  action: action,
  respondersProbed: respondersProbed,
  relaysHealed: 0,
  relayErrors: relayErrors,
  ownConfirmed: ownConfirmed,
);

void main() {
  group('keyPackageDataOf', () {
    test('found carries the verified author and every relay list', () {
      final data = keyPackageDataOf(
        const MemberLookupFfi(
          verdict: MemberLookupVerdictFfi.found,
          member: _member,
        ),
      )!;
      expect(data.pubkey, 'npub1verifiedauthor');
      expect(data.eventJson, _member.keyPackageJson);
      expect(data.relays, _member.inboxRelays);
      expect(data.nip65Relays, _member.nip65Relays);
      expect(data.nip65WriteRelays, _member.nip65WriteRelays);
    });

    test('not found — absence proven — is null', () {
      expect(
        keyPackageDataOf(
          const MemberLookupFfi(verdict: MemberLookupVerdictFfi.notFound),
        ),
        isNull,
      );
    });

    test(
      'an unfinished lookup is the retryable failure, never "no account"',
      () {
        expect(
          () => keyPackageDataOf(
            const MemberLookupFfi(
              verdict: MemberLookupVerdictFfi.lookupIncomplete,
            ),
          ),
          throwsA(isA<RelayServiceException>()),
        );
      },
    );
  });

  group('mapRelayListCategory', () {
    test('every FFI action maps to its own service action', () {
      final expected = {
        RelayListActionFfi.suppressed: RelayListMaintenanceAction.suppressed,
        RelayListActionFfi.alreadyCurrent:
            RelayListMaintenanceAction.alreadyCurrent,
        RelayListActionFfi.republished: RelayListMaintenanceAction.republished,
        RelayListActionFfi.awaitingResetAcknowledgement:
            RelayListMaintenanceAction.awaitingResetAcknowledgement,
        RelayListActionFfi.nothingConfigured:
            RelayListMaintenanceAction.nothingConfigured,
        RelayListActionFfi.unacknowledged:
            RelayListMaintenanceAction.unacknowledged,
      };
      expect(expected.keys, containsAll(RelayListActionFfi.values));
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(mapRelayListCategory(_category(key)).action, value);
      }
    });

    test('a local read failure Rust labels suppressed is a failure, not the '
        "user's choice", () {
      final c = mapRelayListCategory(
        _category(RelayListActionFfi.suppressed, relayErrors: 1),
      );
      expect(c.action, RelayListMaintenanceAction.failed);
      expect(c.needsPromptRetry, isTrue);
    });

    test('own confirmation and the tallies are carried', () {
      final c = mapRelayListCategory(
        _category(
          RelayListActionFfi.republished,
          ownConfirmed: true,
          respondersProbed: 3,
          relayErrors: 1,
        ),
      );
      expect(c.ownConfirmed, isTrue);
      expect(c.respondersProbed, 3);
      expect(c.relayErrors, 1);
      expect(c.needsPromptRetry, isFalse);
    });

    test('a list only a lookup relay took is not confirmed, and retries', () {
      final c = mapRelayListCategory(
        _category(RelayListActionFfi.republished, respondersProbed: 1),
      );
      expect(c.ownConfirmed, isFalse);
      expect(c.needsPromptRetry, isTrue);
    });
  });

  group('classifyKeyPackageMaintenance carries publishedCurrent', () {
    KpMaintenanceOutcomeFfi ffi(
      KpMaintenanceActionFfi action, {
      required bool publishedCurrent,
      int relaysHealed = 0,
    }) => KpMaintenanceOutcomeFfi(
      action: action,
      canonicalOnRelays: 1,
      respondersProbed: 1,
      relaysTargeted: 1,
      relaysHealed: relaysHealed,
      relayErrors: 0,
      expiredInitKeyPurged: false,
      publishedCurrent: publishedCurrent,
      retiredMalformedSlot: false,
    );

    test('an adopt-only tick is healthy bookkeeping, never current', () {
      final o = classifyKeyPackageMaintenance(
        ffi(KpMaintenanceActionFfi.seededD, publishedCurrent: false),
      );
      expect(o, isA<KeyPackageMaintenanceHealthy>());
      expect(o.publishedCurrent, isFalse);
    });

    test('a healthy tick serving this device\'s package is current', () {
      final o = classifyKeyPackageMaintenance(
        ffi(KpMaintenanceActionFfi.alreadyHealthy, publishedCurrent: true),
      );
      expect(o.publishedCurrent, isTrue);
    });

    test('an acknowledged publish is current', () {
      final o = classifyKeyPackageMaintenance(
        ffi(
          KpMaintenanceActionFfi.republishedFreshD,
          publishedCurrent: true,
          relaysHealed: 1,
        ),
      );
      expect(o, isA<KeyPackageMaintenancePublished>());
      expect(o.publishedCurrent, isTrue);
    });

    test('a publish nobody acknowledged is never current', () {
      final o = classifyKeyPackageMaintenance(
        ffi(KpMaintenanceActionFfi.republishedFreshD, publishedCurrent: true),
      );
      expect(o, isA<KeyPackageMaintenanceFailed>());
      expect(o.publishedCurrent, isFalse);
    });
  });
}
