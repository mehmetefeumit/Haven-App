/// The e2e-integration lane builds exactly the targets it drives, and both
/// include the Welcome redelivery scenario.
///
/// The two lists live in different files (`build-integration-apks.sh`
/// builds, `e2e-integration.yml` drives). A target built but never driven
/// reports nothing; one driven but never built fails at install, far from
/// its cause. The redelivery scenario is the one proof, on a device, that an
/// owed Welcome is sent again as the same event; a lane that lost it would
/// stay green.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _redelivery = 'integration_test/welcome_redelivery_test.dart';
const _driveStep = 'script: bash tooling/e2e/ci/run-with-deadline.sh';

Set<String> _built() => RegExp(
  r'^\s+"(integration_test/[^"]+\.dart)"\s*$',
  multiLine: true,
)
    .allMatches(
      File('../tooling/e2e/ci/build-integration-apks.sh').readAsStringSync(),
    )
    .map((m) => m.group(1)!)
    .toSet();

Set<String> _driven() {
  final drive = File('../.github/workflows/e2e-integration.yml')
      .readAsLinesSync()
      .singleWhere((line) => line.trimLeft().startsWith(_driveStep));
  return RegExp(r'(integration_test/\S+\.dart)=')
      .allMatches(drive)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  test('the lane builds exactly the targets it drives', () {
    final driven = _driven();
    expect(driven, isNotEmpty);
    expect(_built(), driven);
  });

  test('the Welcome redelivery scenario is built and driven', () {
    expect(_driven(), contains(_redelivery));
    expect(_built(), contains(_redelivery));
  });
}
