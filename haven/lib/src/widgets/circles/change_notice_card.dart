/// The card in Circle details that tells the user what became of changes to
/// the circle, and acknowledges a notice only once the user has read it.
///
/// An acknowledgement is all-or-nothing for the notice it read, and
/// acknowledging a dropped removal clears the targets that hold the circle's
/// sends. So when a removal the user asked for was dropped and someone it
/// named is still listed, a plain Dismiss would quietly resume sharing with
/// the person they tried to remove: the card asks them instead, and only an
/// explicit, confirmed "keep them" acknowledges.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circle_attention_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/change_notices.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/bidi_isolate.dart';
import 'package:haven/src/widgets/circles/remove_member_action.dart';

/// The fixed sentence for a told [note], or `null` for a level note, which
/// the card does not list as something to acknowledge (the sharing card says
/// the levels as causes). Exhaustive with no `_`.
String? changeNoteSentence(ChangeNoteFfi note, AppLocalizations l10n) =>
    switch (note) {
      ChangeNoteFfi.removalUndone => l10n.changeNoteRemovalUndone,
      ChangeNoteFfi.changeUndone => l10n.changeNoteChangeUndone,
      ChangeNoteFfi.mayBeOutOfStep => l10n.changeNoteMayBeOutOfStep,
      ChangeNoteFfi.reinviteOwed => l10n.changeNoteReinviteOwed,
      ChangeNoteFfi.changeUnrecorded => l10n.changeNoteChangeUnrecorded,
      ChangeNoteFfi.queuedChangeDropped => l10n.changeNoteQueuedChangeDropped,
      ChangeNoteFfi.queuedChangesHeld => l10n.changeNoteQueuedChangesHeld,
      ChangeNoteFfi.queuedRemovalDropped =>
        l10n.changeNoteQueuedRemovalDropped,
      ChangeNoteFfi.changeWithdrawn => l10n.changeNoteChangeWithdrawn,
      ChangeNoteFfi.welcomeOwed => l10n.changeNoteWelcomeOwed,
      ChangeNoteFfi.unreadChange ||
      ChangeNoteFfi.unreadLocation ||
      ChangeNoteFfi.awaitsForeground ||
      ChangeNoteFfi.routingCollision => null,
    };

/// Lists [circle]'s notice and acknowledges it once the user has read it.
class ChangeNoticeCard extends ConsumerStatefulWidget {
  /// Creates the card for [circle].
  const ChangeNoticeCard({required this.circle, super.key});

  /// The circle, as the sheet last read it.
  final Circle circle;

  @override
  ConsumerState<ChangeNoticeCard> createState() => _ChangeNoticeCardState();
}

class _ChangeNoticeCardState extends ConsumerState<ChangeNoticeCard> {
  /// Fences a read the circle changed under, or the card left.
  int _generation = 0;

  /// What the last read handed over, levels included.
  List<ChangeNoteFfi> _notes = const [];

  /// Who a dropped removal named that is still listed; `null` when that
  /// could not be read, which keeps the removal form (fail closed).
  List<String>? _kept = const [];

  /// Completes the showing the core waits on: `true` once the user has
  /// acknowledged the notice on screen, `false` when the card left first.
  Completer<bool>? _pending;

  /// Whether the showing in flight ended in the user's acknowledgement.
  bool _acknowledged = false;

  /// The read that last showed something: a read that found no note shows
  /// nothing, and what an earlier one showed must not stay on screen.
  int _shownGeneration = -1;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(ChangeNoticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A removal made since, or the circle's state moving, changes what is
    // true to show: read the notice again.
    if (!listEquals(oldWidget.circle.mlsGroupId, widget.circle.mlsGroupId) ||
        !listEquals(oldWidget.circle.members, widget.circle.members) ||
        oldWidget.circle.engineState != widget.circle.engineState) {
      _start();
    }
  }

  @override
  void dispose() {
    // Closing the sheet acknowledges nothing.
    _release();
    super.dispose();
  }

  void _release() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  void _start() {
    _release();
    final generation = ++_generation;
    unawaited(_run(generation));
  }

  Future<void> _run(int generation) async {
    try {
      await ref
          .read(changeNoticesProvider)
          .showAndAcknowledge(
            widget.circle.mlsGroupId,
            (notes) => _show(generation, notes),
          );
    } on Object catch (e) {
      debugPrint('[Notice] show failed: ${e.runtimeType}');
    }
    if (!mounted || generation != _generation) return;
    if (_shownGeneration != generation && _notes.isNotEmpty) {
      setState(() => _notes = const []);
    }
    if (!_acknowledged) return;
    _acknowledged = false;
    ref.invalidate(circleNoticeProvider(sharingCircleKey(widget.circle)));
    // Read once more: a note written since shows, and what still stands (an
    // information line) stays on screen.
    _start();
  }

  Future<bool> _show(int generation, List<ChangeNoteFfi> notes) async {
    if (!mounted || generation != _generation) return false;
    _shownGeneration = generation;
    final told = toldNotes(notes);
    List<String>? kept = const [];
    if (told.contains(ChangeNoteFfi.queuedRemovalDropped)) {
      try {
        kept = await ref
            .read(circleServiceProvider)
            .unmadeRemovalMembers(widget.circle.mlsGroupId);
      } on Object catch (_) {
        // Logged by the service. Unknown is held as "someone may still be
        // listed".
        kept = null;
      }
      if (!mounted || generation != _generation) return false;
    }
    // Nothing to acknowledge: a notice of levels alone shows no card, bar an
    // information line, and is never offered a Dismiss that drops nothing.
    final pending = told.isEmpty ? null : Completer<bool>();
    setState(() {
      _notes = notes;
      _kept = kept;
      _pending = pending;
    });
    return pending?.future ?? false;
  }

  void _acknowledge() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _acknowledged = true;
    setState(() => _pending = null);
    pending.complete(true);
  }

  Future<void> _confirmKeep() async {
    final l10n = AppLocalizations.of(context);
    final keep =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final scheme = Theme.of(dialogContext).colorScheme;
            return AlertDialog(
              scrollable: true,
              title: Text(l10n.changeNoticeKeepConfirmTitle),
              content: Text(l10n.changeNoticeKeepConfirmBody),
              actions: [
                TextButton(
                  // Focused by default: the safe answer changes nothing.
                  autofocus: true,
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.commonCancel),
                ),
                TextButton(
                  key: WidgetKeys.changeNoticeKeepConfirm,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.changeNoticeKeepConfirmAction),
                ),
              ],
            );
          },
        ) ??
        false;
    if (keep && mounted) _acknowledge();
  }

  /// Removes again everyone the dropped removal named who is still listed.
  /// Nothing is acknowledged: the hold ends when the removal is made, and the
  /// next read then offers the plain Dismiss.
  Future<void> _removeAgain(List<CircleMember> members) async {
    for (final member in members) {
      if (!mounted) return;
      await removeMemberAndReport(
        context: context,
        ref: ref,
        circle: widget.circle,
        member: member,
      );
    }
  }

  void _reviewMembers() {
    ref.read(circleMemberListRequestProvider.notifier).state++;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // A note written while the sheet is open, with no roster or engine-state
    // change to re-read on: shown now, and spoken by the card's live region,
    // since the announcer leaves an open sheet's note to the card.
    ref.listen<AsyncValue<List<ChangeNoteFfi>>>(
      circleNoticeProvider(sharingCircleKey(widget.circle)),
      (_, next) {
        final notes = next.valueOrNull;
        if (notes != null && !listEquals(notes, _notes)) _start();
      },
    );
    final l10n = AppLocalizations.of(context);
    final told = toldNotes(_notes);
    final unreadLocation = _notes.contains(ChangeNoteFfi.unreadLocation);
    if (told.isEmpty && !unreadLocation) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onCard = scheme.onSecondaryContainer;
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(color: onCard);

    final kept = _kept;
    final removalHeld =
        told.contains(ChangeNoteFfi.queuedRemovalDropped) &&
        (kept == null || kept.isNotEmpty);
    final keptMembers = [
      for (final hex in kept ?? const <String>[])
        ...widget.circle.members.where((m) => m.pubkey == hex),
    ];
    final keptNames = [
      for (final member in keptMembers) resolveRemovalDisplayName(ref, member),
    ];
    final self = ref.watch(identityProvider).valueOrNull?.pubkeyHex;
    final isAdmin =
        self != null &&
        widget.circle.members.any((m) => m.pubkey == self && m.isAdmin);
    final sentences = [
      for (final note in told) ?changeNoteSentence(note, l10n),
    ];
    // Shown with each name bidi-isolated, so a right-to-left name cannot
    // reorder the list; spoken raw, as a screen reader would read the marks.
    final keptLine = keptNames.isEmpty
        ? null
        : '${l10n.changeNoticeStillInCircleLabel} '
              '${keptNames.map(bidiIsolate).join(', ')}';
    final keptSpoken = keptNames.isEmpty
        ? null
        : '${l10n.changeNoticeStillInCircleLabel} ${keptNames.join(', ')}';
    final awaiting = _pending != null;

    // Spaced from what is above only when it renders: an empty card leaves
    // no gap.
    final card = Card(
      key: WidgetKeys.changeNoticeCard,
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              // ONE node, spoken once when it appears or changes while the
              // sheet is open (WCAG 2.1 SC 4.1.3); the buttons stay outside.
              container: true,
              liveRegion: told.isNotEmpty,
              explicitChildNodes: true,
              label: [
                l10n.changeNoticeHeading,
                ...sentences,
                ?keptSpoken,
                if (unreadLocation) l10n.changeNoteUnreadLocation,
              ].join('\n'),
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.changeNoticeHeading,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: onCard,
                      ),
                    ),
                    for (final sentence in sentences) ...[
                      const SizedBox(height: HavenSpacing.xs),
                      Text(sentence, style: bodyStyle),
                    ],
                    if (keptLine != null) ...[
                      const SizedBox(height: HavenSpacing.xs),
                      Text(keptLine, style: bodyStyle),
                    ],
                    if (unreadLocation) ...[
                      const SizedBox(height: HavenSpacing.xs),
                      Text(l10n.changeNoteUnreadLocation, style: bodyStyle),
                    ],
                  ],
                ),
              ),
            ),
            if (awaiting) ...[
              const SizedBox(height: HavenSpacing.sm),
              // Wraps at large text scales instead of overflowing.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: HavenSpacing.sm,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  if (told.contains(ChangeNoteFfi.removalUndone))
                    TextButton(
                      key: WidgetKeys.changeNoticeReviewMembers,
                      style: TextButton.styleFrom(foregroundColor: onCard),
                      onPressed: _reviewMembers,
                      child: Text(l10n.changeNoticeReviewMembers),
                    ),
                  if (removalHeld) ...[
                    if (isAdmin && keptMembers.isNotEmpty)
                      TextButton(
                        key: WidgetKeys.changeNoticeRemoveAgain,
                        style: TextButton.styleFrom(foregroundColor: onCard),
                        onPressed: () => _removeAgain(keptMembers),
                        child: Text(l10n.changeNoticeRemoveAgain),
                      ),
                    TextButton(
                      key: WidgetKeys.changeNoticeKeepMembers,
                      style: TextButton.styleFrom(foregroundColor: onCard),
                      onPressed: _confirmKeep,
                      child: Text(l10n.changeNoticeKeepMembers),
                    ),
                  ] else
                    TextButton(
                      key: WidgetKeys.changeNoticeDismiss,
                      style: TextButton.styleFrom(foregroundColor: onCard),
                      onPressed: _acknowledge,
                      child: Text(l10n.commonDismiss),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.sm),
      child: card,
    );
  }
}
