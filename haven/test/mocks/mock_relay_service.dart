/// Mock implementation of [RelayService] for testing.
library;

import 'dart:async';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';

/// A mock [RelayService] for testing.
class MockRelayService implements RelayService {
  /// Creates a [MockRelayService].
  MockRelayService({
    this.groupMessages = const [],
    this.keyPackageResult,
    this.shouldThrowOnFetchKeyPackage = false,
    this.fetchKeyPackageException,
    this.checkEventResults = const {},
    this.shouldThrowOnCheckEvent = false,
  });

  /// Group messages to return from fetchGroupMessages.
  final List<String> groupMessages;

  /// KeyPackage to return from fetchKeyPackage (null = no account found).
  final KeyPackageData? keyPackageResult;

  /// Whether fetchKeyPackage should throw.
  final bool shouldThrowOnFetchKeyPackage;

  /// Custom exception to throw from fetchKeyPackage (defaults to
  /// [RelayServiceException]).
  final Exception? fetchKeyPackageException;

  /// Configurable results for [checkEventOnRelay].
  ///
  /// Keyed by `"$relayUrl:$eventKind"`.
  final Map<String, RelayEventCheck> checkEventResults;

  /// Whether checkEventOnRelay should throw.
  final bool shouldThrowOnCheckEvent;

  /// Optional completer to control when fetchKeyPackage resolves.
  ///
  /// When set, fetchKeyPackage waits for this completer before returning.
  /// Complete it in tests to simulate network delay.
  Completer<void>? fetchKeyPackageGate;

  /// Optional handler for [fetchGiftWrapsPerRelay].
  ///
  /// When null, every relay is reported as responded with no events. Set
  /// this to simulate unreachable relays or per-relay gift-wrap payloads.
  Future<List<RelayGiftWrapFetch>> Function(List<String> relays)?
  fetchGiftWrapsPerRelayHandler;

  /// Optional per-relay gates for [checkEventOnRelay], keyed by relay URL.
  ///
  /// When a completer is present for a relay, every kind-check on that relay
  /// awaits it before returning — letting a test observe the ring's
  /// incremental per-relay progress (one relay resolved while another is still
  /// in flight).
  final Map<String, Completer<void>> checkEventGates = {};

  /// Tracks method calls for verification.
  final List<String> methodCalls = [];

  /// Published events.
  final List<String> publishedEvents = [];

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    methodCalls.add('fetchGroupMessages');
    return groupMessages;
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    methodCalls.add('publishEvent');
    publishedEvents.add(eventJson);
    return PublishResult(
      eventId: 'mock-event-id',
      acceptedBy: relays,
      rejectedBy: const [],
      failed: const [],
    );
  }

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {
    methodCalls.add('publishEventFireAndForget');
    publishedEvents.add(eventJson);
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    methodCalls.add('publishWelcome');
    return const PublishResult(
      eventId: 'mock-event-id',
      acceptedBy: ['wss://relay.example.com'],
      rejectedBy: [],
      failed: [],
    );
  }

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async {
    methodCalls.add('fetchKeyPackageRelays');
    return [];
  }

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async {
    methodCalls.add('fetchNip65Relays');
    return [];
  }

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async {
    methodCalls.add('fetchKeyPackage');
    if (fetchKeyPackageGate != null) {
      await fetchKeyPackageGate!.future;
    }
    if (shouldThrowOnFetchKeyPackage) {
      throw fetchKeyPackageException ??
          const RelayServiceException('Network error');
    }
    return keyPackageResult;
  }

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    methodCalls.add('fetchGiftWraps');
    return [];
  }

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    methodCalls.add('fetchGiftWrapsPerRelay');
    final handler = fetchGiftWrapsPerRelayHandler;
    if (handler != null) return handler(relays);
    return [
      for (final r in relays)
        RelayGiftWrapFetch(relayUrl: r, responded: true, events: const []),
    ];
  }

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async {
    methodCalls.add('checkEventOnRelay:$relayUrl:$eventKind');
    await checkEventGates[relayUrl]?.future;
    if (shouldThrowOnCheckEvent) {
      throw const RelayServiceException('Check event failed');
    }
    final key = '$relayUrl:$eventKind';
    return checkEventResults[key] ??
        RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);
  }

  @override
  Future<void> disconnectRelay(String url) async {
    methodCalls.add('disconnectRelay:$url');
  }
}
