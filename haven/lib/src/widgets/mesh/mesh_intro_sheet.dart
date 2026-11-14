/// What the Bluetooth mesh does and what it costs, told before it is first
/// turned on (`docs/BLUETOOTH_MESH_PLAN.md` §0.4, §7.4;
/// `docs/BLUETOOTH_MESH_M3_DESIGN.md` §D, §E.2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/bidi_isolate.dart';

/// The top corners of the mesh's sheets, as the app's other sheets have them.
const ShapeBorder kMeshSheetShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.vertical(top: Radius.circular(HavenSpacing.base)),
);

/// The handle at the top of the mesh's sheets, as the app's other sheets
/// draw it.
class MeshSheetHandle extends StatelessWidget {
  /// Creates the handle.
  const MeshSheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 32,
      height: 4,
      margin: const EdgeInsets.only(bottom: HavenSpacing.base),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// Shows the mesh's disclosure. With [offerTurnOn] it ends in a choice and
/// answers `true` only for "Turn on"; without, it is there to be read again.
Future<bool?> showMeshIntroSheet(
  BuildContext context, {
  required bool offerTurnOn,
}) => showModalBottomSheet<bool>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  shape: kMeshSheetShape,
  builder: (_) => MeshIntroSheet(offerTurnOn: offerTurnOn),
);

/// Shows the phone's Bluetooth [name], which linked phones can read, between
/// the permission that lets it be read and anything being stored. Answers
/// whether the user went on to turn mesh on.
///
/// The name comes first and largest: it is what the step is for, and at
/// large text a title and a paragraph ahead of it push it out of view.
Future<bool> showMeshNameStep(BuildContext context, String name) async {
  final l10n = AppLocalizations.of(context);
  final go = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      final theme = Theme.of(dialog);
      return AlertDialog(
        scrollable: true,
        // A caption over the name: the name is what must be in view.
        title: Text(l10n.meshNameStepTitle),
        titleTextStyle: theme.textTheme.titleSmall,
        content: MeshBluetoothName(name: name, lead: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.meshTurnOn),
          ),
        ],
      );
    },
  );
  return go ?? false;
}

/// The disclosure, under three headings: every paragraph a text of its own,
/// so a screen reader steps through them, above actions that stay in view.
class MeshIntroSheet extends StatelessWidget {
  /// Creates the disclosure.
  const MeshIntroSheet({required this.offerTurnOn, super.key});

  /// Whether the sheet ends in "Turn on" and "Cancel", or in "Back" alone.
  final bool offerTurnOn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.lg),
      child: Semantics(
        header: true,
        child: Text(text, style: theme.textTheme.titleSmall),
      ),
    );
    Widget paragraph(String text) => Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.sm),
      child: Text(text, style: theme.textTheme.bodyMedium),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HavenSpacing.base,
        HavenSpacing.sm,
        HavenSpacing.base,
        HavenSpacing.base,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MeshSheetHandle(),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.meshIntroTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  heading(l10n.meshIntroHeadingDoes),
                  paragraph(l10n.meshIntroWhat),
                  paragraph(l10n.meshIntroAutoOff),
                  paragraph(l10n.meshIntroBattery),
                  paragraph(l10n.meshIntroClosed),
                  heading(l10n.meshIntroHeadingLearn),
                  paragraph(l10n.meshIntroNearby),
                  paragraph(l10n.meshIntroConnected),
                  const Padding(
                    padding: EdgeInsets.only(top: HavenSpacing.sm),
                    child: MeshBluetoothName(),
                  ),
                  paragraph(l10n.meshIntroBridge),
                  paragraph(l10n.meshIntroRemoved),
                  heading(l10n.meshIntroHeadingKnow),
                  paragraph(l10n.meshIntroStats),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: HavenSpacing.sm),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: HavenSpacing.sm,
              overflowAlignment: OverflowBarAlignment.end,
              children: offerTurnOn
                  ? [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(l10n.commonCancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(l10n.meshTurnOn),
                      ),
                    ]
                  : [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.commonBack),
                      ),
                    ],
            ),
          ),
        ],
      ),
    );
  }
}

/// That linked phones can read the phone's Bluetooth name, the name itself
/// where it can be read, and the way to the system settings that change it.
///
/// The name is held here only while this is on screen, and is read again at
/// every return to the app: the settings it offers are where it changes.
class MeshBluetoothName extends ConsumerStatefulWidget {
  /// Creates the name's lines. [name] is the name already read, where the
  /// caller had to read it first. With [lead] the name stands first, large
  /// and by itself, under a title of the caller's that says what it is.
  const MeshBluetoothName({this.name, this.lead = false, super.key});

  /// The phone's Bluetooth name, if the caller read it.
  final String? name;

  /// Whether the name leads.
  final bool lead;

  @override
  ConsumerState<MeshBluetoothName> createState() => _MeshBluetoothNameState();
}

class _MeshBluetoothNameState extends ConsumerState<MeshBluetoothName> {
  late String? _name = widget.name;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _read);
    if (_name == null) _read();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final name = await ref.read(meshProvider.notifier).bluetoothName();
    if (mounted) setState(() => _name = name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    final name = _name;
    const gap = SizedBox(height: HavenSpacing.sm);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.lead && name != null) ...[
          // The user's own text: isolated, so that a right-to-left name
          // keeps its own order wherever it is laid out.
          Text(bidiIsolate(name), style: theme.textTheme.titleLarge),
          gap,
        ],
        Text(l10n.meshIntroName, style: style),
        gap,
        if (!widget.lead && name != null) ...[
          Text(l10n.meshIntroNameIs(bidiIsolate(name)), style: style),
          gap,
        ],
        if (widget.lead) ...[Text(l10n.meshNameStepChange, style: style), gap],
        // Outlined, so that its edge stands on the text's own.
        OutlinedButton(
          onPressed: ref.read(meshProvider.notifier).openBluetoothSettings,
          child: Text(l10n.meshBluetoothSettings),
        ),
      ],
    );
  }
}
