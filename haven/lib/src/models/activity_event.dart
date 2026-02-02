/// Activity event models for Haven.
///
/// Defines the types of events that appear in the activity feed.
library;

/// An event in the activity feed.
sealed class ActivityEvent {
  /// Creates an activity event.
  const ActivityEvent({
    required this.id,
    required this.timestamp,
    this.isRead = false,
  });

  /// Unique identifier for this event.
  final String id;

  /// When the event occurred.
  final DateTime timestamp;

  /// Whether the user has read this event.
  final bool isRead;

  /// Creates a copy with optionally updated fields.
  ActivityEvent copyWith({bool? isRead});
}

/// A member joined a circle.
class MemberJoinedEvent extends ActivityEvent {
  /// Creates a member joined event.
  const MemberJoinedEvent({
    required super.id,
    required super.timestamp,
    required this.memberName,
    required this.circleName,
    super.isRead,
  });

  /// Name of the member who joined.
  final String memberName;

  /// Name of the circle they joined.
  final String circleName;

  @override
  MemberJoinedEvent copyWith({bool? isRead}) => MemberJoinedEvent(
    id: id,
    timestamp: timestamp,
    memberName: memberName,
    circleName: circleName,
    isRead: isRead ?? this.isRead,
  );
}

/// A member left a circle.
class MemberLeftEvent extends ActivityEvent {
  /// Creates a member left event.
  const MemberLeftEvent({
    required super.id,
    required super.timestamp,
    required this.memberName,
    required this.circleName,
    super.isRead,
  });

  /// Name of the member who left.
  final String memberName;

  /// Name of the circle they left.
  final String circleName;

  @override
  MemberLeftEvent copyWith({bool? isRead}) => MemberLeftEvent(
    id: id,
    timestamp: timestamp,
    memberName: memberName,
    circleName: circleName,
    isRead: isRead ?? this.isRead,
  );
}

/// An invitation was received.
class InvitationReceivedEvent extends ActivityEvent {
  /// Creates an invitation received event.
  const InvitationReceivedEvent({
    required super.id,
    required super.timestamp,
    required this.inviterName,
    required this.circleName,
    super.isRead,
  });

  /// Name of the person who sent the invitation.
  final String inviterName;

  /// Name of the circle.
  final String circleName;

  @override
  InvitationReceivedEvent copyWith({bool? isRead}) => InvitationReceivedEvent(
    id: id,
    timestamp: timestamp,
    inviterName: inviterName,
    circleName: circleName,
    isRead: isRead ?? this.isRead,
  );
}

/// Location was shared with a circle.
class LocationSharedEvent extends ActivityEvent {
  /// Creates a location shared event.
  const LocationSharedEvent({
    required super.id,
    required super.timestamp,
    required this.circleName,
    super.isRead,
  });

  /// Name of the circle location was shared with.
  final String circleName;

  @override
  LocationSharedEvent copyWith({bool? isRead}) => LocationSharedEvent(
    id: id,
    timestamp: timestamp,
    circleName: circleName,
    isRead: isRead ?? this.isRead,
  );
}

/// A circle was created.
class CircleCreatedEvent extends ActivityEvent {
  /// Creates a circle created event.
  const CircleCreatedEvent({
    required super.id,
    required super.timestamp,
    required this.circleName,
    super.isRead,
  });

  /// Name of the created circle.
  final String circleName;

  @override
  CircleCreatedEvent copyWith({bool? isRead}) => CircleCreatedEvent(
    id: id,
    timestamp: timestamp,
    circleName: circleName,
    isRead: isRead ?? this.isRead,
  );
}

/// A system notification.
class SystemNotificationEvent extends ActivityEvent {
  /// Creates a system notification event.
  const SystemNotificationEvent({
    required super.id,
    required super.timestamp,
    required this.title,
    required this.message,
    super.isRead,
  });

  /// Notification title.
  final String title;

  /// Notification message.
  final String message;

  @override
  SystemNotificationEvent copyWith({bool? isRead}) => SystemNotificationEvent(
    id: id,
    timestamp: timestamp,
    title: title,
    message: message,
    isRead: isRead ?? this.isRead,
  );
}
