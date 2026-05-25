/// Cross-process barriers for multi-AVD E2E scenarios.
///
/// All synchronization is via observable Nostr events on the hermetic
/// strfry relay — never side channels (filesystem, environment, etc.).
/// This mirrors the production sync model exactly: in real Haven, Bob's
/// instance only learns about Alice's invitation when a gift-wrap event
/// shows up on his inbox relay.
library;

import 'dart:async';

import 'test_relay.dart';

/// Waits until the relay reports at least one kind-1059 (gift-wrap)
/// event addressed to [recipientPubkeyHex] via a `#p` tag.
///
/// Mirrors `NostrRelayService.fetchGiftWraps` filter semantics. Bob's
/// scenario calls this to gate `Accept` on the invitation actually
/// being on the wire (not just on Alice's local state).
Future<TestRelayEvent> waitForGiftWrap({
  required TestRelay relay,
  required String recipientPubkeyHex,
  Duration timeout = const Duration(seconds: 60),
}) =>
    relay.firstWhere(
      filter: <String, dynamic>{
        'kinds': <int>[1059],
        '#p': <String>[recipientPubkeyHex],
        'limit': 50,
      },
      timeout: timeout,
    );

/// Waits until the relay reports at least one kind-445 (Marmot group
/// message) on the given `h`-tagged Nostr group ID.
///
/// Useful for asserting that a publisher reached the relay before the
/// peer-side fetch attempts to read.
Future<TestRelayEvent> waitForGroupMessage({
  required TestRelay relay,
  required String nostrGroupIdHex,
  Duration timeout = const Duration(seconds: 30),
}) =>
    relay.firstWhere(
      filter: <String, dynamic>{
        'kinds': <int>[445],
        '#h': <String>[nostrGroupIdHex],
        'limit': 50,
      },
      timeout: timeout,
    );

/// Waits until the relay reports at least one kind-443 (KeyPackage)
/// authored by [authorPubkeyHex].
///
/// Used during circle-creation flows where Alice's instance needs to
/// see Bob's published KeyPackage before invoking `createCircle`.
Future<TestRelayEvent> waitForKeyPackage({
  required TestRelay relay,
  required String authorPubkeyHex,
  Duration timeout = const Duration(seconds: 30),
}) =>
    relay.firstWhere(
      filter: <String, dynamic>{
        'kinds': <int>[443],
        'authors': <String>[authorPubkeyHex],
        'limit': 5,
      },
      timeout: timeout,
    );
