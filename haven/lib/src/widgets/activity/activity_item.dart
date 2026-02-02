/// Activity item widget for Haven.
///
/// Displays individual activity events in the feed with appropriate
/// styling and icons for each event type.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/models/activity_event.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:intl/intl.dart';

/// Displays a single activity event.
///
/// Renders different layouts based on the event type using pattern matching
/// on the sealed [ActivityEvent] class hierarchy.
class ActivityItem extends StatelessWidget {
  /// Creates an activity item.
  const ActivityItem({required this.event, this.onTap, super.key});

  /// The event to display.
  final ActivityEvent event;

  /// Called when the item is tapped.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: onTap != null,
      label: _semanticLabel,
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.base,
          vertical: HavenSpacing.xs,
        ),
        color: event.isRead
            ? colorScheme.surfaceContainerLow
            : colorScheme.surfaceContainerHigh,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HavenSpacing.md),
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.base),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildIcon(colorScheme),
                const SizedBox(width: HavenSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: event.isRead
                              ? FontWeight.normal
                              : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: HavenSpacing.xs),
                      Text(
                        _subtitle,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: HavenSpacing.sm),
                      Text(
                        _formatTimestamp(event.timestamp),
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!event.isRead)
                  Semantics(
                    label: 'Unread',
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(ColorScheme colorScheme) {
    final (icon, color) = switch (event) {
      MemberJoinedEvent() => (Icons.person_add, HavenSecurityColors.encrypted),
      MemberLeftEvent() => (Icons.person_remove, colorScheme.error),
      InvitationReceivedEvent() => (Icons.mail, colorScheme.primary),
      LocationSharedEvent() => (Icons.location_on, HavenPrivacyColors.exact),
      CircleCreatedEvent() => (Icons.add_circle, HavenSecurityColors.encrypted),
      SystemNotificationEvent() => (Icons.info, colorScheme.secondary),
    };

    return Container(
      padding: const EdgeInsets.all(HavenSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(HavenSpacing.sm),
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }

  String get _title {
    return switch (event) {
      MemberJoinedEvent(memberName: final name, circleName: final circle) =>
        '$name joined $circle',
      MemberLeftEvent(memberName: final name, circleName: final circle) =>
        '$name left $circle',
      InvitationReceivedEvent(
        inviterName: final name,
        circleName: final circle,
      ) =>
        '$name invited you to $circle',
      LocationSharedEvent(circleName: final circle) =>
        'Location shared with $circle',
      CircleCreatedEvent(circleName: final circle) => 'Created circle $circle',
      SystemNotificationEvent(title: final title) => title,
    };
  }

  String get _subtitle {
    return switch (event) {
      MemberJoinedEvent() => 'New member in your circle',
      MemberLeftEvent() => 'Member has left the circle',
      InvitationReceivedEvent() => 'Tap to view invitation',
      LocationSharedEvent() => 'Your location is now visible to members',
      CircleCreatedEvent() => 'End-to-end encrypted group created',
      SystemNotificationEvent(message: final msg) => msg,
    };
  }

  String get _semanticLabel {
    final readStatus = event.isRead ? 'Read' : 'Unread';
    final time = _formatTimestamp(event.timestamp);
    return '$readStatus activity: $_title. $_subtitle. $time';
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      // Use localized date format
      return DateFormat.yMd().format(timestamp);
    }
  }
}

/// Displays an invitation with accept/decline actions.
///
/// Specialized widget for [InvitationReceivedEvent] that shows
/// actionable buttons instead of just displaying the event.
class InvitationActivityItem extends StatelessWidget {
  /// Creates an invitation activity item.
  const InvitationActivityItem({
    required this.event,
    required this.onAccept,
    required this.onDecline,
    super.key,
  });

  /// The invitation event to display.
  final InvitationReceivedEvent event;

  /// Called when the user accepts the invitation.
  final VoidCallback onAccept;

  /// Called when the user declines the invitation.
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: 'Invitation from ${event.inviterName} to join ${event.circleName}',
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.base,
          vertical: HavenSpacing.xs,
        ),
        color: colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(HavenSpacing.sm),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(HavenSpacing.sm),
                    ),
                    child: Icon(
                      Icons.mail,
                      color: colorScheme.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Circle Invitation',
                          style: textTheme.titleSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: HavenSpacing.xs),
                        Text(
                          '${event.inviterName} invited you to '
                          '${event.circleName}',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HavenSpacing.base),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onDecline,
                    child: Text(
                      'Decline',
                      semanticsLabel:
                          'Decline invitation to ${event.circleName}',
                    ),
                  ),
                  const SizedBox(width: HavenSpacing.sm),
                  FilledButton(
                    onPressed: onAccept,
                    child: Text(
                      'Accept',
                      semanticsLabel:
                          'Accept invitation to ${event.circleName}',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
