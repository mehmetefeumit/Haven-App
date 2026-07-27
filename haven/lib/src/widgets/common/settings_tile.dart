/// Shared settings-row tile.
///
/// Extracted from `settings_page.dart` so the Settings menu and the pages that
/// present their own menu of sub-destinations (Privacy) render identical rows.
/// Keeping one implementation is what stops a second menu from drifting
/// visually against the Settings rows it sits beside.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/widgets/common/disclosure_chevron.dart';

/// A navigation row for a settings menu: leading icon, title, optional
/// subtitle, and a trailing [DisclosureChevron] when the row is tappable.
///
/// The chevron is rendered only when [onTap] is non-null, so a purely
/// informational row does not advertise a destination it does not have.
/// [DisclosureChevron] is used rather than a bare `LucideIcons.chevronRight`
/// because Lucide chevrons do not mirror automatically under RTL locales.
class HavenSettingsTile extends StatelessWidget {
  /// Creates a [HavenSettingsTile].
  const HavenSettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    super.key,
  });

  /// Leading icon, tinted `onSurfaceVariant` so it reads as secondary to the
  /// title.
  final IconData icon;

  /// Primary row label.
  final String title;

  /// Optional supporting line beneath [title].
  final String? subtitle;

  /// Invoked when the row is tapped. When null, no chevron is shown.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(icon, color: colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: onTap != null ? const DisclosureChevron() : null,
      onTap: onTap,
    );
  }
}
