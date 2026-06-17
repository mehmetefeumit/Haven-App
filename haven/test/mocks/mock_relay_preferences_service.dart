/// Mock implementation of [RelayPreferencesService] for tests.
///
/// Stores everything in memory; allows tests to seed/inject responses
/// for each method via constructor parameters and to read mutation
/// counts via `addCalls`, `removeCalls`, etc.
library;

import 'dart:typed_data';

import 'package:haven/src/services/relay_preferences_service.dart';

/// A mock [RelayPreferencesService] for tests.
class MockRelayPreferencesService implements RelayPreferencesService {
  /// Creates a mock with optional initial state.
  MockRelayPreferencesService({
    Map<RelayCategory, List<String>>? initialRelays,
    Map<RelayCategory, bool>? publishToggles,
    this.seedThrows = false,
    this.addThrows,
    this.removeThrows,
  }) : _relays = {
         RelayCategory.inbox: List<String>.from(
           initialRelays?[RelayCategory.inbox] ?? const <String>[],
         ),
         RelayCategory.keyPackage: List<String>.from(
           initialRelays?[RelayCategory.keyPackage] ?? const <String>[],
         ),
       },
       _toggles = {
         RelayCategory.inbox: publishToggles?[RelayCategory.inbox] ?? true,
         RelayCategory.keyPackage:
             publishToggles?[RelayCategory.keyPackage] ?? true,
       };

  final Map<RelayCategory, List<String>> _relays;
  final Map<RelayCategory, bool> _toggles;

  /// If true, [`seedDefaultsIfUnseeded`] throws.
  bool seedThrows;

  /// If non-null, [`addRelay`] throws this exception (allows asserting
  /// the UI's error handling path).
  Exception? addThrows;

  /// If non-null, [`removeRelay`] throws this exception.
  Exception? removeThrows;

  /// Whether [`seedDefaultsIfUnseeded`] has been called at least once.
  bool didSeed = false;

  /// Mutation log (in call order). Useful for asserting invalidation
  /// chains and test ordering.
  final List<String> log = [];

  @override
  Future<List<String>> listRelays(RelayCategory category) async {
    log.add('list:${category.name}');
    return List<String>.from(_relays[category] ?? const <String>[]);
  }

  @override
  Future<void> addRelay(RelayCategory category, String url) async {
    log.add('add:${category.name}:$url');
    if (addThrows != null) throw addThrows!;
    final list = _relays[category]!;
    if (!list.contains(url)) list.add(url);
  }

  @override
  Future<bool> removeRelay(RelayCategory category, String url) async {
    log.add('remove:${category.name}:$url');
    if (removeThrows != null) throw removeThrows!;
    final list = _relays[category]!;
    if (list.length <= 1 && list.contains(url)) {
      throw const RelayValidationError(
        'You need at least one relay so others can reach you.',
      );
    }
    return list.remove(url);
  }

  @override
  Future<void> restoreDefaults(RelayCategory category) async {
    log.add('restore:${category.name}');
    final list = _relays[category]!;
    for (final url in const ['wss://default-a', 'wss://default-b']) {
      if (!list.contains(url)) list.add(url);
    }
  }

  @override
  Future<void> wipeAndResetDefaults(RelayCategory category) async {
    log.add('wipe:${category.name}');
    _relays[category] = [
      'wss://default-a',
      'wss://default-b',
      'wss://default-c',
    ];
  }

  @override
  Future<void> seedDefaultsIfUnseeded() async {
    log.add('seed');
    didSeed = true;
    if (seedThrows) {
      throw const RelayPreferencesException('seeding failed');
    }
    if (_relays[RelayCategory.inbox]!.isEmpty) {
      _relays[RelayCategory.inbox]!.addAll([
        'wss://default-a',
        'wss://default-b',
      ]);
    }
    if (_relays[RelayCategory.keyPackage]!.isEmpty) {
      _relays[RelayCategory.keyPackage]!.addAll([
        'wss://default-a',
        'wss://default-b',
      ]);
    }
  }

  @override
  Future<bool> getPublishRelayList(RelayCategory category) async {
    return _toggles[category] ?? true;
  }

  @override
  Future<void> setPublishRelayList(
    RelayCategory category, {
    required bool value,
  }) async {
    log.add('toggle:${category.name}=$value');
    _toggles[category] = value;
  }

  @override
  Future<List<String>> publishTargets(RelayCategory category) async {
    // Two-plane model: targets are EXACTLY the user's configured relays —
    // no public-default union (mirrors the real service and Rust
    // `dedup_relay_targets`). A previous version injected 'wss://default-a'
    // here, which masked the no-leak invariant in mock-based tests.
    return List<String>.from(_relays[category]!);
  }

  @override
  Future<BuiltRelayListPublish> buildRelayListPublish({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
  }) async {
    final enabled = _toggles[category] ?? true;
    if (!enabled) {
      return const BuiltRelayListPublish(suppressed: true);
    }
    return BuiltRelayListPublish(
      suppressed: false,
      eventJson: '{"kind":${category == RelayCategory.inbox ? 10050 : 10051}}',
      eventIdHex: '0' * 64,
      targets: await publishTargets(category),
      kind: category == RelayCategory.inbox ? 10050 : 10051,
      createdAtSecs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<void> recordPublishedRelayList({
    required String identityPubkeyHex,
    required int kind,
    required String eventIdHex,
    required int publishedAtSecs,
  }) async {
    log.add('record:$kind:$eventIdHex@$publishedAtSecs');
  }

  @override
  Future<BuiltUnpublish> buildUnpublishRelayList({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
  }) async {
    return BuiltUnpublish(
      suppressed: false,
      replacementEventJson: '{"unpublish":true}',
      targets: await publishTargets(category),
    );
  }

  @override
  Future<BuiltUnpublish> buildRelayRemovalScrub({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
    required List<String> droppedRelays,
  }) async {
    log.add('scrub:${category.name}:${droppedRelays.join(",")}');
    if (droppedRelays.isEmpty) {
      return const BuiltUnpublish(suppressed: true);
    }
    // Removal hygiene: deletion targeted at the dropped relays only, no
    // empty-replacement (mirrors the real service).
    return BuiltUnpublish(
      suppressed: false,
      deletionEventJson: '{"kind":5,"scrub":true}',
      targets: List<String>.from(droppedRelays),
    );
  }
}
