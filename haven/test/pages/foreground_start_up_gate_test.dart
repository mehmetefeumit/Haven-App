// What a shell mounted while the app is away does, driven through the real
// binding: a lifecycle message before the mount, then the frames.
//
// `MapShell` needs the Rust bridge, so the gate is a mixin it wires with its
// own pause handler, foreground stamp, consent and start-up relay contact
// (`map_shell_mount_lifecycle_test.dart` pins that wiring). Here a probe wires
// the same mixin to recording hooks.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/foreground_start_up_gate.dart';

class _Probe extends StatefulWidget {
  const _Probe({
    required this.log,
    required this.consent,
    this.poolOpen,
    this.launched,
    this.mayResume,
    this.consentStepShown = true,
  });

  final List<String> log;
  final Completer<void> consent;

  /// When set, the relay contact first awaits it, as MapShell's awaits its
  /// publish pool's open, and re-reads the lifecycle after it.
  final Completer<void>? poolOpen;

  /// The native "launched for location" read, asked anew each time; null
  /// answers false at once, which is every process iOS did not launch for a
  /// location event.
  final Future<bool> Function()? launched;

  /// The launch's reads (consent, current disclosure, roster); null answers
  /// true.
  final Future<bool>? mayResume;

  /// What the consent step answers: false when the app left the front first.
  final bool consentStepShown;

  @override
  State<_Probe> createState() => _ProbeState();
}

/// The probe's monotonic clock, which a test moves.
Duration _clock = Duration.zero;

/// How many resumes ran the one-shot extras.
int _extras = 0;

/// The lifecycle each consent step ran under, kept apart from the log so the
/// relay-contact orderings read as they did before the step existed.
final List<AppLifecycleState?> _consentSteps = [];

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
  Future<bool> launchedForLocation() =>
      widget.launched?.call() ?? Future.value(false);

  @override
  Future<bool> launchMayResume() => widget.mayResume ?? Future.value(true);

  @override
  Future<bool> foregroundConsentStep() async {
    _consentSteps.add(WidgetsBinding.instance.lifecycleState);
    return widget.consentStepShown;
  }

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(gateConsentStep());
      unawaited(gateStartUp());
    });
  }

  // What MapShell's handlers do with the gate. The pause stands for the iOS
  // sharing-on branch, where the launch is taken.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (!admitPause()) return;
      final turn = ++_turn;
      widget.log.add('pause');
      final launch = takeLaunchSession();
      if (launch != null) {
        unawaited(
          launch.then((session) {
            if (!mounted || turn != _turn) return;
            widget.log.add('launch ${session.name}');
          }),
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      noteResume();
      _turn++;
      widget.log.add('resume');
      unawaited(payOwedConsentStep());
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
    Future<bool> Function()? launched,
    Future<bool>? mayResume,
    bool consentStepShown = true,
  }) async {
    // Inside the test's own zone, so its completion runs on the test's clock.
    log = [];
    _clock = Duration.zero;
    _extras = 0;
    _consentSteps.clear();
    consent = Completer<void>();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pumpWidget(
      _Probe(
        log: log,
        consent: consent,
        poolOpen: poolOpen,
        launched: launched,
        mayResume: mayResume,
        consentStepShown: consentStepShown,
      ),
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

  // A process iOS launched into the background for a location event (OD-R1).
  // Whatever the binding read at the mount, and whether iOS's own `paused`
  // lands before or after the launch's reads resolve, the first pause starts
  // the background session exactly once and the pause handler runs once.
  group('a location relaunch', () {
    late Completer<bool> launchRead;
    late Completer<bool> mayResume;
    late bool nativeLaunched;

    Future<void> mountRelaunch(
      WidgetTester tester,
      AppLifecycleState state,
    ) async {
      launchRead = Completer<bool>();
      mayResume = Completer<bool>();
      nativeLaunched = true;
      var first = true;
      await mountUnder(
        tester,
        state,
        // The first read is the mount's; any later one is the re-read after a
        // resume, which the first foreground answers false.
        launched: () {
          if (!first) return Future.value(nativeLaunched);
          first = false;
          return launchRead.future;
        },
        mayResume: mayResume.future,
      );
    }

    Future<void> resolve(WidgetTester tester, {bool resume = true}) async {
      launchRead.complete(true);
      await tester.pump();
      mayResume.complete(resume);
      if (!consent.isCompleted) consent.complete();
      await tester.pump();
    }

    int count(String entry) => log.where((e) => e == entry).length;

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.detached,
    ]) {
      testWidgets('mounted under ${state.name}: nothing until the launch is '
          'read, then one pause that starts the session', (tester) async {
        await mountRelaunch(tester, state);
        expect(log, ['stamp'], reason: 'paused before the reads resolved');

        await resolve(tester);
        expect(log, ['stamp', 'pause', 'launch resume']);
      });

      testWidgets('mounted under ${state.name}, iOS pauses BEFORE the reads '
          'resolve: that pause is handed the session, once', (tester) async {
        await mountRelaunch(tester, state);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(log, ['stamp', 'pause'], reason: 'premise: one pause, pending');

        await resolve(tester);
        expect(log, ['stamp', 'pause', 'launch resume']);
      });

      testWidgets('mounted under ${state.name}, iOS pauses AFTER the reads '
          'resolve: no second pause, no second session', (tester) async {
        await mountRelaunch(tester, state);
        await resolve(tester);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        expect(log, ['stamp', 'pause', 'launch resume']);
        expect(count('pause'), 1, reason: 'a second pause cancels the burst');
      });
    }

    testWidgets('mounted under paused: one pause, once the launch and the '
        'consent are read, and it starts the session', (tester) async {
      await mountRelaunch(tester, AppLifecycleState.paused);
      launchRead.complete(true);
      mayResume.complete(true);
      await tester.pump();
      expect(log, isEmpty, reason: 'paused on a consent still loading');

      consent.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(log, ['pause', 'launch resume']);
    });

    testWidgets('a launch the current disclosure does not cover takes no '
        'pause of its own, and a pause iOS dispatches starts nothing', (
      tester,
    ) async {
      await mountRelaunch(tester, AppLifecycleState.inactive);
      await resolve(tester, resume: false);
      expect(log, ['stamp'], reason: 'an older acceptance took a pause');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(log, ['stamp', 'pause', 'launch receiveOnly']);
    });

    testWidgets('an unreadable launch flag is no launch', (tester) async {
      await mountUnder(
        tester,
        AppLifecycleState.inactive,
        launched: () => Future.error(StateError('channel gone')),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(log, ['stamp', 'pause'], reason: 'routed as a relaunch');
    });

    testWidgets('a user who opened the app first owns it: the native flag is '
        'cleared, and their later pause is an ordinary one', (tester) async {
      await mountRelaunch(tester, AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      nativeLaunched = false;
      await resolve(tester);
      expect(log, ['stamp', 'resume', 'relay contact']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(log, ['stamp', 'resume', 'relay contact', 'pause', 'launch none']);
    });

    // The real message path: a lifecycle message that reaches a binding still
    // reading the `detached` seed is walked through `resumed` first. That
    // resume is nobody's, and the native flag (cleared only by a real
    // foreground) says so.
    testWidgets("the binding's synthesized resume over the detached seed "
        'does not cancel the launch', (tester) async {
      await mountRelaunch(tester, AppLifecycleState.detached);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/lifecycle',
        const StringCodec().encodeMessage(
          AppLifecycleState.inactive.toString(),
        ),
        (_) {},
      );
      await tester.pump();
      // What a resume does, the relay contact included (SECURITY.md P4
      // residual 12, which this change leaves as it was).
      expect(
        log,
        ['stamp', 'resume', 'relay contact'],
        reason: 'premise: the synthesized resume',
      );

      await resolve(tester);
      expect(log, [
        'stamp',
        'resume',
        'relay contact',
        'pause',
        'launch resume',
      ]);
    });
  });

  // R-3: the consent step is a foreground interaction. It runs only while the
  // app reads `resumed`, once per mount, owed to the first resume otherwise.
  group('the foreground consent step', () {
    testWidgets('mounted in front: once, at the start-up, while resumed', (
      tester,
    ) async {
      await mountUnder(tester, AppLifecycleState.resumed);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_consentSteps, [AppLifecycleState.resumed]);
    });

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      testWidgets('mounted under ${state.name}: never while away, then once '
          'at the first resume', (tester) async {
        await mountUnder(tester, state);
        consent.complete();
        await tester.pump();
        expect(_consentSteps, isEmpty, reason: 'a dialog pushed while away');

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(_consentSteps, [AppLifecycleState.resumed]);
      });
    }

    testWidgets('a background location launch never runs it', (tester) async {
      await mountUnder(
        tester,
        AppLifecycleState.inactive,
        launched: () => Future.value(true),
      );
      consent.complete();
      await tester.pump();
      expect(log, ['stamp', 'pause', 'launch resume']);
      expect(_consentSteps, isEmpty);
    });

    testWidgets('a step the app left the front before showing is owed to the '
        'next resume', (tester) async {
      await mountUnder(
        tester,
        AppLifecycleState.resumed,
        consentStepShown: false,
      );
      expect(_consentSteps, hasLength(1));
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_consentSteps, hasLength(2), reason: 'the deferred step was lost');
    });
  });
}
