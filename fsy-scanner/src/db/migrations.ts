import * as SQLite from 'expo-sqlite';
import { APP_SETTINGS_DDL, PARTICIPANTS_DDL, SYNC_TASKS_DDL } from './schema';
import { generateDeviceId } from '../utils/deviceId';

type DB = any;

function execSql(db: DB, sql: string, params: any[] = []): Promise<any> {
  return new Promise((resolve, reject) => {
    db.transaction(
      (tx: any) => {
        tx.executeSql(
          sql,
          params,
          (_: any, result: any) => resolve(result),
          (_: any, error: any) => {
            reject(error);
            return false;
          }
        );
      },
      (txErr: any) => reject(txErr)
    );
  });
}

export async function runMigrations(dbParam?: DB): Promise<void> {
  const openDb: any = (SQLite as any).openDatabase ?? (SQLite as any).openDatabaseSync;
  const db = dbParam ?? openDb('fsy_scanner.db');

  try {
    // Ensure app_settings table exists first (migration requirement)
    await execSql(db, APP_SETTINGS_DDL);

    // Read current db_version from app_settings (default 0)
    let currentVersion = 0;
    try {
      const res = await execSql(db, 'SELECT value FROM app_settings WHERE key = ? LIMIT 1', ['db_version']);
      if (res && res.rows && res.rows.length > 0) {
        const v = res.rows.item(0).value;
        currentVersion = parseInt(v, 10) || 0;
      }
    } catch (err) {
      currentVersion = 0;
    }

    // Migration v1: create participants and sync_tasks tables, set db_version, ensure device_id
    if (currentVersion < 1) {
      await execSql(db, PARTICIPANTS_DDL);
      await execSql(db, SYNC_TASKS_DDL);

      await execSql(db, 'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', ['db_version', '1']);

      try {
        const devRes = await execSql(db, 'SELECT value FROM app_settings WHERE key = ? LIMIT 1', ['device_id']);
        if (!devRes || !devRes.rows || devRes.rows.length === 0) {
          const newId = await generateDeviceId();
          await execSql(db, 'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', ['device_id', newId]);
        }
      } catch (err) {
        const newId = await generateDeviceId();
        await execSql(db, 'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', ['device_id', newId]);
      }
    }
  } catch (err) {
    console.error('runMigrations error', err);
    throw err;
  }
}
