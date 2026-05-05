import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Initialize the notification plugin and request permissions.
  static Future<void> init() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(settings);
    // Request notifications permission on Android 13+
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Shows a local heads-up notification that a group is ready for hotel check‑in.
  ///
  /// [groupName] is used as the title (e.g. "Group 1").
  /// [roomsText] is shown in the body (e.g. "256, 257").
  static Future<void> showGroupReadyNotification({
    required String groupName,
    required String roomsText,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'group_complete_channel',
      'Group Completions',
      channelDescription:
          'Notifications when a group is fully ready for hotel check‑in',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    // groupName.hashCode is used as a unique id; subsequent notifications for the same
    // group name will replace the previous one.
    await _plugin.show(
      groupName.hashCode,
      'Group $groupName ready for check‑in',
      'Rooms: $roomsText',
      details,
    );
  }
}
