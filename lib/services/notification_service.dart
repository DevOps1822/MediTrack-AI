import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();
  final plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android: android));
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> show(String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'meditrack',
        'MediTrack',
        channelDescription: 'MediTrack local notifications',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  Future<void> scheduleFollowUp({
    required int id,
    required String title,
    required String body,
    required DateTime date,
  }) async {
    final scheduled = tz.TZDateTime.from(
      date.isBefore(DateTime.now())
          ? DateTime.now().add(const Duration(minutes: 1))
          : date,
      tz.local,
    );
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'meditrack_followups',
        'MediTrack Follow-ups',
        channelDescription: 'Scheduled MediTrack follow-up reminders',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await plugin.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}
