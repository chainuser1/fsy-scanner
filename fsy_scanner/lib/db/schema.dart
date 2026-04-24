const String participantsDDL = '''
  CREATE TABLE IF NOT EXISTS participants (
    id TEXT PRIMARY KEY,
    full_name TEXT NOT NULL,
    stake TEXT, ward TEXT, gender TEXT,
    room_number TEXT, table_number TEXT,
    tshirt_size TEXT, medical_info TEXT, note TEXT, status TEXT,
    registered INTEGER DEFAULT 0,
    verified_at INTEGER, printed_at INTEGER,
    registered_by TEXT, sheets_row INTEGER NOT NULL,
    raw_json TEXT, updated_at INTEGER
  )
''';

const String syncTasksDDL = '''
  CREATE TABLE IF NOT EXISTS sync_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL, payload TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    attempts INTEGER DEFAULT 0, last_error TEXT,
    created_at INTEGER, completed_at INTEGER
  )
''';

const String appSettingsDDL = '''
  CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY, value TEXT
  )
''';


class DatabaseHelper {
  static const String createSyncQueueTable = '''
    CREATE TABLE SyncQueue (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL,
      tableName TEXT NOT NULL,
      recordId TEXT,
      data TEXT NOT NULL,
      createdAt INTEGER NOT NULL
    )
  ''';
}
