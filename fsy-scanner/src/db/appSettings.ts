import * as SQLite from 'expo-sqlite';

type DB = any;

const openDb: any = (SQLite as any).openDatabase ?? (SQLite as any).openDatabaseSync;
const db: DB = openDb('fsy_scanner.db');

function execSql(sql: string, params: any[] = []) {
  return new Promise<any>((resolve, reject) => {
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

export async function getSetting(key: string): Promise<string | null> {
  const res = await execSql('SELECT value FROM app_settings WHERE key = ? LIMIT 1', [key]);
  if (res.rows && res.rows.length > 0) {
    return res.rows.item(0).value as string;
  }
  return null;
}

export async function setSetting(key: string, value: string): Promise<void> {
  await execSql('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', [key, value]);
}

export async function getSettings(keys: string[]): Promise<Record<string, string | null>> {
  const result: Record<string, string | null> = {};
  for (const key of keys) {
    result[key] = await getSetting(key);
  }
  return result;
}
