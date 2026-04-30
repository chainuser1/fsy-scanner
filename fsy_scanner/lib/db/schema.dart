const String participantsDDL = '''
  CREATE TABLE IF NOT EXISTS participants (
    id TEXT PRIMARY KEY,
    full_name TEXT NOT NULL,
    stake TEXT, ward TEXT, gender TEXT,
    room_number TEXT, table_number TEXT,
    tshirt_size TEXT, medical_info TEXT, note TEXT, status TEXT,
    age INTEGER, birthday TEXT,
    verified_at INTEGER, printed_at INTEGER,
    registered_by TEXT, sheets_row INTEGER NOT NULL,
    raw_json TEXT, updated_at INTEGER
  )
''';

const String participantsSearchDDL = '''
  CREATE VIRTUAL TABLE IF NOT EXISTS participants_search
  USING fts4(
    id UNINDEXED,
    full_name,
    stake,
    ward,
    room_number,
    table_number,
    tokenize=unicode61
  )
''';

const String participantsSearchInsertTriggerDDL = '''
  CREATE TRIGGER IF NOT EXISTS participants_search_ai
  AFTER INSERT ON participants
  BEGIN
    INSERT INTO participants_search (
      id,
      full_name,
      stake,
      ward,
      room_number,
      table_number
    ) VALUES (
      NEW.id,
      COALESCE(NEW.full_name, ''),
      COALESCE(NEW.stake, ''),
      COALESCE(NEW.ward, ''),
      COALESCE(NEW.room_number, ''),
      COALESCE(NEW.table_number, '')
    );
  END;
''';

const String participantsSearchUpdateTriggerDDL = '''
  CREATE TRIGGER IF NOT EXISTS participants_search_au
  AFTER UPDATE ON participants
  BEGIN
    DELETE FROM participants_search WHERE id = OLD.id;
    INSERT INTO participants_search (
      id,
      full_name,
      stake,
      ward,
      room_number,
      table_number
    ) VALUES (
      NEW.id,
      COALESCE(NEW.full_name, ''),
      COALESCE(NEW.stake, ''),
      COALESCE(NEW.ward, ''),
      COALESCE(NEW.room_number, ''),
      COALESCE(NEW.table_number, '')
    );
  END;
''';

const String participantsSearchDeleteTriggerDDL = '''
  CREATE TRIGGER IF NOT EXISTS participants_search_ad
  AFTER DELETE ON participants
  BEGIN
    DELETE FROM participants_search WHERE id = OLD.id;
  END;
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

const String eventProfilesDDL = '''
  CREATE TABLE IF NOT EXISTS event_profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    sheets_id TEXT NOT NULL,
    sheets_tab TEXT NOT NULL,
    event_name TEXT NOT NULL
  )
''';
