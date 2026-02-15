/// Relay status provider for monitoring event publication.
///
/// Tracks per-relay publication status for KeyPackage (443) and
/// relay list (10051) events.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';

/// Status of an event check on a relay.
enum EventCheckStatus {
  /// Not yet checked.
  pending,

  /// Currently checking.
  checking,

  /// Event found on the relay.
  found,

  /// Event not found on the relay.
  notFound,

  /// Error occurred during check.
  error,
}

/// Per-kind event check result.
@immutable
class KindCheckResult {
  /// Creates a [KindCheckResult].
  const KindCheckResult({
    this.status = EventCheckStatus.pending,
    this.newestTimestamp,
    this.errorMessage,
  });

  /// The check status.
  final EventCheckStatus status;

  /// Newest event timestamp, if found.
  final DateTime? newestTimestamp;

  /// Error message, if status is [EventCheckStatus.error].
  final String? errorMessage;

  /// Creates a copy with the given fields replaced.
  KindCheckResult copyWith({
    EventCheckStatus? status,
    DateTime? newestTimestamp,
    String? errorMessage,
  }) {
    return KindCheckResult(
      status: status ?? this.status,
      newestTimestamp: newestTimestamp ?? this.newestTimestamp,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Per-relay event status for both kind 443 and 10051.
@immutable
class RelayEventStatus {
  /// Creates a [RelayEventStatus].
  const RelayEventStatus({
    required this.relayUrl,
    this.keyPackage = const KindCheckResult(),
    this.relayList = const KindCheckResult(),
  });

  /// The relay URL.
  final String relayUrl;

  /// Status of kind 443 (KeyPackage) on this relay.
  final KindCheckResult keyPackage;

  /// Status of kind 10051 (relay list) on this relay.
  final KindCheckResult relayList;

  /// Creates a copy with the given fields replaced.
  RelayEventStatus copyWith({
    KindCheckResult? keyPackage,
    KindCheckResult? relayList,
  }) {
    return RelayEventStatus(
      relayUrl: relayUrl,
      keyPackage: keyPackage ?? this.keyPackage,
      relayList: relayList ?? this.relayList,
    );
  }
}

/// Overall relay status state.
@immutable
class RelayStatusState {
  /// Creates a [RelayStatusState].
  const RelayStatusState({
    required this.relays,
    this.isRefreshing = false,
    this.lastChecked,
  });

  /// Per-relay event status.
  final List<RelayEventStatus> relays;

  /// Whether a refresh is currently in progress.
  final bool isRefreshing;

  /// When the last check completed.
  final DateTime? lastChecked;

  /// Creates a copy with the given fields replaced.
  RelayStatusState copyWith({
    List<RelayEventStatus>? relays,
    bool? isRefreshing,
    DateTime? lastChecked,
  }) {
    return RelayStatusState(
      relays: relays ?? this.relays,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }
}

/// Provider for relay event publication status.
final relayStatusProvider =
    AsyncNotifierProvider<RelayStatusNotifier, RelayStatusState>(
      RelayStatusNotifier.new,
    );

/// Notifier for relay event publication status.
class RelayStatusNotifier extends AsyncNotifier<RelayStatusState> {
  @override
  Future<RelayStatusState> build() async {
    return RelayStatusState(
      relays: defaultRelays
          .map((url) => RelayEventStatus(relayUrl: url))
          .toList(),
    );
  }

  /// Checks all relays for KeyPackage and relay list events.
  Future<void> checkAllRelays() async {
    final identityAsync = ref.read(identityProvider);
    final Identity? identity;
    if (identityAsync.hasValue) {
      identity = identityAsync.value;
    } else {
      // Wait for identity to load if still pending
      identity = await ref.read(identityProvider.future);
    }
    if (identity == null) return;

    final relayService = ref.read(relayServiceProvider);
    final currentState = state.valueOrNull;
    if (currentState == null) return;

    // Set refreshing flag
    state = AsyncData(currentState.copyWith(isRefreshing: true));

    var relays = currentState.relays;

    for (var i = 0; i < relays.length; i++) {
      final relay = relays[i];

      // Mark both kinds as checking
      relays = List.of(relays);
      relays[i] = relay.copyWith(
        keyPackage: const KindCheckResult(status: EventCheckStatus.checking),
        relayList: const KindCheckResult(status: EventCheckStatus.checking),
      );
      state = AsyncData(currentState.copyWith(relays: relays));

      // Check kind 443 (KeyPackage)
      KindCheckResult kpResult;
      try {
        final check = await relayService.checkEventOnRelay(
          relayUrl: relay.relayUrl,
          authorPubkey: identity.pubkeyHex,
          eventKind: 443,
        );
        kpResult = KindCheckResult(
          status: check.found
              ? EventCheckStatus.found
              : EventCheckStatus.notFound,
          newestTimestamp: check.newestTimestamp,
        );
      } on Object catch (e) {
        debugPrint('Error checking kind 443 on ${relay.relayUrl}: $e');
        kpResult = const KindCheckResult(
          status: EventCheckStatus.error,
          errorMessage: 'Check failed',
        );
      }

      // Check kind 10051 (relay list)
      KindCheckResult rlResult;
      try {
        final check = await relayService.checkEventOnRelay(
          relayUrl: relay.relayUrl,
          authorPubkey: identity.pubkeyHex,
          eventKind: 10051,
        );
        rlResult = KindCheckResult(
          status: check.found
              ? EventCheckStatus.found
              : EventCheckStatus.notFound,
          newestTimestamp: check.newestTimestamp,
        );
      } on Object catch (e) {
        debugPrint('Error checking kind 10051 on ${relay.relayUrl}: $e');
        rlResult = const KindCheckResult(
          status: EventCheckStatus.error,
          errorMessage: 'Check failed',
        );
      }

      // Update this relay's results
      relays = List.of(relays);
      relays[i] = relay.copyWith(keyPackage: kpResult, relayList: rlResult);
      state = AsyncData(currentState.copyWith(relays: relays));
    }

    // Done — clear refreshing flag and set lastChecked
    state = AsyncData(
      currentState.copyWith(
        relays: relays,
        isRefreshing: false,
        lastChecked: DateTime.now(),
      ),
    );
  }
}
