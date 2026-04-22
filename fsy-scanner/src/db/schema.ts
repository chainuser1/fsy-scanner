export const PARTICIPANTS_DDL = `
CREATE TABLE IF NOT EXISTS participants (
  id              TEXT PRIMARY KEY,
  full_name       TEXT NOT NULL,
  stake           TEXT,
  ward            TEXT,
  gender          TEXT,
  room_number     TEXT,
  table_number    TEXT,
  tshirt_size     TEXT,
  status          TEXT,
  medical_info    TEXT,
  note            TEXT,
  registered      INTEGER DEFAULT 0,
  verified_at     INTEGER,
  printed_at      INTEGER,
  verified_by     TEXT,
  sheets_row      INTEGER NOT NULL,
  raw_json        TEXT,
  updated_at      INTEGER
);
`;

export const SYNC_TASKS_DDL = `
CREATE TABLE IF NOT EXISTS sync_tasks (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  type          TEXT NOT NULL,
  payload       TEXT NOT NULL,
  status        TEXT DEFAULT 'pending',
  attempts      INTEGER DEFAULT 0,
  last_error    TEXT,
  created_at    INTEGER,
  updated_at    INTEGER,
  completed_at  INTEGER
);
`;

export const APP_SETTINGS_DDL = `
CREATE TABLE IF NOT EXISTS app_settings (
  key   TEXT PRIMARY KEY,
  value TEXT
);
`;
