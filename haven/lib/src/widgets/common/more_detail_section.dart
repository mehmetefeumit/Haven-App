/// Collapsible "in more detail" region for long-form explanatory pages.
///
/// This is the single place technical depth lives on the Privacy pages, so a
/// reader who wants the protocol-level answer can reach it while a reader who
/// does not is never shown it. Built as one reusable widget rather than an
/// [ExpansionTile] per page for an accessibility reason: the framework's
/// [ExpansionTile] announces state changes and supplies expand/collapse hints,
/// but does not set the formal `expanded` semantics flag that assistive
/// technology uses to report collapsed state *before* the user interacts.
/// Wiring that once, here, is testable; wiring it per page is not.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A disclosure region whose [children] are hidden until the user expands it.
///
/// Collapsed by default — the point of the widget is that depth is opt-in.
/// The header is a 48dp-minimum tap target at every text scale, carries the
/// `expanded` semantics flag plus an action hint, and announces its new state
/// on toggle. Expanding does not scroll the header away, so the reader keeps
/// their place.
class HavenMoreDetailSection extends StatefulWidget {
  /// Creates a [HavenMoreDetailSection].
  const HavenMoreDetailSection({
    required this.label,
    required this.children,
    required this.expandHint,
    required this.collapseHint,
    required this.expandedAnnouncement,
    required this.collapsedAnnouncement,
    super.key,
  });

  /// Header text, e.g. "In more detail".
  final String label;

  /// Content revealed when expanded.
  final List<Widget> children;

  /// Screen-reader hint describing the action while collapsed.
  final String expandHint;

  /// Screen-reader hint describing the action while expanded.
  final String collapseHint;

  /// Announced when the region becomes expanded.
  final String expandedAnnouncement;

  /// Announced when the region becomes collapsed.
  final String collapsedAnnouncement;

  @override
  State<HavenMoreDetailSection> createState() => _HavenMoreDetailSectionState();
}

class _HavenMoreDetailSectionState extends State<HavenMoreDetailSection> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    // The visual change is obvious to a sighted user but silent otherwise, so
    // state is announced explicitly rather than left to the reader to discover.
    SemanticsService.sendAnnouncement(
      View.of(context),
      _expanded ? widget.expandedAnnouncement : widget.collapsedAnnouncement,
      Directionality.of(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Honour the platform "reduce motion" setting: an expand animation is
    // decorative, and for some users it is actively harmful.
    final animate = !MediaQuery.disableAnimationsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          hint: _expanded ? widget.collapseHint : widget.expandHint,
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(HavenSpacing.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: HavenSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    // Chevron rotation, not a swapped glyph, so the control
                    // reads as one affordance changing state. Vertical
                    // rotation needs no RTL mirroring.
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: animate
                          ? const Duration(milliseconds: 200)
                          : Duration.zero,
                      child: Icon(
                        LucideIcons.chevronDown,
                        size: 20,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}
