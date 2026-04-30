import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

class DatabaseHelper {
  static const String _dbName = 'fsy_scanner.db';
  static const String _dbVersion = '5';
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
      version: 5,
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
          await runMigrations(db);
        }
        await runMigrations(db);
      },
    );
  }

  static Future<void> runMigrations(Database db) async {
    // device_id
    final deviceIdResult = await db.rawQuery(
      'SELECT value FROM app_settings WHERE key = ?',
      ['device_id'],
    );
    if (deviceIdResult.isEmpty) {
      final uuid = const Uuid().v4();
      await db.insert('app_settings', {
        'key': 'device_id',
        'value': uuid,
      });
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
    final profileCount =
        await db.rawQuery('SELECT COUNT(*) AS cnt FROM event_profiles');
    if ((profileCount.first['cnt'] as int?) == 0) {
      await db.insert('event_profiles', {
        'name': 'Default',
        'sheets_id': '', // will be filled by .env later
        'sheets_tab': '',
        'event_name': '',
      });
    }
  }
}
