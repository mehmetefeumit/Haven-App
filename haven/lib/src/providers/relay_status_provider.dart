/// Relay status provider for monitoring event publication.
///
/// Tracks per-relay publication status for KeyPackage (443) and
/// relay list (10051) events.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/relays.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/relay_service.dart';

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

/// Per-relay event status for kinds 443 (KeyPackage), 10051 (KP relay
/// list), and 10050 (Inbox relay list).
@immutable
class RelayEventStatus {
  /// Creates a [RelayEventStatus].
  const RelayEventStatus({
    required this.relayUrl,
    this.keyPackage = const KindCheckResult(),
    this.relayList = const KindCheckResult(),
    this.inboxRelayList = const KindCheckResult(),
  });

  /// The relay URL.
  final String relayUrl;

  /// Status of kind 443 (KeyPackage) on this relay.
  final KindCheckResult keyPackage;

  /// Status of kind 10051 (KeyPackage relay list) on this relay.
  final KindCheckResult relayList;

  /// Status of kind 10050 (NIP-17 Inbox relay list) on this relay.
  final KindCheckResult inboxRelayList;

  /// Creates a copy with the given fields replaced.
  RelayEventStatus copyWith({
    KindCheckResult? keyPackage,
    KindCheckResult? relayList,
    KindCheckResult? inboxRelayList,
  }) {
    return RelayEventStatus(
      relayUrl: relayUrl,
      keyPackage: keyPackage ?? this.keyPackage,
      relayList: relayList ?? this.relayList,
      inboxRelayList: inboxRelayList ?? this.inboxRelayList,
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
  /// Generation counter incremented on every [`checkAllRelays`] call.
  /// Inflight checks compare against this and discard their per-relay
  /// state mutations if a newer check has started — prevents two
  /// concurrent refreshes from racing on `state` and prevents a check
  /// from continuing to mutate state after the user navigates away.
  int _checkGeneration = 0;

  @override
  Future<RelayStatusState> build() async {
    // Coupling to the relay-preferences invalidator: when the user
    // changes their relay lists, the status page rebuilds with the new
    // union.
    ref.watch(relayStatusInvalidatorProvider);
    // Source the relays to monitor from the union of the user's two
    // configured lists. Defaults are still surfaced because they are
    // included in the publish target union for both kind 10050 / 10051
    // events. Falls back to defaults if both lists are empty.
    final inbox = await ref.read(inboxRelaysProvider.future);
    final keyPackage = await ref.read(keyPackageRelaysProvider.future);
    var union = <String>{...inbox, ...keyPackage}.toList();
    if (union.isEmpty) {
      union = defaultRelays;
    }
    return RelayStatusState(
      relays: union.map((url) => RelayEventStatus(relayUrl: url)).toList(),
    );
  }

  /// Checks all relays for KeyPackage and relay-list events.
  ///
  /// Per-relay checks fan out via [`Future.wait`] so the overall refresh
  /// completes in O(slowest_relay) instead of O(sum_of_relays). Every
  /// call increments [`_checkGeneration`]; in-flight calls observe the
  /// generation and abort their `state` mutations as soon as a newer
  /// check supersedes them. This makes rapid refresh-button taps safe
  /// and lets the notifier no-op gracefully if the user navigates away.
  Future<void> checkAllRelays() async {
    final identityAsync = ref.read(identityProvider);
    final Identity? identity;
    if (identityAsync.hasValue) {
      identity = identityAsync.value;
    } else {
      identity = await ref.read(identityProvider.future);
    }
    if (identity == null) return;

    final relayService = ref.read(relayServiceProvider);
    final currentState = state.valueOrNull;
    if (currentState == null) return;

    final myGeneration = ++_checkGeneration;
    // Mark every relay as "checking" up front so the UI flips dots
    // immediately rather than per-relay.
    final pending = currentState.relays
        .map(
          (r) => r.copyWith(
            keyPackage: const KindCheckResult(
              status: EventCheckStatus.checking,
            ),
            relayList: const KindCheckResult(status: EventCheckStatus.checking),
            inboxRelayList: const KindCheckResult(
              status: EventCheckStatus.checking,
            ),
          ),
        )
        .toList();
    state = AsyncData(
      currentState.copyWith(relays: pending, isRefreshing: true),
    );

    Future<RelayEventStatus> checkOne(RelayEventStatus relay) async {
      // Three concurrent kind-checks per relay; let them race.
      final results = await Future.wait([
        _checkKind(
          relayService,
          relay.relayUrl,
          identity!.pubkeyHex,
          eventKind: 443,
        ),
        _checkKind(
          relayService,
          relay.relayUrl,
          identity.pubkeyHex,
          eventKind: 10051,
        ),
        _checkKind(
          relayService,
          relay.relayUrl,
          identity.pubkeyHex,
          eventKind: 10050,
        ),
      ]);
      return relay.copyWith(
        keyPackage: results[0],
        relayList: results[1],
        inboxRelayList: results[2],
      );
    }

    // Fan out across all relays in parallel.
    final updated = await Future.wait(pending.map(checkOne));

    // If a newer checkAllRelays superseded us, drop our results
    // silently — the newer call owns `state` from here on.
    if (myGeneration != _checkGeneration) {
      debugPrint('[RelayStatus] check superseded; dropping stale results');
      return;
    }
    state = AsyncData(
      currentState.copyWith(
        relays: updated,
        isRefreshing: false,
        lastChecked: DateTime.now(),
      ),
    );
  }

  /// Checks a single (relay, kind) pair, mapping success / not-found /
  /// failure into a [`KindCheckResult`].
  Future<KindCheckResult> _checkKind(
    RelayService relayService,
    String relayUrl,
    String authorPubkey, {
    required int eventKind,
  }) async {
    try {
      final check = await relayService.checkEventOnRelay(
        relayUrl: relayUrl,
        authorPubkey: authorPubkey,
        eventKind: eventKind,
      );
      return KindCheckResult(
        status: check.found
            ? EventCheckStatus.found
            : EventCheckStatus.notFound,
        newestTimestamp: check.newestTimestamp,
      );
    } on Object catch (_) {
      debugPrint('[RelayStatus] Kind $eventKind check failed');
      return const KindCheckResult(
        status: EventCheckStatus.error,
        errorMessage: 'Check failed',
      );
    }
  }
}
