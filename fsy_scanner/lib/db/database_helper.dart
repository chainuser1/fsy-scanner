import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

class DatabaseHelper {
  static const String _dbName = 'fsy_scanner.db';
  static Database? _database;

  // Returns the open database instance (opens if not yet open)
  static Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute(appSettingsDDL);
        await db.execute(participantsDDL);
        await db.execute(syncTasksDDL);
        await runMigrations(db);
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        // Handle future migrations here
      },
    );
  }

  // Runs initial data seeding on first creation
  static Future<void> runMigrations(Database db) async {
    // Check if device_id exists in app_settings
    final deviceIdResult = await db.rawQuery(
      'SELECT value FROM app_settings WHERE key = ?',
      ['device_id'],
    );

    if (deviceIdResult.isEmpty) {
      // Generate UUID v4 and save to app_settings
      final uuid = const Uuid().v4();
      await db.insert('app_settings', {
        'key': 'device_id',
        'value': uuid,
      });
    }

    // Set db_version = 1 if not already set
    final versionResult = await db.rawQuery(
      'SELECT value FROM app_settings WHERE key = ?',
      ['db_version'],
    );

    if (versionResult.isEmpty) {
      await db.insert('app_settings', {
        'key': 'db_version',
        'value': '1',
      });
    }
  }
}
