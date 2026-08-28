/// Providers for the member picker's local directory (plan §9.3/§9.4).
///
/// **Loaded once, filtered in memory.** The alternative — querying per
/// keystroke — would put a SQLCipher round-trip on the keystroke path for a
/// result set that cannot change while the picker is open, and would need a
/// debounce to stay affordable, which is a debounce on the filter itself.
/// The whole directory is a roster-sized list of identifiers and short
/// strings, so holding it for the life of one screen is cheap and the filter
/// over it is a synchronous scan.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/member_directory_service.dart';

/// The local directory of current co-members, loaded when the picker opens.
///
/// `autoDispose` makes it screen-scoped rather than a process cache: closing
/// the picker releases it, and re-opening asks again, so a co-member added
/// in between appears without an invalidation call.
///
/// Watches [circlesProvider] rather than having the service re-fetch it:
/// `circlesProvider` is a non-autoDispose provider the map shell already
/// keeps warm for the life of the process, so this is a cache read, not a
/// second walk of every circle's roster.
///
/// Never resolves to an error — [MemberDirectoryService.loadDirectory]
/// degrades to [MemberDirectory.empty] or [MemberDirectory.readFailed] instead.
final AutoDisposeFutureProvider<MemberDirectory> memberDirectoryProvider =
    FutureProvider.autoDispose<MemberDirectory>((ref) async {
  final circles = await ref.watch(circlesProvider.future);
  return ref
      .watch(memberDirectoryServiceProvider)
      .loadDirectory(circles: circles);
});

/// The directory filtered by the family argument `query`, in rank order.
///
/// The query is a FAMILY ARGUMENT, not a provider of its own. A search
/// field's text already lives in widget state (the `TextEditingController`
/// that renders the caret), and an `autoDispose` `StateProvider` beside it
/// would be a second copy that silently resets to `''` the moment nothing
/// listens — snapping the list back to showing everyone with no keystroke to
/// explain it. Passing the text in has no state to lose.
///
/// A plain [Provider], so it recomputes synchronously the moment the query
/// changes — no debounce, no `Future`, no service call. An empty `query` is
/// R2's auto-populate, which is what the picker shows the moment it opens.
/// Empty while the directory is still loading and after a failed load; the
/// field itself keeps working either way.
///
/// Usage:
/// ```dart
/// final results = ref.watch(memberDirectoryResultsProvider(controller.text));
/// ```
final AutoDisposeProviderFamily<List<MemberCandidate>, String>
    memberDirectoryResultsProvider =
    Provider.autoDispose.family<List<MemberCandidate>, String>((ref, query) {
  final directory = ref.watch(memberDirectoryProvider).valueOrNull;
  if (directory == null) return const <MemberCandidate>[];
  return searchDirectory(directory, query: query);
});
