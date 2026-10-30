/// Speaks what Circle details would show, while it is closed.
///
/// The sharing card and the change card live only in Circle details (OD-1),
/// and a live region speaks only while it is mounted. Without this a fault or
/// a note that appears while the sheet is closed would be silent to a
/// screen-reader user (WCAG 2.1 SC 4.1.3). It renders nothing, and it never
/// repeats the message: it says only that there is something to read, and
/// where.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circle_attention_provider.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/change_notices.dart';
import 'package:haven/src/services/circle_service.dart';

/// Announces, while Circle details is closed: the selected circle's sharing
/// fault appearing, and again on the user's return while it stands; its
/// recovery; and a note appearing for any accepted circle.
class SharingHealthAnnouncer extends ConsumerStatefulWidget {
  /// Creates the announcer.
  const SharingHealthAnnouncer({super.key});

  @override
  ConsumerState<SharingHealthAnnouncer> createState() =>
      _SharingHealthAnnouncerState();
}

class _SharingHealthAnnouncerState
    extends ConsumerState<SharingHealthAnnouncer> {
  /// The circle the last verdict was about, and whether it was a shown fault.
  String? _verdictKey;
  bool _faultShown = false;

  /// Disbanded circles already announced: a state the user keeps on purpose
  /// is said once per process, not on every return.
  final Set<String> _disbandedSaid = {};

  /// Circles whose current note was already announced.
  final Set<String> _noticesSaid = {};

  late final ValueListenable<bool> _foreground;

  @override
  void initState() {
    super.initState();
    _foreground = ref.read(sharingHealthForegroundProvider)
      ..addListener(_onForegroundChanged);
  }

  @override
  void dispose() {
    _foreground.removeListener(_onForegroundChanged);
    super.dispose();
  }

  bool get _sheetOpen => ref.read(circleDetailsOpenProvider);

  String? get _selectedKey {
    final selected = ref.read(selectedCircleProvider);
    return selected == null ? null : sharingCircleKey(selected);
  }

  void _say(String message) {
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      ),
    );
  }

  void _onForegroundChanged() {
    if (!_foreground.value || !mounted || _sheetOpen || !_faultShown) return;
    if (_isDisbanded(ref.read(sharingHealthShownProvider))) return;
    _say(AppLocalizations.of(context).sharingHealthAttentionAnnouncement);
  }

  static bool _isDisbanded(SharingHealthShown shown) =>
      shown.health.pausedReason == SharingPausedReason.circleDisbanded;

  void _onVerdict(SharingHealthShown next) {
    final key = _selectedKey;
    // Another circle selected: the last verdict was about a different one, so
    // its end is no recovery to speak.
    final wasShown = key == _verdictKey && _faultShown;
    _verdictKey = key;
    _faultShown = next.isStopped;
    if (_sheetOpen) return;
    final l10n = AppLocalizations.of(context);
    if (!wasShown && next.isStopped) {
      if (_isDisbanded(next) && key != null && !_disbandedSaid.add(key)) {
        return;
      }
      _say(l10n.sharingHealthAttentionAnnouncement);
    } else if (wasShown && next.isRecovered) {
      _say(l10n.sharingHealthResumedAnnouncement);
    }
  }

  void _onNotes(Circle circle, List<ChangeNoteFfi>? notes) {
    if (notes == null) return;
    final key = sharingCircleKey(circle);
    if (toldNotes(notes).isEmpty) {
      _noticesSaid.remove(key);
      return;
    }
    if (!_noticesSaid.add(key)) return;
    // The open sheet's card shows its own circle's note.
    if (_sheetOpen && key == _selectedKey) return;
    _say(
      AppLocalizations.of(
        context,
      ).changeNoticeArrivedAnnouncement(circle.displayName),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SharingHealthShown>(
      sharingHealthShownProvider,
      (_, next) => _onVerdict(next),
    );
    final circles = ref.watch(circlesProvider).valueOrNull ?? const <Circle>[];
    for (final circle in circles) {
      if (circle.membershipStatus != MembershipStatus.accepted) continue;
      ref.listen<AsyncValue<List<ChangeNoteFfi>>>(
        circleNoticeProvider(sharingCircleKey(circle)),
        (_, next) => _onNotes(circle, next.valueOrNull),
      );
    }
    return const SizedBox.shrink();
  }
}
