// A premise Haven's lifecycle handling rests on, and does not own.
//
// The framework does not hand an observer the state the platform sent. It
// hands it EVERY state between the last one and that one, in order
// (`ServicesBinding._generateStateTransitions`). Two things in `MapShell`
// are only right because of it:
//
//  * a resume in flight is always superseded at a detach, although a detach
//    does not move `_lifecycleTurn`: `paused` is dispatched ahead of it;
//  * an observer registered while the binding still holds the seed is
//    dispatched `resumed` first, and for `paused` the pause right behind it.
//
// A shell mounted after the binding left the seed is dispatched none of it;
// what it does then is `ForegroundStartUpGate`'s, driven through the binding
// in `test/pages/foreground_start_up_gate_test.dart`.
//
// A Flutter that stopped synthesising would break each of them silently.
// This drives the `flutter/lifecycle` channel the embedder drives and reads
// what an observer is dispatched, so such a bump goes red here.
//
// Not pinned here, because a host binding has no embedder: that the seed IS
// `detached` on a device (READ: `FlutterDartProject.mm`,
// `android_shell_holder.cc` at Flutter 3.41.0).
@TestOn('vm')
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder with WidgetsBindingObserver {
  final List<AppLifecycleState> seen = [];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => seen.add(state);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  /// What an observer is dispatched when the embedder, at [from], sends
  /// [to] over the lifecycle channel.
  Future<List<AppLifecycleState>> dispatched({
    required AppLifecycleState from,
    required AppLifecycleState to,
  }) async {
    binding.handleAppLifecycleStateChanged(from);
    final recorder = _Recorder();
    binding.addObserver(recorder);
    addTearDown(() => binding.removeObserver(recorder));
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(to.toString()),
      (_) {},
    );
    return recorder.seen;
  }

  tearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  test('leaving the seed for inactive dispatches resumed first', () async {
    expect(
      await dispatched(
        from: AppLifecycleState.detached,
        to: AppLifecycleState.inactive,
      ),
      [AppLifecycleState.resumed, AppLifecycleState.inactive],
    );
  });

  test('leaving the seed for paused dispatches resumed, then paused, in one '
      'loop', () async {
    expect(
      await dispatched(
        from: AppLifecycleState.detached,
        to: AppLifecycleState.paused,
      ),
      [
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ],
    );
  });

  test('a detach is dispatched behind paused, from every state but paused',
      () async {
    for (final from in const [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      final seen = await dispatched(from: from, to: AppLifecycleState.detached);
      expect(seen.last, AppLifecycleState.detached, reason: '$from');
      expect(
        seen.indexOf(AppLifecycleState.paused),
        allOf(isNonNegative, lessThan(seen.length - 1)),
        reason: 'from $from a detach reached an observer with no pause '
            'ahead of it: a resume in flight is not superseded',
      );
    }
    expect(
      await dispatched(
        from: AppLifecycleState.paused,
        to: AppLifecycleState.detached,
      ),
      [AppLifecycleState.detached],
    );
  });

  test('a return from paused dispatches resumed last, and no second pause',
      () async {
    expect(
      await dispatched(
        from: AppLifecycleState.paused,
        to: AppLifecycleState.resumed,
      ),
      [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ],
    );
  });

  test('a state the binding already holds is dispatched to nobody', () async {
    expect(
      await dispatched(
        from: AppLifecycleState.paused,
        to: AppLifecycleState.paused,
      ),
      isEmpty,
    );
  });
}
