/// Relay-plane containment for the UNPROXIED multi-relay lanes, read from
/// each relay's store.
///
/// The proxied core-flow lanes hold every client->relay frame to its relay's
/// roles on the wire (C8, `tooling/e2e/ci/check-wire-planes.sh`). The lanes
/// that run several relays without the recorder (relay customization, the
/// profile plane, key-package rotation) have no journal, but each relay's
/// store is a record of what reached it. [assertStoreWithinRoles] holds that
/// record to the roles the test gave the relay.
///
/// What a store cannot show is stated in [TestRelay.dumpStore]: no REQ or NEG
/// (no filter is stored), no application kind-445 past its NIP-40 expiry, no
/// deleted event, and no binding beyond the kind (which circle, which
/// recipient). REQ containment on these topologies is the Rust layers' (L1).
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/log_alias.dart' show magnitudeBucket;

import 'test_relay.dart';

/// The event kinds a relay holding each role may receive: each role's
/// `events` in `tooling/e2e/relay_planes.json`, the matrix the Rust judge
/// exports. A device cannot read the repo, so this is a copy, held equal to
/// the export by `test/lints/relay_planes_mirror_test.dart`.
const Map<String, Set<int>> kRoleEventKinds = <String, Set<int>>{
  'inbox': <int>{1059, 10050, 5},
  'keypackage': <int>{30443, 10002, 5},
  'discovery': <int>{},
  'profile': <int>{0, 5},
  'location': <int>{445},
};

/// The kinds a kind-5 deletion names: its `k` values, the kind of each `a`
/// coordinate and the kind of each `e` target the store still holds
/// ([kindOf]; one the relay already deleted names nothing). A deletion is
/// admitted only where every kind it names is, and one naming none is admitted
/// nowhere (the judge's EV-5 rule), so a key-package retraction on a profile
/// relay is a crossing even though kind 5 itself is admitted there.
Set<int> _deletedKinds(TestRelayEvent event, Map<String, int> kindOf) {
  final kinds = <int>{};
  for (final tag in event.raw['tags'] as List<dynamic>? ?? const <dynamic>[]) {
    if (tag is! List || tag.length < 2 || tag[1] is! String) continue;
    final name = tag[0];
    final value = tag[1] as String;
    if (name == 'e') {
      final target = kindOf[value];
      if (target != null) kinds.add(target);
      continue;
    }
    if (name != 'k' && name != 'a') continue;
    // An unparsable kind is -1, which no role admits.
    final kind = name == 'k' ? value : value.split(':').first;
    kinds.add(int.tryParse(kind) ?? -1);
  }
  return kinds;
}

bool _admits(
  Set<int> admitted,
  TestRelayEvent event,
  Map<String, int> kindOf,
) {
  if (!admitted.contains(event.kind)) return false;
  if (event.kind != 5) return true;
  final named = _deletedKinds(event, kindOf);
  return named.isNotEmpty && admitted.containsAll(named);
}

/// Whether [event] is new since [before] and not the harness's own
/// ([harnessIds]).
bool _judged(
  TestRelayEvent event,
  Set<String> before,
  Set<String> harnessIds,
) => !before.contains(event.id) && !harnessIds.contains(event.id);

/// The ids [store] holds now: the snapshot a per-test check is scoped by.
///
/// Taken at a test's start, because the hermetic relays are reset per TARGET,
/// not per test, and the tests of one target give the same relay different
/// roles. Sound only while nothing the previous test sent can land after this
/// read, and that holds for every file calling it: each write to the shared
/// relay is awaited to that relay's answer (`publishEvent`,
/// `maintainKeyPackage`, `createCircleDelivered`) or read back off it by the
/// test before it returns (a location's copy); the tests drive the FFI with no
/// app, so no maintenance tick, live-sync engine or profile sync runs (the one
/// test that wires providers, RLY-PROV-01, is alone in its file), and no
/// shipped path publishes detached; and a commit a later drive may still owe a
/// relay (a relay change, OD-2's re-send) is in a file whose tests all give
/// that relay the same roles, or in its last test.
Future<Set<String>> storeIds(TestRelay store) async =>
    (await store.dumpStore()).map((e) => e.id).toSet();

/// Fails unless every event [store] gained since [before] has a kind one of
/// [roles] admits (and, for a kind-5 deletion, names only such kinds).
///
/// [roles] are names from [kRoleEventKinds]; an empty set asserts the relay
/// received nothing. [harnessIds] are the harness's own publishes
/// ([TestRelay.publishedIds]), which are not the product's traffic. The
/// failure names [check], the roles, the out-of-role kinds and a bucketed
/// count — never an id, author, tag value or URL (Security Rule 15).
Future<void> assertStoreWithinRoles(
  TestRelay store, {
  required String check,
  required Set<String> roles,
  Set<String> before = const <String>{},
  Set<String> harnessIds = const <String>{},
}) async {
  final unknown = roles.difference(kRoleEventKinds.keys.toSet());
  if (unknown.isNotEmpty) {
    throw ArgumentError('assertStoreWithinRoles: unknown role name');
  }
  final admitted = <int>{for (final role in roles) ...kRoleEventKinds[role]!};
  final stored = await store.dumpStore();
  final kindOf = <String, int>{for (final e in stored) e.id: e.kind};
  final events = stored
      .where((e) => _judged(e, before, harnessIds))
      .toList(growable: false);
  final crossed = events
      .where((e) => !_admits(admitted, e, kindOf))
      .toList(growable: false);
  final crossedKinds = crossed.map((e) => e.kind).toSet().toList()..sort();
  final rolesText =
      roles.isEmpty ? 'no role' : (roles.toList()..sort()).join('+');
  expect(
    crossed,
    isEmpty,
    reason:
        '[$check] a relay holding $rolesText stores '
        '${magnitudeBucket(crossed.length)} new event(s) of kind(s) '
        '$crossedKinds outside its roles: a crossing between relay planes.',
  );
  _printPass(check, rolesText, events.length);
}

/// Fails if [store] gained, since [before], any event of one of [kinds].
///
/// For a relay that holds every role but one plane's (relay customization's
/// R1 is every account role and every circle's routing at once, so only its
/// missing profile role can be checked).
Future<void> assertStoreLacksKinds(
  TestRelay store, {
  required String check,
  required Set<int> kinds,
  Set<String> before = const <String>{},
  Set<String> harnessIds = const <String>{},
}) async {
  final events = (await store.dumpStore())
      .where((e) => _judged(e, before, harnessIds))
      .toList(growable: false);
  final hits = events.where((e) => kinds.contains(e.kind)).length;
  final kindsText = (kinds.toList()..sort()).toString();
  expect(
    hits,
    0,
    reason:
        '[$check] the relay stores ${magnitudeBucket(hits)} new event(s) of '
        'kind(s) $kindsText, which no role it holds admits.',
  );
  _printPass(check, 'no kind $kindsText', events.length);
}

/// The pass line: the check's name, roles and a bucketed count only.
void _printPass(String check, String what, int judged) {
  debugPrint(
    '[$check] store check OK: ${magnitudeBucket(judged)} new event(s), '
    'all within $what.',
  );
}
