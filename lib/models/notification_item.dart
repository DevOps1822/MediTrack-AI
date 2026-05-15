class NotificationItem {
  NotificationItem({
    required this.id,
    required this.userRole,
    required this.userId,
    required this.title,
    required this.message,
    required this.type,
    this.isRead = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String userRole;
  final String userId;
  final String title;
  final String message;
  final String type;
  bool isRead;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'userRole': userRole,
    'userId': userId,
    'title': title,
    'message': message,
    'type': type,
    'isRead': isRead,
    'createdAt': createdAt.toIso8601String(),
  };

  factory NotificationItem.fromJson(Map<String, dynamic> json) =>
      NotificationItem(
        id: json['id'],
        userRole: json['userRole'],
        userId: json['userId'],
        title: json['title'],
        message: json['message'],
        type: json['type'],
        isRead: json['isRead'] ?? false,
        createdAt: DateTime.parse(json['createdAt']),
      );
}
