const String participantsDDL = '''
  CREATE TABLE IF NOT EXISTS participants (
    id TEXT PRIMARY KEY,
    full_name TEXT NOT NULL,
    stake TEXT, ward TEXT, gender TEXT,
    room_number TEXT, table_number TEXT,
    tshirt_size TEXT, medical_info TEXT, note TEXT, status TEXT,
    registration_source TEXT, signed_by TEXT,
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

const String printJobsDDL = '''
  CREATE TABLE IF NOT EXISTS print_jobs (
    job_id TEXT PRIMARY KEY,
    participant_id TEXT NOT NULL,
    participant_name TEXT NOT NULL,
    participant_json TEXT,
    device_id TEXT,
    printer_address TEXT,
    status TEXT NOT NULL,
    failure_code TEXT,
    failure_reason TEXT,
    queued_at INTEGER NOT NULL,
    last_attempt_at INTEGER,
    next_retry_at INTEGER,
    attempt_count INTEGER DEFAULT 0,
    is_reprint INTEGER DEFAULT 0,
    printed_at INTEGER,
    completed_at INTEGER,
    updated_at INTEGER NOT NULL
  )
''';

const String printJobAttemptsDDL = '''
  CREATE TABLE IF NOT EXISTS print_job_attempts (
    attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT NOT NULL,
    participant_id TEXT NOT NULL,
    participant_name TEXT NOT NULL,
    device_id TEXT,
    printer_address TEXT,
    attempt_number INTEGER NOT NULL,
    outcome TEXT NOT NULL,
    failure_code TEXT,
    failure_reason TEXT,
    is_reprint INTEGER DEFAULT 0,
    started_at INTEGER NOT NULL,
    finished_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
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

const String analyticsSavedViewsDDL = '''
  CREATE TABLE IF NOT EXISTS analytics_saved_views (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    committee_view TEXT NOT NULL,
    is_default INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
''';
