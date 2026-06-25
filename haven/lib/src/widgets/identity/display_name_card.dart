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
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Possible UI states for the display-name editor.
@visibleForTesting
enum DisplayNameStatus {
  /// The field matches the persisted value.
  saved,

  /// The field has been edited but not yet saved.
  unsaved,

  /// A save is in flight.
  saving,

  /// The most recent save attempt failed.
  failed,
}

/// Card containing the display-name editor.
///
/// Consumes [identityServiceProvider] and [displayNameProvider]; tests can
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
  DisplayNameStatus _status = DisplayNameStatus.saved;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // If the provider already has data when we mount, seed synchronously
    // so the very first paint shows the user's name (not an empty field).
    ref.read(displayNameProvider).whenData(_seedSilently);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  bool get _isDirty => _controller.text.trim() != _savedName;

  /// Sets the controller and status without firing the dirty-state listener.
  ///
  /// Called from `initState` (pre-build, no setState needed) and from
  /// `ref.listen` in `build` (caller wraps in setState).
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
    _status = DisplayNameStatus.saved;
    _loaded = true;
  }

  void _onTextChanged() {
    if (!_loaded) return;
    // While saving or holding a failed state, leave status alone so an
    // in-flight save (or a failure the user has not acknowledged) is not
    // overwritten by an incidental keystroke.
    if (_status == DisplayNameStatus.saving) return;
    final next = _isDirty ? DisplayNameStatus.unsaved : DisplayNameStatus.saved;
    if (next != _status) setState(() => _status = next);
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    // The visible save state is carried by the circular button. To preserve
    // the screen-reader feedback the removed live-region status row provided,
    // announce save outcomes — most importantly failure, which the disabled
    // ->re-enabled button alone may not reliably re-announce. Capture the view
    // and text direction before the first await (no context use after await).
    final view = View.of(context);
    final textDirection = Directionality.of(context);
    final l10n = AppLocalizations.of(context);
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        l10n.displayNameCardSavingLabel,
        textDirection,
      ),
    );
    setState(() => _status = DisplayNameStatus.saving);
    try {
      await ref
          .read(identityServiceProvider)
          .setDisplayName(text.isEmpty ? null : text);
      if (!mounted) return;
      ref.invalidate(displayNameProvider);
      unawaited(
        SemanticsService.sendAnnouncement(
          view,
          l10n.displayNameCardSavedAnnouncement,
          textDirection,
        ),
      );
      setState(() {
        _savedName = text;
        _status = DisplayNameStatus.saved;
      });
    } on IdentityServiceException catch (_) {
      // Detail is logged in debug; surface a generic state to the user.
      debugPrint('[Identity] Display name save failed');
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
      setState(() => _status = DisplayNameStatus.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Seed on first arrival of async data. Guarded by `_loaded` so a
    // subsequent invalidate-after-save does not clobber the field.
    ref.listen<AsyncValue<String?>>(displayNameProvider, (_, next) {
      if (_loaded) return;
      next.whenData((value) => setState(() => _seedSilently(value)));
    });

    final displayNameAsync = ref.watch(displayNameProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: displayNameAsync.when(
          loading: () => _buildLoadingBody(context),
          error: (_, _) => _buildErrorBody(context),
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

  Widget _buildErrorBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.displayNameCardTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          l10n.displayNameCardLoadError,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
        ),
      ],
    );
  }

  Widget _buildLoadedBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.displayNameCardTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: HavenSpacing.md),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: _loaded,
                maxLength: 64,
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
                  hintText: l10n.displayNameCardHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: HavenSpacing.sm),
            _CircularSaveButton(
              status: _status,
              onPressed: (_isDirty && _status != DisplayNameStatus.saving)
                  ? _save
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// Compact circular save button to the right of the display-name field.
///
/// Encodes the current [DisplayNameStatus] through its icon (a distinct shape
/// per state, so the signal is never color-only) and carries a per-state
/// tooltip/accessible label. Kept a [FilledButton] so it inherits the M3 state
/// layer, focus ring, and disabled treatment, and stays a [ButtonStyleButton].
/// The spinner is rendered inside the button while a save is in flight.
class _CircularSaveButton extends StatelessWidget {
  const _CircularSaveButton({required this.status, required this.onPressed});

  final DisplayNameStatus status;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    final (Widget child, String label, Color? background, Color? foreground) =
        switch (status) {
          DisplayNameStatus.saved => (
            const Icon(LucideIcons.check, size: 20),
            l10n.displayNameCardSavedLabel,
            null,
            null,
          ),
          DisplayNameStatus.unsaved => (
            const Icon(LucideIcons.arrowUp, size: 20),
            l10n.displayNameCardSaveLabel,
            null,
            null,
          ),
          DisplayNameStatus.saving => (
            SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.onPrimary,
              ),
            ),
            l10n.displayNameCardSavingLabel,
            null,
            null,
          ),
          DisplayNameStatus.failed => (
            const Icon(LucideIcons.rotateCcw, size: 20),
            l10n.displayNameCardRetryLabel,
            colorScheme.errorContainer,
            colorScheme.onErrorContainer,
          ),
        };

    // Animate the icon/spinner swap unless the user prefers reduced motion.
    final animatedChild = reducedMotion
        ? child
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, animation) =>
                ScaleTransition(scale: animation, child: c),
            child: KeyedSubtree(
              key: ValueKey<DisplayNameStatus>(status),
              child: child,
            ),
          );

    return Tooltip(
      message: label,
      child: FilledButton(
        key: WidgetKeys.displayNameSaveButton,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          minimumSize: const Size(48, 48),
          fixedSize: const Size(48, 48),
          backgroundColor: background,
          foregroundColor: foreground,
        ),
        // Give the icon-only button a state-dependent accessible name. There
        // is no live region in this card; screen readers read this label when
        // the button is focused, and _save() announces save outcomes.
        child: Semantics(
          label: label,
          excludeSemantics: true,
          child: animatedChild,
        ),
      ),
    );
  }
}
