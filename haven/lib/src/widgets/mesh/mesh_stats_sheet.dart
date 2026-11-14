/// What the Bluetooth mesh has done: four counts, one status line, when it
/// turns itself off, and the actions on them
/// (`docs/BLUETOOTH_MESH_PLAN.md` §7.5, §7.6).
///
/// The counts are shown and never logged (Security Rule 15).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/mesh/mesh_flow.dart';
import 'package:haven/src/widgets/mesh/mesh_intro_sheet.dart';

/// How often the open sheet reads the mesh again.
const Duration kMeshStatsRefresh = Duration(minutes: 1);

/// Whether the sheet is on screen.
bool _shown = false;

/// Shows the mesh's statistics. One sheet however it is asked for — the mesh
/// button, its screen-reader action, the Settings row, a tapped notice: asked
/// while it is open, nothing is added.
Future<void> showMeshStatsSheet(BuildContext context) async {
  if (_shown) return;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    shape: kMeshSheetShape,
    builder: (_) => const MeshStatsSheet(),
  );
}

/// The statistics sheet's content.
class MeshStatsSheet extends ConsumerStatefulWidget {
  /// Creates the statistics sheet.
  const MeshStatsSheet({super.key});

  @override
  ConsumerState<MeshStatsSheet> createState() => _MeshStatsSheetState();
}

class _MeshStatsSheetState extends ConsumerState<MeshStatsSheet> {
  Timer? _refresh;
  late final AppLifecycleListener _lifecycle;

  /// What the sheet's own turn-on or turn-off came to, when it failed: said
  /// here, since a snackbar would be under the sheet.
  MeshFailure? _failure;

  @override
  void initState() {
    super.initState();
    _shown = true;
    unawaited(_read());
    // No timer runs while the app is away: there the session is the
    // background's, and a read would fail and be what the sheet shows on the
    // way back. A state not yet reported is an app in front.
    _lifecycle = AppLifecycleListener(onStateChange: _arm);
    _arm(WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed);
  }

  void _arm(AppLifecycleState lifecycle) {
    _refresh?.cancel();
    _refresh = lifecycle != AppLifecycleState.resumed
        ? null
        : Timer.periodic(
            kMeshStatsRefresh,
            (_) => unawaited(ref.read(meshProvider.notifier).refresh()),
          );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _lifecycle.dispose();
    _shown = false;
    super.dispose();
  }

  /// A drive of the sheet's own before the read, when it opens: a phone
  /// with no circle due to publish drives the mesh at no tick, and what it
  /// received meanwhile is counted at a drive.
  Future<void> _read() async {
    final mesh = ref.read(meshProvider.notifier);
    await mesh.drive();
    await mesh.refresh();
  }

  /// On or off through the mesh button's own flow.
  Future<void> _toggle({required bool on}) async {
    setState(() => _failure = null);
    final asked = await (on ? meshTurnOn(context) : meshTurnOff(context));
    if (mounted) setState(() => _failure = asked.failure);
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.meshStatsResetTitle),
        content: Text(l10n.meshStatsResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.meshStatsResetConfirm),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await ref.read(meshProvider.notifier).resetCounts();
  }

  String _status(
    AppLocalizations l10n,
    MeshPhase phase, {
    required bool linked,
  }) {
    switch (phase) {
      case MeshPhase.off:
        return l10n.meshStatusOff;
      case MeshPhase.paused:
        return l10n.meshStatusPaused;
      case MeshPhase.on:
        if (linked) return l10n.meshStatusConnected;
        final canSearch = ref.watch(meshRadioStatusProvider)?.canSearch ?? true;
        return canSearch ? l10n.meshStatusSearching : l10n.meshStatusFindable;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final mesh = ref.read(meshProvider.notifier);
    final read = ref.watch(meshProvider);
    // A read that failed still carries the one before it: counts that may
    // no longer be true are not shown as the counts.
    final stats = read.hasError ? null : read.valueOrNull;
    final phase = ref.watch(meshPhaseProvider);
    final until = ref.watch(meshOnUntilProvider);
    final asked = ref.watch(meshAskedProvider);
    final failure = _failure;
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // The session the first column counts: the one under way, or — with
    // mesh off — the last, whose counts the store keeps until the next.
    final session = stats?.on_ ?? false
        ? l10n.meshStatsThisSession
        : l10n.meshStatsLastSession;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        HavenSpacing.base,
        HavenSpacing.sm,
        HavenSpacing.base,
        HavenSpacing.base,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MeshSheetHandle(),
          Semantics(
            header: true,
            child: Text(
              l10n.meshStatsTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: HavenSpacing.sm),
          Text(
            _status(l10n, phase, linked: stats?.linked ?? false),
            style: theme.textTheme.bodyLarge,
          ),
          if (phase != MeshPhase.off && until != null)
            Text(l10n.meshTurnsOffAt(until), style: quiet),
          const SizedBox(height: HavenSpacing.sm),
          OverflowBar(
            spacing: HavenSpacing.sm,
            overflowSpacing: HavenSpacing.xs,
            children: [
              // Not on a phone that answered it cannot use mesh: a control
              // that could never work.
              if (!ref.watch(meshAvailableProvider))
                const SizedBox.shrink()
              else if (phase == MeshPhase.off)
                FilledButton(
                  onPressed: asked ? null : () => _toggle(on: true),
                  child: Text(l10n.meshTurnOn),
                )
              else
                OutlinedButton(
                  onPressed: asked ? null : () => _toggle(on: false),
                  child: Text(l10n.meshTurnOff),
                ),
              // Paused is Bluetooth switched off: this is where it goes
              // back on.
              if (phase == MeshPhase.paused)
                OutlinedButton(
                  onPressed: mesh.openBluetoothSettings,
                  child: Text(l10n.meshBluetoothSettings),
                ),
              if (stats?.on_ ?? false)
                TextButton(
                  onPressed: mesh.keepOn,
                  child: Text(l10n.meshKeepOn),
                ),
            ],
          ),
          if (failure != null) ...[
            const SizedBox(height: HavenSpacing.xs),
            Semantics(
              liveRegion: true,
              child: Text(
                failure.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            if (failure.remedy case final remedy?)
              OutlinedButton(
                onPressed: remedy,
                child: Text(failure.remedyLabel!),
              ),
          ],
          const SizedBox(height: HavenSpacing.base),
          if (stats == null) ...[
            Text(l10n.meshStatsUnavailable, style: theme.textTheme.bodyMedium),
            TextButton(onPressed: _read, child: Text(l10n.commonRetry)),
          ] else ...[
            _Counts(
              row: l10n.meshStatsFromCircles,
              session: session,
              sinceOn: stats.fromCirclesSinceOn,
              allTime: stats.fromCirclesTotal,
            ),
            const SizedBox(height: HavenSpacing.base),
            _Counts(
              row: l10n.meshStatsPassedOn,
              session: session,
              sinceOn: stats.passedOnSinceOn,
              allTime: stats.passedOnTotal,
            ),
            const SizedBox(height: HavenSpacing.md),
            Text(
              l10n.meshStatsFootnote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: HavenSpacing.sm),
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () =>
                    showMeshIntroSheet(context, offerTurnOn: false),
                child: Text(l10n.meshStatsAbout),
              ),
              if (stats != null)
                TextButton(onPressed: _reset, child: Text(l10n.meshStatsReset)),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of the two things counted, with its two counts side by side: for the
/// session, and for all time. Each count is one semantics node that says
/// what it counts, so the headings round it are not read apart.
class _Counts extends StatelessWidget {
  const _Counts({
    required this.row,
    required this.session,
    required this.sinceOn,
    required this.allTime,
  });

  final String row;
  final String session;
  final BigInt sinceOn;
  final BigInt allTime;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget count(String column, BigInt value) {
      final shown = l10n.commonNumber(value.toInt());
      return Expanded(
        child: Semantics(
          label: l10n.meshStatsCell(row, column, shown),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A count is never broken over two lines or cut: one that
                // does not fit its column is drawn smaller, whole. Its
                // digits are of one width, so a count that changes does not
                // shift.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    shown,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Text(
                  column,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Text(row, style: theme.textTheme.titleSmall)),
        const SizedBox(height: HavenSpacing.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            count(session, sinceOn),
            const SizedBox(width: HavenSpacing.base),
            count(l10n.meshStatsAllTime, allTime),
          ],
        ),
      ],
    );
  }
}
