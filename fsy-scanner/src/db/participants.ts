import * as SQLite from 'expo-sqlite';

type Participant = {
  id: string;
  full_name: string;
  stake?: string | null;
  ward?: string | null;
  gender?: string | null;
  room_number?: string | null;
  table_number?: string | null;
  tshirt_size?: string | null;
  status?: string | null;
  medical_info?: string | null;
  note?: string | null;
  registered: number;
  verified_at?: number | null;
  printed_at?: number | null;
  verified_by?: string | null;
  sheets_row: number;
  raw_json?: string | null;
  updated_at?: number | null;
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

function normalizeRegistered(v: any): number {
  if (v === 1 || v === '1' || v === true || v === 'Y' || v === 'y') return 1;
  return 0;
}

export async function upsertParticipant(data: Partial<Participant> & { id: string }): Promise<void> {
  const now = Date.now();
  const res = await execSql('SELECT * FROM participants WHERE id = ? LIMIT 1', [data.id]);
  const exists = res.rows && res.rows.length > 0;

  if (exists) {
    const row = res.rows.item(0) as Participant;
    const existingRegistered = row.registered || 0;
    const incomingRegistered = normalizeRegistered((data as any).registered);
    const registered = existingRegistered === 1 ? 1 : incomingRegistered;
    const verifiedAt = data.verified_at ?? row.verified_at ?? (registered ? now : null);
    const verifiedBy = data.verified_by ?? row.verified_by ?? null;
    const printedAt = data.printed_at ?? row.printed_at ?? null;

    await execSql(
      `UPDATE participants SET full_name = ?, stake = ?, ward = ?, gender = ?, room_number = ?, table_number = ?, tshirt_size = ?, status = ?, medical_info = ?, note = ?, registered = ?, verified_at = ?, printed_at = ?, verified_by = ?, sheets_row = ?, raw_json = ?, updated_at = ? WHERE id = ?`,
      [
        data.full_name ?? row.full_name,
        data.stake ?? row.stake,
        data.ward ?? row.ward,
        data.gender ?? row.gender,
        data.room_number ?? row.room_number,
        data.table_number ?? row.table_number,
        data.tshirt_size ?? row.tshirt_size,
        data.status ?? row.status,
        data.medical_info ?? row.medical_info,
        data.note ?? row.note,
        registered,
        verifiedAt,
        printedAt,
        verifiedBy,
        data.sheets_row ?? row.sheets_row,
        data.raw_json ?? row.raw_json,
        now,
        data.id,
      ]
    );
  } else {
    const registered = normalizeRegistered((data as any).registered);
    const sheets_row = data.sheets_row ?? 0;

    await execSql(
      `INSERT INTO participants (id, full_name, stake, ward, gender, room_number, table_number, tshirt_size, status, medical_info, note, registered, verified_at, printed_at, verified_by, sheets_row, raw_json, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [
        data.id,
        data.full_name ?? '',
        data.stake ?? null,
        data.ward ?? null,
        data.gender ?? null,
        data.room_number ?? null,
        data.table_number ?? null,
        data.tshirt_size ?? null,
        data.status ?? null,
        data.medical_info ?? null,
        data.note ?? null,
        registered,
        data.verified_at ?? null,
        data.printed_at ?? null,
        data.verified_by ?? null,
        sheets_row,
        data.raw_json ?? JSON.stringify(data),
        now,
      ]
    );
  }
}

export async function getParticipantById(id: string): Promise<Participant | null> {
  const res = await execSql('SELECT * FROM participants WHERE id = ? LIMIT 1', [id]);
  if (res.rows && res.rows.length > 0) return res.rows.item(0) as Participant;
  return null;
}

export async function markRegisteredLocally(id: string, deviceId: string): Promise<void> {
  const now = Date.now();
  await execSql(`UPDATE participants SET registered = 1, verified_at = ?, verified_by = ?, updated_at = ? WHERE id = ?`, [now, deviceId, now, id]);
}

export async function markPrintedLocally(id: string): Promise<void> {
  const now = Date.now();
  await execSql(`UPDATE participants SET printed_at = ?, updated_at = ? WHERE id = ?`, [now, now, id]);
}

export async function getAllParticipants(): Promise<Participant[]> {
  const res = await execSql('SELECT * FROM participants ORDER BY full_name ASC', []);
  const out: Participant[] = [];
  if (res.rows && res.rows.length > 0) {
    for (let i = 0; i < res.rows.length; i++) out.push(res.rows.item(i));
  }
  return out;
}

export async function searchParticipants(query: string): Promise<Participant[]> {
  const q = `%${query.toLowerCase()}%`;
  const res = await execSql('SELECT * FROM participants WHERE LOWER(full_name) LIKE ? ORDER BY full_name ASC LIMIT 50', [q]);
  const out: Participant[] = [];
  if (res.rows && res.rows.length > 0) {
    for (let i = 0; i < res.rows.length; i++) out.push(res.rows.item(i));
  }
  return out;
}

export async function getRegisteredCount(): Promise<number> {
  const res = await execSql('SELECT COUNT(*) as c FROM participants WHERE registered = 1', []);
  if (res.rows && res.rows.length > 0) return res.rows.item(0).c as number;
  return 0;
}
