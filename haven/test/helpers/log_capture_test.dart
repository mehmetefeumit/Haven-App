/// Tests for [LogCapture] itself — the shared helper every service/provider
/// log-anonymity test now builds on, so a defect here would silently weaken
/// every one of them.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'log_capture.dart';

void main() {
  test('captures debugPrint lines in order', () {
    final capture = LogCapture();
    debugPrint('first');
    debugPrint('second');
    capture.restore();

    expect(capture.lines, ['first', 'second']);
    expect(capture.joined, 'first\nsecond');
  });

  test('restore puts the prior debugPrint callback back', () {
    final prior = debugPrint;
    final capture = LogCapture();
    expect(debugPrint, isNot(same(prior)));
    capture.restore();
    expect(debugPrint, same(prior));
  });

  test('install() schedules restore via addTearDown', () {
    final prior = debugPrint;
    LogCapture.install();
    expect(debugPrint, isNot(same(prior)));
    // addTearDown's own restore runs after this test body — proven by the
    // other tests in this file each starting with debugPrint back at its
    // ambient value (package:test tears down between tests).
  });

  test('assertContains passes when the marker is present', () {
    final capture = LogCapture();
    debugPrint('SomeFailure: recorded by type');
    capture
      ..restore()
      ..assertContains('SomeFailure');
  });

  test('assertContains fails — anti-vacuity — when nothing was logged', () {
    final capture = LogCapture()..restore();

    expect(
      () => capture.assertContains('SomeFailure'),
      throwsA(isA<TestFailure>()),
      reason:
          'a capture with no output must not silently satisfy the marker '
          'check, or assertNoNeedles could pass vacuously',
    );
  });

  test('assertNoNeedles catches the literal value', () {
    final capture = LogCapture();
    debugPrint('leaked: deadbeefcafebabe0011223344556677');
    capture.restore();

    expect(
      () => capture.assertNoNeedles(['deadbeefcafebabe0011223344556677']),
      throwsA(isA<TestFailure>()),
    );
  });

  test('assertNoNeedles catches an upper/lower re-casing', () {
    final capture = LogCapture();
    debugPrint('leaked: DEADBEEFCAFEBABE0011223344556677');
    capture.restore();

    expect(
      () => capture.assertNoNeedles(['deadbeefcafebabe0011223344556677']),
      throwsA(isA<TestFailure>()),
    );
  });

  test('assertNoNeedles catches an 8-char prefix truncation', () {
    final capture = LogCapture();
    debugPrint('evt=deadbeef');
    capture.restore();

    expect(
      () => capture.assertNoNeedles(['deadbeefcafebabe0011223344556677']),
      throwsA(isA<TestFailure>()),
    );
  });

  test('assertNoNeedles catches a 16-char prefix truncation', () {
    final capture = LogCapture();
    debugPrint('group=deadbeefcafebabe');
    capture.restore();

    expect(
      () => capture.assertNoNeedles(['deadbeefcafebabe0011223344556677']),
      throwsA(isA<TestFailure>()),
    );
  });

  test('assertNoNeedles catches a bare-host leak of a URL needle', () {
    final capture = LogCapture();
    debugPrint('connecting to relay.example.com');
    capture.restore();

    expect(
      () => capture.assertNoNeedles(['wss://relay.example.com']),
      throwsA(isA<TestFailure>()),
    );
  });

  test('assertNoNeedles passes when the needle never appears', () {
    final capture = LogCapture();
    debugPrint('LocationServiceException: publish failed');
    capture
      ..restore()
      ..assertNoNeedles(['deadbeefcafebabe0011223344556677', 'npub1x']);
  });

  test(
    'assertNoNeedles skips empty needles instead of matching everything',
    () {
      final capture = LogCapture();
      debugPrint('anything at all');
      capture
        ..restore()
        ..assertNoNeedles(['']);
    },
  );
}
