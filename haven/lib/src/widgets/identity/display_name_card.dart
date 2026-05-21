/// Display name card with persistent inline edit/save state.
///
/// Replaces a fleeting success SnackBar with an always-visible status row
/// that telegraphs Saved / Unsaved changes / Saving / Save failed at a
/// glance. The Save button is disabled when there are no unsaved edits.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
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
  static const _narrowBreakpoint = 360.0;

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
    setState(() => _status = DisplayNameStatus.saving);
    try {
      await ref
          .read(identityServiceProvider)
          .setDisplayName(text.isEmpty ? null : text);
      if (!mounted) return;
      ref.invalidate(displayNameProvider);
      setState(() {
        _savedName = text;
        _status = DisplayNameStatus.saved;
      });
    } on IdentityServiceException catch (_) {
      // Detail is logged in debug; surface a generic state to the user.
      debugPrint('[Identity] Display name save failed');
      if (!mounted) return;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Display Name', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: HavenSpacing.md),
        const LinearProgressIndicator(),
      ],
    );
  }

  Widget _buildErrorBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Display Name', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          'Could not load your display name. Try again later.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
        ),
      ],
    );
  }

  Widget _buildLoadedBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Display Name', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: HavenSpacing.md),
        TextField(
          controller: _controller,
          enabled: _loaded,
          maxLength: 64,
          // Hide the default 0/64 counter — it conflicts visually with
          // the status row and adds noise to a single-field card.
          buildCounter:
              (
                _, {
                required int currentLength,
                required bool isFocused,
                required int? maxLength,
              }) => null,
          decoration: const InputDecoration(
            hintText: 'Enter your display name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: HavenSpacing.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            final indicator = _StatusIndicator(status: _status);
            final saveButton = _SaveButton(
              status: _status,
              onPressed: (_isDirty && _status != DisplayNameStatus.saving)
                  ? _save
                  : null,
            );
            if (constraints.maxWidth < _narrowBreakpoint) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(alignment: Alignment.centerLeft, child: indicator),
                  const SizedBox(height: HavenSpacing.sm),
                  saveButton,
                ],
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: indicator),
                const SizedBox(width: HavenSpacing.sm),
                saveButton,
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Inline status indicator: icon + text describing the current edit state.
///
/// Color signal is carried by the icon so the text can stay on
/// high-contrast `onSurface` (WCAG AA) for body-size labels.
class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({required this.status});

  final DisplayNameStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final (IconData icon, Color iconColor, String label) = switch (status) {
      DisplayNameStatus.saved => (
        LucideIcons.circleCheck,
        HavenSecurityColors.encrypted,
        'Saved',
      ),
      DisplayNameStatus.unsaved => (
        LucideIcons.circle,
        HavenSecurityColors.warning,
        'Unsaved changes',
      ),
      DisplayNameStatus.saving => (
        LucideIcons.loaderCircle,
        colorScheme.onSurfaceVariant,
        'Saving…',
      ),
      DisplayNameStatus.failed => (
        LucideIcons.triangleAlert,
        HavenSecurityColors.danger,
        'Save failed — try again',
      ),
    };

    final isFailed = status == DisplayNameStatus.failed;
    // Failed text uses danger color (~4.5:1 vs white surface, passes AA).
    // Other states use onSurface so the icon alone carries the color signal.
    final textColor = isFailed
        ? HavenSecurityColors.danger
        : colorScheme.onSurface;
    final semanticLabel = isFailed ? 'Error: save failed, try again' : label;

    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    final iconWidget = Icon(icon, size: 16, color: iconColor);
    final animatedIcon = reducedMotion
        ? iconWidget
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: KeyedSubtree(
              key: ValueKey<DisplayNameStatus>(status),
              child: iconWidget,
            ),
          );

    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          animatedIcon,
          const SizedBox(width: HavenSpacing.xs),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: textColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Save button that shows a spinner while a save is in flight.
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.status, required this.onPressed});

  final DisplayNameStatus status;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isSaving = status == DisplayNameStatus.saving;
    return FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size(72, 48)),
      onPressed: onPressed,
      child: isSaving
          ? SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            )
          : const Text('Save'),
    );
  }
}
