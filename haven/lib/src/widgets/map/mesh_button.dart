/// The Bluetooth mesh's button on the map: a tap turns mesh on or off, a hold
/// shows what it has done (`docs/BLUETOOTH_MESH_PLAN.md` §7.4–§7.5;
/// `docs/BLUETOOTH_MESH_M3_DESIGN.md` §E.1).
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/mesh_aura_geometry.dart';
import 'package:haven/src/utils/reduce_motion.dart';
import 'package:haven/src/widgets/common/long_message_snack_bar.dart';
import 'package:haven/src/widgets/mesh/mesh_flow.dart';
import 'package:haven/src/widgets/mesh/mesh_stats_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// How long a word on the mesh stays on the map.
const Duration kMeshSaid = Duration(seconds: 8);

/// The air between the button and what stands beside or above it.
const double _kGap = HavenSpacing.sm;

enum _Slot { button, notice }

/// The mesh button in its corner of the shell, and beside it — until the user
/// dismisses it — the notice that mesh was turned off by something other
/// than them. Fills the shell and takes touches only on those two.
///
/// The state is told by the icon, the surface and the semantics, never by
/// colour alone; the aura is decoration over it. No tooltip: a tooltip's own
/// trigger is the hold.
class MeshButton extends ConsumerStatefulWidget {
  /// Creates the mesh button.
  const MeshButton({super.key});

  /// The button's face.
  static const Key faceKey = ValueKey('mesh-button');

  /// The mark that a phone is linked.
  static const Key linkedKey = ValueKey('mesh-button-linked');

  /// The mark that mesh is being turned on.
  static const Key startingKey = ValueKey('mesh-button-starting');

  /// The notice of a stop the user did not make.
  static const Key stoppedKey = ValueKey('mesh-stopped-notice');

  @override
  ConsumerState<MeshButton> createState() => _MeshButtonState();
}

class _MeshButtonState extends ConsumerState<MeshButton> {
  StreamSubscription<MeshRadioAction>? _noticeTaps;

  /// This button's snackbar now showing, if one is.
  Object? _saying;

  /// The stop the notice tells is known to be the twelve hours running out.
  bool _byDeadline = false;

  /// The start under way has been announced.
  bool _startAnnounced = false;

  @override
  void initState() {
    super.initState();
    _noticeTaps = ref.read(meshNoticeTapsProvider).listen(_onNoticeTap);
  }

  @override
  void dispose() {
    unawaited(_noticeTaps?.cancel());
    super.dispose();
  }

  /// A tapped notice opens Haven here. "Keep on" restarts the twelve hours
  /// first; the sheet then shows the new time, or that mesh is off.
  Future<void> _onNoticeTap(MeshRadioAction action) async {
    if (action == MeshRadioAction.keepOn) {
      await ref.read(meshProvider.notifier).keepOn();
    }
    if (mounted) await showMeshStatsSheet(context);
  }

  // The hold's haptic is the ink well's own.
  void _openStats() => unawaited(showMeshStatsSheet(context));

  Future<void> _turnOn() async {
    final l10n = AppLocalizations.of(context);
    final say = _sayer();
    final asked = await meshTurnOn(context);
    if (asked.done) {
      say(
        l10n.meshTurnedOn,
        undo: SnackBarAction(
          label: l10n.meshUndo,
          onPressed: () {
            if (mounted) unawaited(_turnOff());
          },
        ),
      );
    } else if (asked.failure case final failure?) {
      say(failure.message, failure: failure);
    }
  }

  Future<void> _turnOff() async {
    final say = _sayer();
    final asked = await meshTurnOff(context);
    if (asked.failure case final failure?) say(failure.message);
  }

  /// What says a word at the bottom of the map, clear of this button and of
  /// the map controls opposite: under it, a tap meant for the button would
  /// land on the word. Made before the flow it speaks for, since a phone
  /// that cannot use mesh loses this button under it.
  ///
  /// One of this button's own still showing gives way to the next; another's
  /// is left to be read. Said in the app's snackbar for long messages: at
  /// large text on a small phone the word scrolls there, where a plain
  /// snackbar lifted this high runs off the top of the screen, and an
  /// action's label wraps under it. A word with a remedy stays until closed;
  /// any other goes after [kMeshSaid].
  void Function(String message, {SnackBarAction? undo, MeshFailure? failure})
  _sayer() {
    final messenger = ScaffoldMessenger.of(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final shell = MediaQuery.sizeOf(context);
    final button = meshButtonRect(shell, viewPadding);
    final margin = EdgeInsets.fromLTRB(
      button.left,
      0,
      viewPadding.right + HavenSpacing.base + kMeshButtonSize + _kGap,
      shell.height - button.top + _kGap,
    );
    return (message, {undo, failure}) {
      if (_saying != null) messenger.hideCurrentSnackBar();
      final token = Object();
      void shown() => _saying = token;
      final remedy = failure?.remedy;
      final bar = longMessageSnackBar(
        // The messenger's own: this button may be gone by now.
        messenger.context,
        message,
        action: remedy == null
            ? undo
            : SnackBarAction(
                label: failure!.remedyLabel!,
                onPressed: () => unawaited(remedy()),
              ),
        lasts: remedy == null ? kMeshSaid : null,
        margin: margin,
        onVisible: shown,
        dismiss: AppLocalizations.of(messenger.context).meshStoppedOk,
      );
      unawaited(
        messenger.showSnackBar(bar).closed.then((_) {
          if (_saying == token) _saying = null;
        }),
      );
    };
  }

  void _announce(String message) => unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    ),
  );

  /// A change the user did not make is told: a stop by the notice beside the
  /// button, a pause to a screen reader. Their own tap is not told twice.
  void _onPhase(MeshPhase? was, MeshPhase now) {
    final userOff = ref.read(meshUserOffProvider.notifier);
    if (now != MeshPhase.off) userOff.state = false;
    if (was == null || was == MeshPhase.off) return;
    if (now == MeshPhase.paused) {
      _announce(AppLocalizations.of(context).meshNoticePaused);
    } else if (now == MeshPhase.off && !userOff.state) {
      // The one cause known here: the clock has passed the deadline the
      // engine gave. Any other stop is told with no cause.
      final until = ref.read(meshOnUntilProvider);
      _byDeadline = until != null && !clock.now().isBefore(until);
      ref.read(meshStoppedNoticeProvider.notifier).state = true;
    }
  }

  /// The notice is owed — by the line above, or by a reconcile that turned
  /// mesh off. One for a stop the user asked for is taken back unshown.
  void _onStoppedNotice(bool? was, bool owed) {
    if (!owed) {
      _byDeadline = false;
    } else if (!(was ?? false)) {
      if (ref.read(meshUserOffProvider)) {
        final notice = ref.read(meshStoppedNoticeProvider.notifier);
        unawaited(Future.microtask(() => notice.state = false));
      } else {
        _announce(_stoppedCopy(AppLocalizations.of(context)));
      }
    }
  }

  String _stoppedCopy(AppLocalizations l10n) =>
      _byDeadline ? l10n.meshStoppedAfterDeadline : l10n.meshStoppedNotice;

  /// A start is said once to a screen reader, which cannot see its mark.
  void _onStarting(bool? was, bool starting) {
    if (!starting || _startAnnounced) return;
    _startAnnounced = true;
    _announce(AppLocalizations.of(context).meshTurningOn);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final phase = ref.watch(meshPhaseProvider);
    final linked =
        phase == MeshPhase.on &&
        (ref.watch(meshProvider).valueOrNull?.linked ?? false);
    final owed =
        ref.watch(meshStoppedNoticeProvider) && !ref.watch(meshUserOffProvider);
    ref
      ..listen(meshPhaseProvider, _onPhase)
      ..listen(meshStoppedNoticeProvider, _onStoppedNotice)
      ..listen(meshStartingProvider, _onStarting)
      ..listen(meshAskedProvider, (_, asked) {
        if (!asked) _startAnnounced = false;
      });
    return CustomMultiChildLayout(
      delegate: _CornerLayout(MediaQuery.viewPaddingOf(context)),
      children: [
        LayoutId(
          id: _Slot.button,
          child: _Face(
            phase: phase,
            linked: linked,
            starting: ref.watch(meshStartingProvider),
            onTap: () =>
                unawaited(phase == MeshPhase.off ? _turnOn() : _turnOff()),
            onStats: _openStats,
          ),
        ),
        if (owed)
          LayoutId(
            id: _Slot.notice,
            child: _StoppedNotice(
              message: _stoppedCopy(l10n),
              onTurnOn: () => unawaited(_turnOn()),
              onDismiss: () =>
                  ref.read(meshStoppedNoticeProvider.notifier).state = false,
            ),
          ),
      ],
    );
  }
}

/// Puts the button on [meshButtonRect] — the rect the aura's wave starts
/// from — and the notice beside it, clear of the map controls opposite.
class _CornerLayout extends MultiChildLayoutDelegate {
  _CornerLayout(this.viewPadding);

  final EdgeInsets viewPadding;

  @override
  void performLayout(Size size) {
    final rect = meshButtonRect(size, viewPadding);
    layoutChild(_Slot.button, BoxConstraints.tight(rect.size));
    positionChild(_Slot.button, rect.topLeft);
    if (!hasChild(_Slot.notice)) return;
    final left = rect.right + _kGap;
    // The controls' column is as wide as this button and as far from its
    // edge.
    final right =
        size.width -
        viewPadding.right -
        HavenSpacing.base -
        kMeshButtonSize -
        _kGap;
    final notice = layoutChild(
      _Slot.notice,
      BoxConstraints(
        maxWidth: (right - left).clamp(0, double.infinity),
        maxHeight: (rect.bottom - viewPadding.top - _kGap).clamp(
          0,
          double.infinity,
        ),
      ),
    );
    positionChild(_Slot.notice, Offset(left, rect.bottom - notice.height));
  }

  @override
  bool shouldRelayout(_CornerLayout old) => old.viewPadding != viewPadding;
}

class _Face extends StatelessWidget {
  const _Face({
    required this.phase,
    required this.linked,
    required this.starting,
    required this.onTap,
    required this.onStats,
  });

  final MeshPhase phase;
  final bool linked;
  final bool starting;
  final VoidCallback onTap;
  final VoidCallback onStats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final on = phase == MeshPhase.on;
    final ink = on ? Colors.white : scheme.onSurface;
    // The struck-through icon is for the one state in which Bluetooth is
    // off: on a mesh that is merely off it would read as a fault.
    final icon = switch (phase) {
      MeshPhase.paused => LucideIcons.bluetoothOff,
      MeshPhase.on when linked => LucideIcons.bluetoothConnected,
      _ => LucideIcons.bluetooth,
    };
    final radius = BorderRadius.circular(HavenSpacing.sm);
    return Semantics(
      key: MeshButton.faceKey,
      container: true,
      button: true,
      // On or off is told once, by the toggle; what else is true of it, by
      // the value.
      label: l10n.meshButtonLabel,
      toggled: phase != MeshPhase.off,
      value: switch (phase) {
        MeshPhase.paused => l10n.meshButtonValuePaused,
        MeshPhase.on when linked => l10n.meshButtonValueConnected,
        _ => null,
      },
      onTap: onTap,
      onTapHint: phase == MeshPhase.off
          ? l10n.meshButtonHintTurnOn
          : l10n.meshButtonHintTurnOff,
      onLongPress: onStats,
      onLongPressHint: l10n.meshButtonHintStats,
      // The hold again, for whoever cannot hold: in the screen reader's
      // actions menu.
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.meshStatsTitle): onStats,
      },
      child: ExcludeSemantics(
        // The shadow of the map controls opposite.
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Material(
            // Filled while on, outlined otherwise: told by the surface as
            // well as by the icon.
            color: on ? HavenMeshColors.active : scheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: switch (phase) {
                MeshPhase.off => BorderSide(color: scheme.outlineVariant),
                MeshPhase.paused => const BorderSide(
                  color: HavenMeshColors.active,
                  width: 2,
                ),
                MeshPhase.on => BorderSide.none,
              },
            ),
            child: InkWell(
              onTap: onTap,
              onLongPress: onStats,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(icon, size: 24, color: ink),
                  if (linked)
                    const Positioned(
                      key: MeshButton.linkedKey,
                      top: 8,
                      right: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox.square(dimension: 8),
                      ),
                    ),
                  if (phase == MeshPhase.paused)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(LucideIcons.pause, size: 12, color: ink),
                    ),
                  if (starting)
                    SizedBox.square(
                      key: MeshButton.startingKey,
                      dimension: 38,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: ink,
                        // With motion reduced, a ring that does not turn.
                        value: reduceMotionOf(context) ? 0.75 : null,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// That mesh turned off, with the way back on, until dismissed.
class _StoppedNotice extends StatelessWidget {
  const _StoppedNotice({
    required this.message,
    required this.onTurnOn,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onTurnOn;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      key: MeshButton.stoppedKey,
      color: theme.colorScheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(HavenSpacing.sm),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          HavenSpacing.md,
          HavenSpacing.sm,
          HavenSpacing.xs,
          0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: theme.textTheme.bodyMedium),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton(
                    onPressed: onDismiss,
                    child: Text(l10n.meshStoppedOk),
                  ),
                  TextButton(onPressed: onTurnOn, child: Text(l10n.meshTurnOn)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
