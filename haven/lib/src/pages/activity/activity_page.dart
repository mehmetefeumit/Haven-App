/// Activity page for Haven.
///
/// Shows a feed of updates from circles, including member joins,
/// location updates, and system notifications.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/models/activity_event.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// Page displaying the activity feed.
///
/// Shows all activity events from circles in reverse chronological order.
/// Supports filtering by event type and marking events as read.
class ActivityPage extends StatefulWidget {
  /// Creates the activity page.
  const ActivityPage({super.key});

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  // Activity events - in production this would come from a service
  List<ActivityEvent> _events = [];
  bool _showUnreadOnly = false;

  List<ActivityEvent> get _filteredEvents {
    if (_showUnreadOnly) {
      return _events.where((e) => !e.isRead).toList();
    }
    return _events;
  }

  int get _unreadCount => _events.where((e) => !e.isRead).length;

  void _markAsRead(String eventId) {
    setState(() {
      final index = _events.indexWhere((e) => e.id == eventId);
      if (index != -1) {
        _events[index] = _events[index].copyWith(isRead: true);
      }
    });
  }

  void _markAllAsRead() {
    setState(() {
      _events = _events.map((e) => e.copyWith(isRead: true)).toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All activity marked as read')),
    );
  }

  void _handleInvitationAccept(InvitationReceivedEvent event) {
    _markAsRead(event.id);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Joined ${event.circleName}')));
  }

  void _handleInvitationDecline(InvitationReceivedEvent event) {
    setState(() {
      _events.removeWhere((e) => e.id == event.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Declined invitation to ${event.circleName}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final filteredEvents = _filteredEvents;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          if (_unreadCount > 0)
            TextButton(
              onPressed: _markAllAsRead,
              child: const Text(
                'Mark all read',
                semanticsLabel: 'Mark all activity as read',
              ),
            ),
          IconButton(
            icon: Icon(
              _showUnreadOnly
                  ? Icons.filter_list
                  : Icons.filter_list_off_outlined,
            ),
            onPressed: () {
              setState(() {
                _showUnreadOnly = !_showUnreadOnly;
              });
            },
            tooltip: _showUnreadOnly ? 'Show all' : 'Show unread only',
          ),
        ],
      ),
      body: filteredEvents.isEmpty
          ? _buildEmptyState()
          : _buildActivityList(filteredEvents, colorScheme),
    );
  }

  Widget _buildEmptyState() {
    if (_showUnreadOnly) {
      return HavenEmptyState(
        icon: Icons.done_all,
        title: 'All Caught Up',
        message: "You've read all your activity updates.",
        actionLabel: 'Show all activity',
        onAction: () {
          setState(() {
            _showUnreadOnly = false;
          });
        },
      );
    }

    return const HavenEmptyState(
      icon: Icons.notifications_none,
      title: 'No Activity',
      message:
          'When you join circles and share locations, '
          'updates will appear here. '
          'All activity data is end-to-end encrypted.',
    );
  }

  Widget _buildActivityList(
    List<ActivityEvent> events,
    ColorScheme colorScheme,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: HavenSpacing.sm),
      itemCount: events.length,
      cacheExtent: 500, // Pre-render 500 logical pixels for smoother scrolling
      itemBuilder: (context, index) {
        final event = events[index];

        // Special handling for invitations
        if (event is InvitationReceivedEvent && !event.isRead) {
          return InvitationActivityItem(
            event: event,
            onAccept: () => _handleInvitationAccept(event),
            onDecline: () => _handleInvitationDecline(event),
          );
        }

        return ActivityItem(event: event, onTap: () => _markAsRead(event.id));
      },
    );
  }
}
