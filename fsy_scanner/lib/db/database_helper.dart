import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

class DatabaseHelper {
  static const String _dbName = 'fsy_scanner.db';
  static const String _dbVersion = '8';
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: 8,
      onCreate: (Database db, int version) async {
        await db.execute(appSettingsDDL);
        await db.execute(participantsDDL);
        await db.execute(participantsSearchDDL);
        await db.execute(participantsSearchInsertTriggerDDL);
        await db.execute(participantsSearchUpdateTriggerDDL);
        await db.execute(participantsSearchDeleteTriggerDDL);
        await db.execute(syncTasksDDL);
        await db.execute(printJobsDDL);
        await db.execute(printJobAttemptsDDL);
        await db.execute(eventProfilesDDL);
        await db.execute(analyticsSavedViewsDDL);
        await runMigrations(db);
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute(eventProfilesDDL);
        }
        if (oldVersion < 3) {
          await db.execute(participantsSearchDDL);
          await db.execute(participantsSearchInsertTriggerDDL);
          await db.execute(participantsSearchUpdateTriggerDDL);
          await db.execute(participantsSearchDeleteTriggerDDL);
        }
        if (oldVersion < 4) {
          await db.execute(printJobsDDL);
        }
        if (oldVersion < 5) {
          await db.execute(printJobAttemptsDDL);
        }
        if (oldVersion < 6) {
          await db.execute(analyticsSavedViewsDDL);
        }
        if (oldVersion < 7) {
          await _ensureParticipantColumns(db);
        }
        if (oldVersion < 8) {
          await _migrateToV8(db);
        }
        if (oldVersion < 1) {
          await db.execute(appSettingsDDL);
          await db.execute(participantsDDL);
          await db.execute(participantsSearchDDL);
          await db.execute(participantsSearchInsertTriggerDDL);
          await db.execute(participantsSearchUpdateTriggerDDL);
          await db.execute(participantsSearchDeleteTriggerDDL);
          await db.execute(syncTasksDDL);
          await db.execute(printJobsDDL);
          await db.execute(printJobAttemptsDDL);
          await db.execute(eventProfilesDDL);
          await db.execute(analyticsSavedViewsDDL);
          await runMigrations(db);
        }
        await runMigrations(db);
      },
    );
  }

  static Future<void> runMigrations(Database db) async {
    await _ensureParticipantColumns(db);

    // device_id
    final deviceIdResult = await db.rawQuery(
      'SELECT value FROM app_settings WHERE key = ?',
      ['device_id'],
    );
    if (deviceIdResult.isEmpty) {
      final uuid = const Uuid().v4();
      await db.insert('app_settings', {'key': 'device_id', 'value': uuid});
    }

    // db_version
    final versionResult = await db.rawQuery(
      'SELECT value FROM app_settings WHERE key = ?',
      ['db_version'],
    );
    if (versionResult.isEmpty) {
      await db.insert('app_settings', {
        'key': 'db_version',
        'value': _dbVersion,
      });
    } else {
      await db.update(
        'app_settings',
        {'value': _dbVersion},
        where: 'key = ?',
        whereArgs: ['db_version'],
      );
    }

    await db.execute(participantsSearchDDL);
    await db.execute(participantsSearchInsertTriggerDDL);
    await db.execute(participantsSearchUpdateTriggerDDL);
    await db.execute(participantsSearchDeleteTriggerDDL);
    await db.execute(printJobsDDL);
    await db.execute(printJobAttemptsDDL);
    await db.execute(analyticsSavedViewsDDL);
    await db.delete('participants_search');
    await db.execute('''
      INSERT INTO participants_search (
        id,
        full_name,
        stake,
        ward,
        room_number,
        table_number
      )
      SELECT
        id,
        COALESCE(full_name, ''),
        COALESCE(stake, ''),
        COALESCE(ward, ''),
        COALESCE(room_number, ''),
        COALESCE(table_number, '')
      FROM participants
    ''');

    // Seed default profile if none exist
    final profileCount = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM event_profiles',
    );
    if ((profileCount.first['cnt'] as int?) == 0) {
      await db.insert('event_profiles', {
        'name': 'Default',
        'sheets_id': '', // will be filled by .env later
        'sheets_tab': '',
        'event_name': '',
      });
    }
  }

  /// Migration v8: extend event_profiles with additional columns
  static Future<void> _migrateToV8(Database db) async {
    final tableInfo = await db.rawQuery('PRAGMA table_info(event_profiles)');
    final existingColumns = tableInfo
        .map((row) => row['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();

    if (!existingColumns.contains('organization_name')) {
      await db.execute(
        "ALTER TABLE event_profiles ADD COLUMN organization_name TEXT DEFAULT ''",
      );
    }
    if (!existingColumns.contains('col_map_override')) {
      await db.execute(
        "ALTER TABLE event_profiles ADD COLUMN col_map_override TEXT DEFAULT ''",
      );
    }
    if (!existingColumns.contains('google_service_account_email')) {
      await db.execute(
        "ALTER TABLE event_profiles ADD COLUMN google_service_account_email TEXT DEFAULT ''",
      );
    }
    if (!existingColumns.contains('google_service_account_private_key')) {
      await db.execute(
        "ALTER TABLE event_profiles ADD COLUMN google_service_account_private_key TEXT DEFAULT ''",
      );
    }
    // Also seed google creds from .env if not already set
    final emailResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['google_service_account_email'],
    );
    if (emailResult.isEmpty) {
      final envEmail = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
      if (envEmail != null && envEmail.isNotEmpty) {
        await db.insert('app_settings', {
          'key': 'google_service_account_email',
          'value': envEmail,
        });
      }
    }
    final keyResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['google_service_account_private_key'],
    );
    if (keyResult.isEmpty) {
      final envKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];
      if (envKey != null && envKey.isNotEmpty) {
        await db.insert('app_settings', {
          'key': 'google_service_account_private_key',
          'value': envKey,
        });
      }
    }
  }

  static Future<void> _ensureParticipantColumns(Database db) async {
    final tableInfo = await db.rawQuery('PRAGMA table_info(participants)');
    final existingColumns = tableInfo
        .map((row) => row['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();

    if (!existingColumns.contains('registration_source')) {
      await db.execute(
        'ALTER TABLE participants ADD COLUMN registration_source TEXT',
      );
    }
    if (!existingColumns.contains('signed_by')) {
      await db.execute('ALTER TABLE participants ADD COLUMN signed_by TEXT');
    }
  }
}
