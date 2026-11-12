/// W11's Dart pin: engine work is served inside the wakes the app already
/// has, never from a timer of its own.
///
/// Every `Timer`, `Timer.periodic`, `Future.delayed` and `Stream.periodic`
/// in `lib/` is listed here by file and enclosing member, with how many it
/// holds — an exact allowlist, so a new timer anywhere fails this test until
/// it is reviewed and listed, and a listed site cannot silently multiply.
/// Of those, the sites whose callback reaches engine work (a drive, a leave
/// carry-on, a catch-up, a live-sync heal or health tick, a seal or a fetch)
/// are a second exact list: the existing wakes the engine's deadlines are
/// served from. A new one is a new wake, which costs battery and must be a
/// decision, not a side effect (`docs/POWER_EFFICIENCY_PLAN.md`).
///
/// A syntactic walk of one file at a time: a callback is followed into the
/// same file's declarations for up to two calls, the shape the app uses
/// (a timer delegating to a private tick method), and no further.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('timer and delay sites in lib/', () {
    late Map<String, TimerSite> sites;

    setUpAll(() {
      sites = {};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(Platform.pathSeparator, '/');
        // Generated bridge and localizations hold no timer of the app's.
        if (path.startsWith('lib/src/rust/') || path.startsWith('lib/l10n/')) {
          continue;
        }
        for (final site in timerSites(entity.readAsStringSync(), path)) {
          sites.update(
            site.key,
            (known) => known.merge(site),
            ifAbsent: () => site,
          );
        }
      }
    });

    test('are exactly the reviewed ones, each with its count', () {
      expect(
        {for (final site in sites.values) site.key: site.count},
        _allowedSites,
        reason: 'a timer was added, moved or multiplied: review whether it '
            'may run, and list it here',
      );
      expect(
        _allowedSites.values.fold<int>(0, (sum, count) => sum + count),
        _allowedTotal,
      );
    });

    test('of which only the existing wakes reach engine work', () {
      expect(
        _allowedSites.keys.toSet().containsAll(_engineWakes),
        isTrue,
        reason: 'a wake that is no listed site',
      );
      expect(
        {
          for (final site in sites.values)
            if (site.reachesEngine) site.key,
        }.difference(_engineWakes),
        isEmpty,
        reason: 'engine deadlines are served inside the existing wakes; a '
            'timer that reaches engine work is a wake, and a new one must be '
            'a decision',
      );
    });
  });

  group('the detector', () {
    test('finds every scheduler shape, keyed by its enclosing member', () {
      const source = '''
class A {
  void a() {
    Timer(d, () {});
    Timer.periodic(d, (_) {});
  }
  Future<void> b() => Future<void>.delayed(d);
  void c() {
    Future.delayed(d, () {});
    Stream.periodic(d);
  }
}
''';
      expect(
        {
          for (final s in timerSites(source, 'f.dart'))
            s.key: (s.count, s.reachesEngine),
        },
        {
          'f.dart#A.a': (2, false),
          'f.dart#A.b': (1, false),
          'f.dart#A.c': (2, false),
        },
      );
    });

    test('sees engine work in a multi-line callback', () {
      const source = '''
void drive() {
  Timer.periodic(d, (_) {
    unawaited(maintenance.resumeDrive(foreground: true));
  });
}
''';
      expect(timerSites(source, 'f.dart').single.reachesEngine, isTrue);
    });

    test('follows a tear-off and two extractions out of the callback', () {
      const tearOff = '''
void drive() => Timer.periodic(d, _tick);
void _tick(Timer _) => service.runCatchup();
''';
      const twoHops = '''
void drive() => Timer(d, () => _a());
void _a() => _b();
void _b() => backstop.carryOn();
''';
      expect(timerSites(tearOff, 'f.dart').single.reachesEngine, isTrue);
      expect(timerSites(twoHops, 'f.dart').single.reachesEngine, isTrue);
    });

    test('does not see engine work three calls away, in a comment or in a '
        'string', () {
      const threeHops = '''
void drive() => Timer(d, () => _a());
void _a() => _b();
void _b() => _c();
void _c() => service.runCatchup();
''';
      const prose = '''
void drive() {
  // Timer.periodic must never call resumeDrive.
  Timer.periodic(d, (_) => log('resumeDrive is not called here'));
}
''';
      expect(timerSites(threeHops, 'f.dart').single.reachesEngine, isFalse);
      expect(timerSites(prose, 'f.dart').single.reachesEngine, isFalse);
    });

    test('does not count a timer named only in a comment or a string', () {
      const source = '''
void drive() {
  // Timer.periodic(d, tick) used to live here.
  log('Future.delayed(d)');
}
''';
      expect(timerSites(source, 'f.dart'), isEmpty);
    });
  });
}

const _shell = 'lib/src/pages/map_shell.dart';
const _maintenance =
    'lib/src/providers/maintenance_scheduler_provider.dart#'
    'MaintenanceSchedulerNotifier';
const _task =
    'lib/src/services/background_location_task.dart#'
    'BackgroundLocationTaskHandler';
const _join =
    'lib/src/providers/join_watcher_provider.dart#JoinWatcherNotifier';
const _publishTick =
    'lib/src/providers/location_publish_scheduler_provider.dart#'
    'LocationPublishSchedulerNotifier._pacedPublish';
const _burstPass =
    'lib/src/services/background_burst_coordinator.dart#'
    'BackgroundBurstCoordinator._publishPass';
const _resubscribe =
    'lib/src/services/live_sync_resubscriber.dart#'
    'LiveSyncResubscriber.onCirclesChanged';

/// The reviewed timer and delay sites in `lib/`, by `path#Member`, with how
/// many each holds.
const _allowedSites = <String, int>{
  'lib/src/pages/map/map_page.dart#_MapPageState.build': 1,
  '$_shell#LiveSyncHealBackstop._arm': 1,
  '$_shell#_MapShellState._scheduleInvitationPoll': 1,
  '$_shell#_MapShellState._startIosBackgroundReceiveTimer': 1,
  '$_shell#_MapShellState._startTimers': 4,
  '$_shell#_MapShellState.startUpRelayContact': 1,
  'lib/src/pages/settings/add_relay_sheet.dart#_AddRelaySheetState._onChanged':
      1,
  'lib/src/providers/background_location_provider.dart#'
          'BackgroundSharingNotifier.bound':
      1,
  'lib/src/providers/identity_provider.dart#IdentityNotifier.stopBudget': 1,
  'lib/src/providers/join_watcher_provider.dart#'
          'JoinWatcherNotifier._scheduleTick':
      1,
  'lib/src/providers/join_watcher_provider.dart#JoinWatcherNotifier._start': 2,
  'lib/src/providers/location_access_provider.dart#'
          'LocationAccessNotifier._armFor':
      1,
  'lib/src/providers/location_publish_scheduler_provider.dart#'
          'LocationPublishSchedulerNotifier._pacedPublish':
      1,
  'lib/src/providers/location_sharing_provider.dart#locationPublisherProvider':
      1,
  '$_maintenance._armHealth': 1,
  '$_maintenance._armKeyPackage': 1,
  '$_maintenance._armLeaveFollowUp': 1,
  '$_maintenance._armProfileAntiEntropy': 1,
  '$_maintenance._armRelayList': 1,
  // The moment the Bluetooth mesh turns itself off: the map's state is read
  // against the clock again; nothing is asked of the engine.
  'lib/src/providers/mesh_provider.dart#meshPhaseProvider': 1,
  // The own-profile publish retry: armed only while the app is resumed and
  // reaching the profile plane, never the engine, so it is no new wake.
  'lib/src/providers/profile_sync_provider.dart#'
          'OwnProfileSyncController._armFrom':
      1,
  'lib/src/providers/sharing_health_provider.dart#'
          'SharingHealthNotifier.syncTick':
      1,
  'lib/src/providers/sharing_health_provider.dart#'
          'SharingHealthNotifier.tickIntervalForTest':
      1,
  'lib/src/services/background_burst_coordinator.dart#'
          'BackgroundBurstCoordinator._publishPass':
      1,
  'lib/src/services/background_idle_waiter.dart#'
          'BackgroundIdleWaiter.waitUntilIdle':
      1,
  '$_task._attemptSessionReclaim': 1,
  '$_task._awaitFirstDelivery': 1,
  '$_task._runStreamErrorRecovery': 1,
  '$_task._scheduleStreamErrorRearm': 1,
  '$_task._sleepUnlessShuttingDown': 1,
  'lib/src/services/ios_location_source.dart#'
          'MethodChannelIosLocationSource._armConfirmTimer':
      1,
  'lib/src/services/jittered_scheduler.dart#JitteredScheduler._rearm': 1,
  'lib/src/services/live_sync_resubscriber.dart#'
          'LiveSyncResubscriber.onCirclesChanged':
      1,
  'lib/src/services/mls_session_handover.dart#_defaultDelay': 1,
  'lib/src/services/tile_prefetch_service.dart#'
          'TilePrefetchServiceImpl._fetchOne':
      2,
  'lib/src/widgets/circles/member_picker.dart#'
          '_MemberPickerResultsState._scheduleAnnouncement':
      1,
  'lib/src/widgets/circles/missed_invitations_dialog.dart#'
          '_MissedNpubTileState._copy':
      1,
  'lib/src/widgets/common/refresh_ring/refresh_ring_button.dart#'
          '_RefreshRingButtonState._buildControllers':
      1,
  'lib/src/widgets/common/refresh_ring/refresh_ring_button.dart#'
          '_RefreshRingButtonState._reconcileDismiss':
      1,
  'lib/src/widgets/map/sharing_health_banner.dart#'
          '_SharingHealthBannerState._armRerender':
      1,
  // The open statistics sheet reads the mesh's counts again each minute
  // (a read folds what was counted into the store; it drives nothing). The
  // timer is cancelled while the app is away and armed again at its return.
  'lib/src/widgets/mesh/mesh_stats_sheet.dart#_MeshStatsSheetState._arm': 1,
};

/// The sum of [_allowedSites]: a second pin, so an edit that moves a count
/// from one site to another is still a visible change of this number.
const _allowedTotal = 46;

/// The sites of [_allowedSites] that reach the MLS or the live-sync engine,
/// reviewed by hand: the existing wakes. A timer's callback reaches through
/// providers and fields a syntactic walk cannot follow (the receive poll
/// invalidates a provider that fetches), so the walk only proves this list
/// holds every site it CAN see reach engine work.
const _engineWakes = <String>{
  // The live-sync heal and its health check.
  '$_shell#LiveSyncHealBackstop._arm',
  // The flag-off invitation poll (gift wraps opened through the engine).
  '$_shell#_MapShellState._scheduleInvitationPoll',
  // The iOS background catch-up sweep.
  '$_shell#_MapShellState._startIosBackgroundReceiveTimer',
  // The flag-off receive poll and the evolution poll / engine check.
  '$_shell#_MapShellState._startTimers',
  // The post-join burst polls.
  '$_join._scheduleTick',
  '$_join._start',
  // The foreground publish tick and the gaps between its seals.
  'lib/src/services/jittered_scheduler.dart#JitteredScheduler._rearm',
  _publishTick,
  'lib/src/providers/location_sharing_provider.dart#locationPublisherProvider',
  // The health tick (drives, re-invites, leave carry-ons), the KeyPackage
  // tick, and a leave's follow-up.
  '$_maintenance._armHealth',
  '$_maintenance._armKeyPackage',
  '$_maintenance._armLeaveFollowUp',
  // A background burst's gaps between seals.
  _burstPass,
  // The Android service cycle's gaps between seals, and its liveness gap
  // before reclaiming the session.
  '$_task._sleepUnlessShuttingDown',
  '$_task._attemptSessionReclaim',
  // The re-subscriber's debounce before an engine delta.
  _resubscribe,
  // The session handover's wait for the other isolate's release.
  'lib/src/services/mls_session_handover.dart#_defaultDelay',
};

/// Names whose call is engine work: a drive of the fanout records, a leave
/// carry-on, a re-invite lookup, a catch-up or refetch sweep, a live-sync
/// start, heal, resume or health tick, a seal or a publish of a location, an
/// ingest, or a fetch for a circle.
const _engineCalls = {
  'resumeDrive',
  'resume',
  'carryOnLeaves',
  'carryOn',
  'resumeLeave',
  'reinviteOwed',
  'reinvite',
  'runCatchup',
  'runRefusedRefetch',
  'maintainSubscriptionHealth',
  'resumeAfterBackground',
  'claimForeground',
  'ensureRunning',
  'sealLocation',
  'publishLocation',
  'publishSealedLocation',
  'ingest',
  'ingestEvent',
  'fetchMemberLocations',
  'pollEvolutionEvents',
};

const _schedulerCalls = {
  'Timer',
  'Timer.periodic',
  'Future.delayed',
  'Stream.periodic',
};

const _maxHops = 2;

/// One timer or delay site: where it is, how many it holds, and whether any
/// of their callbacks reaches engine work.
class TimerSite {
  /// Creates a site record.
  const TimerSite(this.key, this.count, {required this.reachesEngine});

  /// `path#Class.member`, or `path#member` for a top-level declaration.
  final String key;

  /// How many schedulers the member holds.
  final int count;

  /// Whether a callback reaches an [_engineCalls] name within [_maxHops].
  final bool reachesEngine;

  /// This site and [other], which has the same key, as one.
  TimerSite merge(TimerSite other) => TimerSite(
    key,
    count + other.count,
    reachesEngine: reachesEngine || other.reachesEngine,
  );
}

/// The timer and delay sites in [source], one per enclosing member.
List<TimerSite> timerSites(String source, String path) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final declarations = <String, AstNode>{};
  unit.accept(_Declarations(declarations));
  final finder = _Schedulers();
  unit.accept(finder);

  final byKey = <String, TimerSite>{};
  for (final found in finder.found) {
    final site = TimerSite(
      '$path#${_enclosingName(found.node)}',
      1,
      reachesEngine: found.callbacks.any(
        (callback) => _reaches(callback, declarations),
      ),
    );
    byKey.update(site.key, (known) => known.merge(site), ifAbsent: () => site);
  }
  return byKey.values.toList();
}

bool _reaches(AstNode callback, Map<String, AstNode> declarations) {
  var frontier = <AstNode>[callback];
  final visited = <String>{};
  for (var hop = 0; hop <= _maxHops && frontier.isNotEmpty; hop++) {
    final next = <AstNode>[];
    for (final body in frontier) {
      final called = _Calls()..collect(body);
      if (called.names.any(_engineCalls.contains)) return true;
      for (final name in called.names) {
        final declared = declarations[name];
        if (declared != null && visited.add(name)) next.add(declared);
      }
    }
    frontier = next;
  }
  return false;
}

String _enclosingName(AstNode node) {
  String? member;
  String? owner;
  for (var at = node.parent; at != null; at = at.parent) {
    if (member == null) {
      if (at is MethodDeclaration) member = at.name.lexeme;
      if (at is FunctionDeclaration) member = at.name.lexeme;
      if (at is VariableDeclaration) member = at.name.lexeme;
      if (at is ConstructorDeclaration) member = at.name?.lexeme ?? 'new';
    }
    if (at is ClassDeclaration) owner = at.namePart.typeName.lexeme;
    if (at is MixinDeclaration) owner = at.name.lexeme;
    if (at is ExtensionDeclaration) owner = at.name?.lexeme;
    if (at is EnumDeclaration) owner = at.namePart.typeName.lexeme;
  }
  return owner == null ? '$member' : '$owner.$member';
}

class _Declarations extends RecursiveAstVisitor<void> {
  _Declarations(this._bodies);

  final Map<String, AstNode> _bodies;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _bodies[node.name.lexeme] = node.functionExpression;
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _bodies[node.name.lexeme] = node.body;
    super.visitMethodDeclaration(node);
  }
}

class _Schedulers extends RecursiveAstVisitor<void> {
  final List<({AstNode node, List<AstNode> callbacks})> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    final qualified = target == null
        ? node.methodName.name
        : '${target is TypeLiteral ? target.type.name.lexeme : target}'
              '.${node.methodName.name}';
    if (_schedulerCalls.contains(qualified)) _add(node, node.argumentList);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.name.lexeme;
    final named = node.constructorName.name?.name;
    if (_schedulerCalls.contains(named == null ? type : '$type.$named')) {
      _add(node, node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  void _add(AstNode node, ArgumentList arguments) {
    found.add((
      node: node,
      callbacks: [
        for (final argument in arguments.arguments)
          if (argument is FunctionExpression || argument is Identifier)
            argument,
      ],
    ));
  }
}

class _Calls extends RecursiveAstVisitor<void> {
  final Set<String> names = {};

  void collect(AstNode node) {
    if (node is SimpleIdentifier) names.add(node.name);
    if (node is PrefixedIdentifier) names.add(node.identifier.name);
    node.accept(this);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    names.add(node.methodName.name);
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // A tear-off handed on (`.then(_tick)`) runs that body too.
    names.add(node.name);
    super.visitSimpleIdentifier(node);
  }
}
