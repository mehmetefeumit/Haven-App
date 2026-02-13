/// Mock implementation of [RelayService] for testing.
library;

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';

/// A mock [RelayService] for testing.
class MockRelayService implements RelayService {
  /// Creates a [MockRelayService].
  MockRelayService({this.groupMessages = const []});

  /// Group messages to return from fetchGroupMessages.
  final List<String> groupMessages;

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
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async {
    methodCalls.add('fetchKeyPackage');
    return null;
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
}
