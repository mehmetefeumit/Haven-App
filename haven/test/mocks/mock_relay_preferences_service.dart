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
    ProfilePoolStatus? poolStatus,
    this.profilePoolStatusThrows,
    this.restoreDefaultProfileRelaysThrows,
  }) : _poolStatus =
           poolStatus ??
           const ProfilePoolStatus(
             configured: 8,
             excluded: 0,
             usable: 8,
             isUnderflow: false,
           ),
       _relays = {
         RelayCategory.inbox: List<String>.from(
           initialRelays?[RelayCategory.inbox] ?? const <String>[],
         ),
         RelayCategory.keyPackage: List<String>.from(
           initialRelays?[RelayCategory.keyPackage] ?? const <String>[],
         ),
         RelayCategory.profile: List<String>.from(
           initialRelays?[RelayCategory.profile] ?? const <String>[],
         ),
       },
       _toggles = {
         RelayCategory.inbox: publishToggles?[RelayCategory.inbox] ?? true,
         RelayCategory.keyPackage:
             publishToggles?[RelayCategory.keyPackage] ?? true,
         // Profile has no publish toggle in production (the category has no
         // publishable form — see `_rejectProfilePublish`); tracked here only
         // so `_toggles[category]` stays total across all three categories.
         RelayCategory.profile: publishToggles?[RelayCategory.profile] ?? true,
       };

  final Map<RelayCategory, List<String>> _relays;
  final Map<RelayCategory, bool> _toggles;

  /// Current profile-pool status returned by [profilePoolStatus]. Mutable so
  /// [restoreDefaultProfileRelays] can clear an underflow the way the real
  /// recovery action does.
  ProfilePoolStatus _poolStatus;

  /// If non-null, [profilePoolStatus] throws this exception.
  Exception? profilePoolStatusThrows;

  /// If non-null, [restoreDefaultProfileRelays] throws this exception.
  Exception? restoreDefaultProfileRelaysThrows;

  /// Number of times [restoreDefaultProfileRelays] has been called.
  int restoreDefaultProfileRelaysCalls = 0;

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

  /// Throws, matching the real `NostrRelayPreferencesService`/Rust
  /// fail-closed behavior: [`RelayCategory.profile`] has no publishable
  /// form, so none of the publish-oriented methods below
  /// (`getPublishRelayList`, `setPublishRelayList`, `publishTargets`,
  /// `buildRelayListPublish`, `buildUnpublishRelayList`,
  /// `buildRelayRemovalScrub`) may be called with it. A caller that does so
  /// by mistake should fail loudly here exactly as it would against the real
  /// FFI, not silently succeed against a lenient mock.
  void _rejectProfilePublish(RelayCategory category) {
    if (category == RelayCategory.profile) {
      throw const RelayPreferencesException(
        'Profile relays are local-only and cannot be published.',
      );
    }
  }

  /// The publishable Nostr event kind for [category].
  ///
  /// Exhaustive by construction: [`RelayCategory.profile`] has none, so it
  /// throws via [_rejectProfilePublish] rather than silently falling through
  /// to a wrong kind (the previous binary ternary here mapped `profile` onto
  /// 10002 — `KeyPackage`'s kind — which would have made a Profile-category
  /// publish attempt look identical to a KeyPackage one in test assertions).
  int _wireKindFor(RelayCategory category) {
    _rejectProfilePublish(category);
    return switch (category) {
      RelayCategory.inbox => 10050,
      RelayCategory.keyPackage => 10002,
      RelayCategory.profile =>
        throw StateError('unreachable: rejected above'),
    };
  }

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
    if (_relays[RelayCategory.profile]!.isEmpty) {
      // Distinct URLs from the location-plane defaults above — mirrors the
      // real curated profile pool being disjoint from the account/location
      // relay defaults (see `fallbackDefaultProfileRelays`), so a test never
      // mistakes plane-separation success for a coincidence of shared mock
      // fixture strings.
      _relays[RelayCategory.profile]!.addAll([
        'wss://profile-default-a',
        'wss://profile-default-b',
      ]);
    }
  }

  @override
  Future<bool> getPublishRelayList(RelayCategory category) async {
    _rejectProfilePublish(category);
    return _toggles[category] ?? true;
  }

  @override
  Future<void> setPublishRelayList(
    RelayCategory category, {
    required bool value,
  }) async {
    log.add('toggle:${category.name}=$value');
    _rejectProfilePublish(category);
    _toggles[category] = value;
  }

  @override
  Future<List<String>> publishTargets(RelayCategory category) async {
    // Fail-closed for `profile` exactly like `CircleManagerFfi
    // ::relay_publish_targets`: the profile plane is local-only, so it has no
    // publish targets to hand back. Returning a list here would let a
    // mock-based test drive a publish loop the real FFI refuses to feed.
    _rejectProfilePublish(category);
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
    final kind = _wireKindFor(category); // throws for RelayCategory.profile
    final enabled = _toggles[category] ?? true;
    if (!enabled) {
      return const BuiltRelayListPublish(suppressed: true);
    }
    // Mirrors the production wire kinds: inbox = 10050 (NIP-17), and the
    // KeyPackage-discovery category = 10002 (NIP-65; the dedicated kind
    // 10051 is retired by the Dark Matter migration).
    return BuiltRelayListPublish(
      suppressed: false,
      eventJson: '{"kind":$kind}',
      eventIdHex: '0' * 64,
      targets: await publishTargets(category),
      kind: kind,
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
    _rejectProfilePublish(category);
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
    _rejectProfilePublish(category);
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

  @override
  Future<ProfilePoolStatus> profilePoolStatus() async {
    log.add('profilePoolStatus');
    if (profilePoolStatusThrows != null) throw profilePoolStatusThrows!;
    return _poolStatus;
  }

  @override
  Future<void> restoreDefaultProfileRelays() async {
    log.add('restoreDefaultProfileRelays');
    restoreDefaultProfileRelaysCalls++;
    if (restoreDefaultProfileRelaysThrows != null) {
      throw restoreDefaultProfileRelaysThrows!;
    }
    // Mirrors the real recovery action: adds back curated defaults (kept
    // distinct from the location-plane defaults, same as
    // `seedDefaultsIfUnseeded` above) and clears the underflow flag, exactly
    // as the production Rust call does when enough relays are restored.
    final list = _relays[RelayCategory.profile]!;
    for (final url in const [
      'wss://profile-default-a',
      'wss://profile-default-b',
    ]) {
      if (!list.contains(url)) list.add(url);
    }
    _poolStatus = ProfilePoolStatus(
      configured: _poolStatus.configured,
      excluded: _poolStatus.excluded,
      usable: list.length,
      isUnderflow: false,
    );
  }
}
