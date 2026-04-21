export const PARTICIPANTS_DDL = `
CREATE TABLE IF NOT EXISTS participants (
  id TEXT PRIMARY KEY,
  full_name TEXT,
  table_number TEXT,
  room_number TEXT,
  registered INTEGER DEFAULT 0,
  registered_at INTEGER,
  registered_by TEXT,
  updated_at INTEGER
);
`;

export const SYNC_TASKS_DDL = `
CREATE TABLE IF NOT EXISTS sync_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT,
  payload TEXT,
  status TEXT DEFAULT 'pending',
  attempts INTEGER DEFAULT 0,
  error TEXT,
  created_at INTEGER,
  updated_at INTEGER,
  completed_at INTEGER
);
`;

export const APP_SETTINGS_DDL = `
CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT
);
`;
