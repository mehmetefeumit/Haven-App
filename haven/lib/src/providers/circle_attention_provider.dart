/// Which circles need the user's attention while Circle details is closed.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/change_notices.dart';
import 'package:haven/src/services/circle_service.dart';

/// Whether a Circle details sheet is open. Written only by the code that
/// opens one, before it opens and after it closes; never during a build.
final circleDetailsOpenProvider = StateProvider<bool>((ref) => false);

/// Bumped to ask the circles sheet to show its member list.
final circleMemberListRequestProvider = StateProvider<int>((ref) => 0);

/// The mls group id a [sharingCircleKey] was made from.
List<int> groupIdOfCircleKey(String key) => [
  for (var i = 0; i + 1 < key.length; i += 2)
    int.parse(key.substring(i, i + 2), radix: 16),
];

/// The notes of the circle keyed `key`, re-read whenever the circle list is.
/// Empty when it carries none or cannot be read: the card reads it again.
final AutoDisposeFutureProviderFamily<List<ChangeNoteFfi>, String>
circleNoticeProvider = FutureProvider.autoDispose
    .family<List<ChangeNoteFfi>, String>((ref, key) async {
      ref.watch(circlesProvider);
      try {
        final read = await ref
            .read(changeNoticesProvider)
            .read(groupIdOfCircleKey(key));
        return read?.notes ?? const [];
      } on Object catch (e) {
        debugPrint('[Notice] read failed: ${e.runtimeType}');
        return const [];
      }
    });

/// Whether the circle keyed `key` needs attention: a note it has not been
/// shown, a circle its engine does not hold live, or — for the selected
/// circle — a sharing fault Circle details shows.
final AutoDisposeProviderFamily<bool, String> circleNeedsAttentionProvider =
    Provider.autoDispose.family<bool, String>((ref, key) {
      final notes = ref.watch(circleNoticeProvider(key)).valueOrNull;
      if (toldNotes(notes ?? const []).isNotEmpty) return true;
      final circles = ref.watch(circlesProvider).valueOrNull ?? const [];
      for (final circle in circles) {
        if (sharingCircleKey(circle) != key ||
            circle.membershipStatus != MembershipStatus.accepted) {
          continue;
        }
        if (circle.engineState != CircleEngineState.live) return true;
      }
      final selected = ref.watch(selectedCircleProvider);
      return selected != null &&
          sharingCircleKey(selected) == key &&
          ref.watch(sharingHealthShownProvider).isStopped;
    });
