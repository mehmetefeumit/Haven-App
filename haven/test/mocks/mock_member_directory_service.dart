/// Mock implementation of [MemberDirectoryService] for testing.
///
/// Recording, not just stubbing: several tests assert on the ABSENCE of a
/// call — R2/R4 promise that typing in the picker issues no service work at
/// all — and an absence is only provable against a recorder that would have
/// caught the call.
library;

import 'dart:async';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';

/// A mock [MemberDirectoryService] for testing.
///
/// Allows tests to control:
/// - What [loadDirectory] resolves to
/// - Whether it fails, and whether it stays in flight (via [loadGate])
/// - Exactly how many calls were made, and when
class MockMemberDirectoryService implements MemberDirectoryService {
  /// Creates a mock member-directory service.
  ///
  /// By default [loadDirectory] resolves to [MemberDirectory.empty].
  MockMemberDirectoryService({MemberDirectory? directory})
    : directory = directory ?? MemberDirectory.empty;

  /// The directory [loadDirectory] resolves to. Settable directly by tests.
  MemberDirectory directory;

  /// Records every method invocation as `(method, args)`, in call order.
  ///
  /// `args` uses each parameter's name as the map key, matching
  /// [`MockProfileService`]'s recorder so assertions read the same way in
  /// both.
  final List<({String method, Map<String, Object?> args})> methodCalls = [];

  /// Set to make [loadDirectory] throw.
  ///
  /// The real implementation never throws — it degrades to an empty
  /// directory — so this models a NON-CONFORMING implementation, and exists
  /// to prove the layers above stay usable even then.
  bool shouldThrowOnLoadDirectory = false;

  /// When set, [loadDirectory] blocks on this until it completes, holding
  /// the call in flight deterministically (no wall-clock delay, no race).
  Completer<void>? loadGate;

  /// The [circles] passed to the most recent [loadDirectory] call, or `null`
  /// before the first call.
  List<Circle>? lastCircles;

  @override
  Future<MemberDirectory> loadDirectory({required List<Circle> circles}) async {
    lastCircles = circles;
    methodCalls.add((method: 'loadDirectory', args: {'circles': circles}));
    final gate = loadGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (shouldThrowOnLoadDirectory) {
      throw StateError('mock member directory failure');
    }
    return directory;
  }
}
