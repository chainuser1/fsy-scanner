import * as SQLite from 'expo-sqlite';

type SyncTask = {
  id: number;
  type: 'mark_registered' | 'mark_printed' | 'pull_delta';
  payload: string; // JSON
  status: string;
  attempts: number;
  last_error?: string | null;
  created_at?: number;
  completed_at?: number | null;
};

const openDb: any = (SQLite as any).openDatabase ?? (SQLite as any).openDatabaseSync;
const db = openDb('fsy_scanner.db');

function execSql(sql: string, params: any[] = []) {
  return new Promise<any>((resolve, reject) => {
    db.transaction(
      (tx: any) => {
        tx.executeSql(
          sql,
          params,
          (_: any, result: any) => resolve(result),
          (_: any, err: any) => {
            reject(err);
            return false;
          }
        );
      },
      (txErr: any) => reject(txErr)
    );
  });
}

export async function enqueueTask(type: 'mark_registered' | 'mark_printed' | 'pull_delta', payload: object): Promise<number> {
  const now = Date.now();
  const res = await execSql('INSERT INTO sync_tasks (type, payload, status, attempts, created_at) VALUES (?,?,?,?,?)', [type, JSON.stringify(payload), 'pending', 0, now]);
  // insertId should be returned by executeSql result
  return res.insertId ?? -1;
}

export async function claimNextTask(): Promise<SyncTask | null> {
  return new Promise<SyncTask | null>((resolve, reject) => {
    db.transaction(
      (tx: any) => {
        tx.executeSql(
          `SELECT id, type, payload, attempts, status, created_at, last_error FROM sync_tasks WHERE status = ? ORDER BY created_at ASC LIMIT 1`,
          ['pending'],
          (_: any, selectRes: any) => {
            if (selectRes.rows && selectRes.rows.length > 0) {
              const row = selectRes.rows.item(0);
              const id = row.id;
              const now = Date.now();
              tx.executeSql(
                `UPDATE sync_tasks SET status = ?, updated_at = ? WHERE id = ?`,
                ['in_progress', now, id],
                (_: any, updRes: any) => {
                  resolve({ id: row.id, type: row.type, payload: row.payload, status: 'in_progress', attempts: row.attempts, last_error: row.last_error, created_at: row.created_at });
                },
                (_: any, err: any) => {
                  reject(err);
                  return false;
                }
              );
            } else {
              resolve(null);
            }
          },
          (_: any, err: any) => {
            reject(err);
            return false;
          }
        );
      },
      (txErr: any) => reject(txErr)
    );
  });
}

export async function completeTask(id: number): Promise<void> {
  await execSql('DELETE FROM sync_tasks WHERE id = ?', [id]);
}

export async function failTask(id: number, error: string): Promise<void> {
  const now = Date.now();
  await execSql('UPDATE sync_tasks SET status = ?, attempts = attempts + 1, last_error = ?, updated_at = ? WHERE id = ?', ['pending', error, now, id]);
}

export async function resetInProgressTasks(): Promise<void> {
  await execSql("UPDATE sync_tasks SET status = 'pending' WHERE status = 'in_progress'", []);
}

export async function getPendingCount(): Promise<number> {
  const res = await execSql("SELECT COUNT(*) as c FROM sync_tasks WHERE status = 'pending' OR status = 'in_progress'", []);
  if (res.rows && res.rows.length > 0) return res.rows.item(0).c as number;
  return 0;
}
