/// Display name card with persistent inline edit/save state.
///
/// The circular save button to the right of the field carries the edit state
/// through its icon/shape (check / up-arrow / spinner / retry) and is disabled
/// when there are no unsaved edits.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/text_input_privacy.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/profile_sync_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/circular_save_button.dart';

/// Card containing the display-name editor.
///
/// Consumes [displayNameProvider] and the services that save; tests can
/// inject mocks via `ProviderScope` overrides.
class DisplayNameCard extends ConsumerStatefulWidget {
  /// Creates a display-name card.
  const DisplayNameCard({super.key});

  @override
  ConsumerState<DisplayNameCard> createState() => _DisplayNameCardState();
}

class _DisplayNameCardState extends ConsumerState<DisplayNameCard> {
  final _controller = TextEditingController();
  String _savedName = '';
  SaveStatus _status = SaveStatus.saved;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // Seed synchronously from whatever is already loaded, so the very first
    // paint shows the user's name (not an empty field): no listener reports a
    // value that landed before this card mounted. Not while it reloads: the
    // value it carries then is the one from before the save that invalidated
    // it.
    final name = ref.read(displayNameProvider);
    if (name.hasValue && !name.isLoading) _seedSilently(name.value);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  bool get _isDirty => _controller.text.trim() != _savedName;

  bool get _canSave => _isDirty && _status != SaveStatus.saving;

  /// Sets the controller and status without firing the dirty-state listener.
  ///
  /// Called from `initState` (pre-build, no setState needed) and from
  /// `ref.listen` in `build` (caller wraps in setState).
  ///
  /// Callers gate re-invocation on `_status == saved` (see the `ref.listen`
  /// callback in [build]) so a slower kind-0 fetch can reseed the field
  /// (plan D12 / Flutter review F1) without ever clobbering an in-progress
  /// `unsaved` / `saving` / `failed` edit.
  void _seedSilently(String? value) {
    final trimmed = value?.trim() ?? '';
    if (_loaded && _controller.text == trimmed) return;
    // Detach the listener so programmatic text assignment does not race
    // with the dirty-state machine and momentarily flip to `unsaved`.
    _controller
      ..removeListener(_onTextChanged)
      ..text = trimmed
      ..addListener(_onTextChanged);
    _savedName = trimmed;
    _status = SaveStatus.saved;
    _loaded = true;
  }

  void _onTextChanged() {
    if (!_loaded) return;
    // An in-flight save keeps its status until it lands; any other state,
    // a failure included, follows the text.
    if (_status == SaveStatus.saving) return;
    final next = _isDirty ? SaveStatus.unsaved : SaveStatus.saved;
    if (next != _status) setState(() => _status = next);
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    // The button carries the visible state; announce only the outcome — most
    // importantly failure, which the disabled->re-enabled button alone may
    // not reliably re-announce. Capture before the first await.
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    final l10n = AppLocalizations.of(context);
    final syncController = ref.read(ownProfileSyncProvider.notifier);
    final identityService = ref.read(identityServiceProvider);
    final profileService = ref.read(profileServiceProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _status = SaveStatus.saving);
    try {
      // A row with no name falls back to the device-local one, so a clear
      // drops that first: an interrupted clear never brings the old name back.
      if (text.isEmpty) await identityService.setDisplayName(null);
      // One local SQLCipher transaction that both holds the edit and queues
      // its publish (unconditional — public by default, owner-directed
      // 2026-07-16), so it is the save; [displayNameProvider] drops the
      // local name once the row holds one.
      await profileService.updateOwnProfile(displayName: text);
      // Publish, and show the name everywhere, even if the card is gone,
      // since `ref` is unusable then.
      unawaited(syncController.sync());
      container
        ..invalidate(displayNameProvider)
        ..invalidate(ownProfileProvider);
      if (!mounted) return;
      unawaited(
        SemanticsService.sendAnnouncement(
          view,
          l10n.displayNameCardSavedAnnouncement,
          textDirection,
        ),
      );
      setState(() {
        _savedName = text;
        // If the field was edited again while this save was in flight, the
        // NEWEST text is what still needs saving — mark it unsaved (re-opens
        // Save) rather than silently reporting the older, already-persisted
        // text as current. Marking it `saved` here would also re-open the
        // reseed gate (`_mayReseed`) and let a stale fetched value clobber
        // the newer, not-yet-saved keystrokes.
        _status = _controller.text.trim() == text
            ? SaveStatus.saved
            : SaveStatus.unsaved;
      });
    } on Object catch (e) {
      // Detail is logged in debug; surface a generic state to the user.
      debugPrint('[Identity] Display name save failed: ${e.runtimeType}');
      if (!mounted) return;
      // Assertive so the failure interrupts speech and is not missed.
      unawaited(
        SemanticsService.sendAnnouncement(
          view,
          l10n.displayNameCardSaveFailedAnnouncement,
          textDirection,
          assertiveness: Assertiveness.assertive,
        ),
      );
      setState(() => _status = SaveStatus.failed);
    }
  }

  /// Whether a newly read name may safely reseed the field: before the very
  /// first seed lands (`!_loaded`), or once it has and the field carries no
  /// unsaved/in-flight/failed edit (`_status == saved`).
  ///
  /// Flutter review F1 (plan D12): the seed-once guard used to stop
  /// reseeding forever after `_loaded` first flipped `true`, which could
  /// discard a name the (slower) kind-0 fetch wrote later. Relaxed here to
  /// keep reseeding whenever there is nothing to clobber.
  bool get _mayReseed => !_loaded || _status == SaveStatus.saved;

  @override
  Widget build(BuildContext context) {
    // The user's name as every surface shows it. Not while it reloads:
    // `when` would hand over the value from before the save that
    // invalidated it.
    ref.listen<AsyncValue<String?>>(displayNameProvider, (_, next) {
      if (!_mayReseed || next.isLoading) return;
      next.when(
        data: (name) => setState(() => _seedSilently(name)),
        error: (_, _) {
          // No name could be read — seed an EDITABLE empty field rather than
          // blocking the whole card (F2): once `_loaded` flips true here the
          // loaded body always renders, never an uneditable error-only state.
          // A field already seeded keeps its text.
          if (!_loaded) setState(() => _seedSilently(null));
        },
        loading: () {},
      );
    });

    final displayNameAsync = ref.watch(displayNameProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: displayNameAsync.when(
          // A profile row reloading under the name must not take the field
          // away from someone typing in it.
          skipLoadingOnReload: true,
          loading: () => _buildLoadingBody(context),
          // F2: keep the field usable on a local-read error rather than
          // rendering an uneditable error-only state — the `ref.listen`
          // error branch above seeds an empty value so `_loaded` is true by
          // the time this renders.
          error: (_, _) => _buildLoadedBody(context, loadError: true),
          data: (_) => _buildLoadedBody(context),
        ),
      ),
    );
  }

  Widget _buildLoadingBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.displayNameCardTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: HavenSpacing.md),
        const LinearProgressIndicator(),
      ],
    );
  }

  /// The loaded (editable) card body — also rendered on a local-read error
  /// (F2), in which case [loadError] shows a small caption above the field
  /// instead of blocking editing entirely. The "profile is public" disclosure
  /// is NOT repeated here per field — it lives once, in the shared
  /// `PublicProfileNotice` shown elsewhere on the page (identity_page.dart).
  Widget _buildLoadedBody(BuildContext context, {bool loadError = false}) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                // Enabled once the field has been seeded (including the F2
                // empty-seed-on-error case above) — never gated on the
                // async `data`/`error` branch alone, so a load error never
                // blocks typing.
                enabled: _loaded,
                maxLength: 64,
                // Publishing this name is the user's choice; the keyboard's
                // learned-word dictionary is a different recipient — outside
                // Haven's storage and its logout wipe.
                enableIMEPersonalizedLearning: false,
                autofillHints: kNoAutofill,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (_canSave) unawaited(_save());
                },
                // Hide the default 0/64 counter — it adds visual noise to a
                // single-field card.
                buildCounter:
                    (
                      _, {
                      required int currentLength,
                      required bool isFocused,
                      required int? maxLength,
                    }) => null,
                decoration: InputDecoration(
                  labelText: l10n.displayNameCardTitle,
                  hintText: l10n.displayNameCardHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: HavenSpacing.sm),
            CircularSaveButton(
              buttonKey: WidgetKeys.displayNameSaveButton,
              status: _status,
              onPressed: _canSave ? _save : null,
              savedLabel: l10n.displayNameCardSavedLabel,
              saveLabel: l10n.displayNameCardSaveLabel,
              savingLabel: l10n.displayNameCardSavingLabel,
              retryLabel: l10n.displayNameCardRetryLabel,
            ),
          ],
        ),
        if (loadError) ...[
          const SizedBox(height: HavenSpacing.sm),
          Text(
            l10n.displayNameCardLoadError,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
          ),
        ],
      ],
    );
  }
}
