/// Host-side proof that a malformed MLS group id is rejected BEFORE it is
/// announced to the recording proxy.
///
/// `TestRelay.announceMlsGroupId` is the drive half of the control channel the
/// wire-correlation oracle's C5.8 depends on: the oracle asserts that the real
/// MLS group id never appears on the wire, which it can only do if the drive
/// tells it what that id is (its absence from the journal *is* the assertion,
/// so the value cannot be recovered from there). The send path itself needs an
/// emulator, a relay and the proxy, so it runs only in an E2E lane — but the
/// validation in front of it is pure, and it is the part that can fail
/// SILENTLY.
///
/// A rejected id makes the lane red. An accepted-but-wrong id is worse: a
/// too-short literal makes the oracle report a leak on frames that never
/// carried the id, and a wrong-case one makes it search for a string no frame
/// can contain, which reads as a clean Rule-4 result. Both directions are
/// pinned below.
///
/// Runs under plain `flutter test`: no Rust bridge, no relay, no device.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/test_relay.dart';

/// A realistic 32-byte MLS group id: every group Haven creates carries one.
Uint8List _realisticId() =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xff));

void main() {
  group('encodeWireMlsGroupId — accepts a real id', () {
    test('encodes 32 bytes to 64 lowercase hex characters', () {
      final hex = encodeWireMlsGroupId(_realisticId());
      expect(hex, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hex), isTrue);
    });

    test('round-trips the exact byte order', () {
      // Order matters: the host greps for this literal, so a reversed or
      // regrouped encoding would search for a value the journal cannot hold
      // and report clean forever.
      final hex = encodeWireMlsGroupId(
        Uint8List.fromList(<int>[
          0x00, 0x01, 0x0f, 0x10, 0x7f, 0x80, 0xfe, 0xff, //
          0x00, 0x01, 0x0f, 0x10, 0x7f, 0x80, 0xfe, 0xff,
        ]),
      );
      expect(hex, '00010f107f80feff00010f107f80feff');
    });

    test('pads single-digit bytes so the length stays even', () {
      // The classic encoder bug: `toRadixString(16)` alone drops the leading
      // zero, shortening the literal and shifting every byte after it.
      final hex = encodeWireMlsGroupId(
        Uint8List.fromList(List<int>.filled(16, 0x05)),
      );
      expect(hex, '05' * 16);
      expect(hex.length.isEven, isTrue);
    });

    test('accepts exactly the minimum length', () {
      expect(
        encodeWireMlsGroupId(
          Uint8List.fromList(List<int>.filled(kMinWireMlsGroupIdBytes, 0xab)),
        ),
        hasLength(kMinWireMlsGroupIdBytes * 2),
      );
    });
  });

  group('encodeWireMlsGroupId — rejects an id the oracle cannot use', () {
    test('rejects an empty id', () {
      expect(
        () => encodeWireMlsGroupId(const <int>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a truncated id one byte below the floor', () {
      expect(
        () => encodeWireMlsGroupId(
          List<int>.filled(kMinWireMlsGroupIdBytes - 1, 0x11),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a short id — the pre-accept gift-wrap stand-in shape', () {
      // Pending invitations are keyed by the gift-wrap id stand-in, not the
      // real group id (DM-4). Announcing one of those would have the oracle
      // scan for a value that is not the thing Rule 4 protects.
      expect(
        () => encodeWireMlsGroupId(List<int>.filled(8, 0x22)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a value above a byte', () {
      final bad = List<int>.filled(32, 0x33)..[7] = 256;
      expect(
        () => encodeWireMlsGroupId(bad),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a negative value', () {
      final bad = List<int>.filled(32, 0x33)..[0] = -1;
      expect(
        () => encodeWireMlsGroupId(bad),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('encodeWireMlsGroupId — errors leak nothing (Security Rule 6)', () {
    test('the rejection message carries no part of the id', () {
      // A validation failure must not become the leak. The bytes below hex to
      // a distinctive literal; none of it — nor any 4-character run of it —
      // may appear in what is thrown, because these messages end up in the
      // drive log, which CI uploads.
      final id = List<int>.filled(kMinWireMlsGroupIdBytes - 1, 0xde);
      final hex = 'de' * (kMinWireMlsGroupIdBytes - 1);
      expect(
        () => encodeWireMlsGroupId(id),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'rendered error',
            allOf(isNot(contains(hex)), isNot(contains('dede'))),
          ),
        ),
      );
    });

    test('the out-of-range message names the position, not the value', () {
      final bad = List<int>.filled(32, 0x44)..[3] = 999;
      expect(
        () => encodeWireMlsGroupId(bad),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'rendered error',
            allOf(
              contains('3'),
              isNot(contains('999')),
              isNot(contains('4444')),
            ),
          ),
        ),
      );
    });
  });

  group('the announce contract the proxy is built against', () {
    test('the minimum is long enough not to collide with frame content', () {
      // The floor exists so the literal cannot occur by chance inside an event
      // id or a pubkey. 32 hex characters is 128 bits; anything materially
      // shorter would turn C5.8 into a source of false leak reports.
      expect(kMinWireMlsGroupIdBytes * 2, greaterThanOrEqualTo(32));
    });

    test('an id that passes is exactly what the frame will carry', () {
      // The frame is ["HAVEN_WIRE_MLS_GROUP_ID","<lowercase-hex>"]; the proxy
      // matches its ack on the same string. Anything the encoder returns must
      // therefore already satisfy the whole contract — lowercase, even, long
      // enough — with no further normalisation at the send site.
      final hex = encodeWireMlsGroupId(_realisticId());
      expect(hex, hex.toLowerCase());
      expect(hex.length.isEven, isTrue);
      expect(hex.length, greaterThanOrEqualTo(kMinWireMlsGroupIdBytes * 2));
    });
  });

  test('an id longer than the proxy accepts is refused before transmission', () {
    // Rust caps at MLS_GROUP_ID_MAX_HEX = 128 hex = 64 bytes. Without a mirror
    // here, Dart transmits and the proxy refuses silently; the caller then sees
    // an ack timeout that reads as "the proxy is broken".
    expect(
      () => encodeWireMlsGroupId(List<int>.filled(65, 0xAB)),
      throwsA(isA<ArgumentError>()),
      reason: 'the two validators must fail on the same inputs',
    );
    expect(
      encodeWireMlsGroupId(List<int>.filled(64, 0xAB)).length,
      128,
      reason: 'exactly at the cap must still be accepted',
    );
  });
}
