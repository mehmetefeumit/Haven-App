// What a shell mounted while the app is away does, driven through the real
// binding: a lifecycle message before the mount, then the frames.
//
// `MapShell` needs the Rust bridge, so the gate is a mixin it wires with its
// own pause handler, foreground stamp, consent and start-up relay contact
// (`map_shell_mount_lifecycle_test.dart` pins that wiring). Here a probe wires
// the same mixin to recording hooks.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/foreground_start_up_gate.dart';

class _Probe extends StatefulWidget {
  const _Probe({required this.log, required this.consent, this.poolOpen});

  final List<String> log;
  final Completer<void> consent;

  /// When set, the relay contact first awaits it, as MapShell's awaits its
  /// publish pool's open, and re-reads the lifecycle after it.
  final Completer<void>? poolOpen;

  @override
  State<_Probe> createState() => _ProbeState();
}

/// The probe's monotonic clock, which a test moves.
Duration _clock = Duration.zero;

/// How many resumes ran the one-shot extras.
int _extras = 0;

class _ProbeState extends State<_Probe>
    with WidgetsBindingObserver, ForegroundStartUpGate<_Probe> {
  int _turn = 0;

  @override
  Duration resumeClock() => _clock;

  @override
  int get lifecycleTurn => _turn;

  @override
  void stampForeground() => widget.log.add('stamp');

  @override
  Future<void> beforeMissedPause() => widget.consent.future;

  @override
  void takePause() => didChangeAppLifecycleState(AppLifecycleState.paused);

  @override
  Future<void> startUpRelayContact() async {
    final pool = widget.poolOpen;
    if (pool != null) {
      widget.log.add('pool open');
      await pool.future;
      if (!mounted || !stillInFront()) return;
    }
    widget.log.add('relay contact');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    gateMount();
    WidgetsBinding.instance.addPostFrameCallback((_) => gateStartUp());
  }

  // What MapShell's handlers do with the gate.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _turn++;
      widget.log.add('pause');
    } else if (state == AppLifecycleState.resumed) {
      _turn++;
      widget.log.add('resume');
      if (!resumeExtrasDue()) return;
      _extras++;
      unawaited(payOwedStartUp());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  late List<String> log;
  late Completer<void> consent;

  Future<void> mountUnder(
    WidgetTester tester,
    AppLifecycleState state, {
    Completer<void>? poolOpen,
  }) async {
    // Inside the test's own zone, so its completion runs on the test's clock.
    log = [];
    _clock = Duration.zero;
    _extras = 0;
    consent = Completer<void>();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pumpWidget(
      _Probe(log: log, consent: consent, poolOpen: poolOpen),
    );
    // `runApp` forces a warm-up frame whatever the lifecycle; a paused test
    // binding schedules none.
    tester.binding.scheduleWarmUpFrame();
    await tester.pump(Duration.zero);
  }

  testWidgets('a shell mounted under paused stamps nothing and contacts no '
      'relay, and takes the pause once the consent is read', (tester) async {
    await mountUnder(tester, AppLifecycleState.paused);
    expect(
      log,
      isEmpty,
      reason: 'a paused process stamped the foreground, contacted a relay, or '
          'paused on a consent not yet read',
    );

    consent.complete();
    await tester.pump();
    expect(log, ['pause']);
  });

  testWidgets('what the paused start-up skipped happens at the first resume, '
      'once', (tester) async {
    await mountUnder(tester, AppLifecycleState.paused);
    consent.complete();
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(log, ['pause', 'resume', 'relay contact', 'pause', 'resume']);
  });

  testWidgets('a resume before the consent is read owns the shell: no missed '
      'pause', (tester) async {
    await mountUnder(tester, AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    consent.complete();
    await tester.pump();

    expect(log, ['resume', 'relay contact']);
  });

  testWidgets('a shell mounted in front stamps and contacts its relays at the '
      'start-up', (tester) async {
    await mountUnder(tester, AppLifecycleState.resumed);
    consent.complete();
    await tester.pump();

    expect(log, ['stamp', 'relay contact']);
  });

  testWidgets('a shell mounted under inactive stamps, and owes its relay '
      'contact to the resume', (tester) async {
    // A launch dialog is a visible app: the foreground is stamped. Nothing
    // publishes until it is in front.
    await mountUnder(tester, AppLifecycleState.inactive);
    expect(log, ['stamp']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(log, ['stamp', 'resume', 'relay contact']);
  });

  testWidgets('a pause that lands while the relay contact awaits its pool '
      'stops the rest of it, and the next resume pays it whole, once', (
    tester,
  ) async {
    final pool = Completer<void>();
    await mountUnder(tester, AppLifecycleState.resumed, poolOpen: pool);
    expect(log, ['stamp', 'pool open']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    pool.complete();
    await tester.pump();
    expect(
      log,
      ['stamp', 'pool open', 'pause'],
      reason: 'the contact went on behind a pause: a publisher rebuilt and a '
          'timer armed from a paused app',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(log, [
      'stamp',
      'pool open',
      'pause',
      'resume',
      'pool open',
      'relay contact',
      'pause',
      'resume',
    ]);
  });

  testWidgets('a resume within the debounce of the last one that ran the '
      'extras skips them; one past it runs them', (tester) async {
    await mountUnder(tester, AppLifecycleState.resumed);
    void comeBackAt(Duration at) {
      _clock = at;
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    comeBackAt(Duration.zero);
    expect(_extras, 1);
    comeBackAt(const Duration(seconds: 29));
    expect(_extras, 1, reason: 'a glance re-ran the extras');
    comeBackAt(const Duration(seconds: 30));
    expect(_extras, 2, reason: 'measured from the last run, not the glance');
    await tester.pump();
  });

  testWidgets('a resume the debounce skips still pays an owed start-up', (
    tester,
  ) async {
    final pool = Completer<void>();
    await mountUnder(tester, AppLifecycleState.resumed, poolOpen: pool);
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(_extras, 1);
    // A pause lands while the contact awaits its pool: it is owed again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pool.complete();
    await tester.pump();
    expect(log, isNot(contains('relay contact')), reason: 'premise: owed');

    _clock = const Duration(seconds: 5);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(_extras, 1, reason: 'premise: debounced');
    expect(log.where((e) => e == 'relay contact'), hasLength(1));
  });
}
