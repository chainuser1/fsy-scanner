import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../db/database_helper.dart';

class DeviceId {
  static String? _cachedId;

  /// Get the device ID, persisting it to app_settings on first generation.
  /// On subsequent calls, reads from database for persistence across restarts.
  static Future<String> get() async {
    if (_cachedId != null) {
      return _cachedId!;
    }

    // Try to read existing device ID from database
    try {
      final db = await DatabaseHelper.database;
      final result = await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['device_id'],
      );

      if (result.isNotEmpty) {
        final storedId = result.first['value'] as String?;
        if (storedId != null && storedId.isNotEmpty) {
          _cachedId = storedId;
          return _cachedId!;
        }
      }
    } catch (e) {
      // Database might not be initialized yet — fall through to generate new ID
    }

    // Generate a new UUID and only cache it after it is persisted successfully.
    final generatedId = const Uuid().v4();

    try {
      final db = await DatabaseHelper.database;
      await db.insert(
          'app_settings',
          {
            'key': 'device_id',
            'value': generatedId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      _cachedId = generatedId;
      return _cachedId!;
    } catch (e) {
      // If persistence fails, return a temporary ID without caching it so the
      // next call can retry against the database-backed source of truth.
      return generatedId;
    }
  }
}
