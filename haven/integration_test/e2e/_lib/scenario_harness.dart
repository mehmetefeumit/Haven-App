/// Per-scenario setup shared by all E2E tests.
///
/// Scenarios call [ScenarioHarness.bootstrap] in `setUpAll`. The harness
/// initialises the Rust bridge, installs the test-only keyring + relay
/// overrides, parses the dart-define role parameter, and returns a context
/// the scenario uses to access its `TestUser`s and the strfry probe.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_relay.dart';
import 'test_user.dart';

/// Which role this Patrol process is driving in a multi-instance scenario.
///
/// Set by `--dart-define=HAVEN_E2E_ROLE=alice|bob|solo` when launching
/// the scenario. Single-process scenarios use [solo].
enum ScenarioRole {
  /// Single-instance scenario (the test process drives the whole flow).
  solo,

  /// Multi-instance scenario, this process plays Alice (admin / inviter).
  alice,

  /// Multi-instance scenario, this process plays Bob (joiner).
  bob;

  static ScenarioRole fromEnvironment() {
    const value = String.fromEnvironment(
      'HAVEN_E2E_ROLE',
      defaultValue: 'solo',
    );
    return switch (value) {
      'alice' => ScenarioRole.alice,
      'bob' => ScenarioRole.bob,
      'solo' || '' => ScenarioRole.solo,
      _ => throw StateError('Unknown HAVEN_E2E_ROLE: "$value"'),
    };
  }
}

/// Shared per-scenario context. Built by [ScenarioHarness.bootstrap].
class ScenarioContext {
  ScenarioContext._({required this.role, required this.relay});

  /// The role this process is driving.
  final ScenarioRole role;

  /// The probe-layer relay client. Use [TestRelay.firstWhere] to
  /// synchronize between roles.
  final TestRelay relay;
}

/// Per-process bootstrap. Idempotent.
abstract final class ScenarioHarness {
  /// Initialises the integration-test binding, the Rust bridge, the
  /// in-memory keyring backend, the relay override, and opens a probe
  /// connection to the strfry relay.
  ///
  /// Returns a [ScenarioContext] the scenario should keep until the end
  /// of the test (calling [ScenarioContext.relay].dispose() in `tearDownAll`).
  static Future<ScenarioContext> bootstrap({
    String relayUrl = defaultStrfryUrl,
  }) async {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    await TestUser.bootstrapProcess(relays: <String>[relayUrl]);
    final relay = await TestRelay.connect(url: relayUrl);
    final role = ScenarioRole.fromEnvironment();
    debugPrint('[ScenarioHarness] bootstrapped role=$role relay=$relayUrl');
    return ScenarioContext._(role: role, relay: relay);
  }

  /// Default test timeout — overrides Patrol's overly generous 5-min default.
  /// Use as the `timeout:` argument on `patrolTest` / `testWidgets`.
  static const Timeout defaultTimeout = Timeout(Duration(minutes: 3));
}
