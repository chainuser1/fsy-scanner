import * as SQLite from 'expo-sqlite';
import { ColMapError } from './sheetsApi';

const REQUIRED_HEADERS = ['ID', 'Name', 'Table Number', 'Hotel Room Number', 'Registered', 'Verified At', 'Printed At', 'Registered By'];
const OPTIONAL_HEADERS = ['Stake', 'Ward', 'Gender', 'Medical/Food Info', 'Note', 'T-Shirt Size', 'Status', 'QR Code'];

type DB = any;

function openDb(): DB {
  const sqlite: any = SQLite as any;
  return sqlite.openDatabase ? sqlite.openDatabase('fsy_scanner.db') : sqlite.openDatabaseSync('fsy_scanner.db');
}

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

export function detectColMap(rows: unknown[][]): Record<string, number> {
  if (!rows || rows.length === 0 || !Array.isArray(rows[0])) {
    throw new ColMapError('Sheet appears to be empty or missing a header row');
  }

  const headerRow = rows[0].map((cell) => String(cell ?? '').trim());
  const colMap: Record<string, number> = {};

  headerRow.forEach((header, index) => {
    if (header) {
      colMap[header] = index;
    }
  });

  const missingRequired = REQUIRED_HEADERS.filter((header) => !(header in colMap));
  if (missingRequired.length > 0) {
    throw new ColMapError(`Missing required headers: ${missingRequired.join(', ')}`);
  }

  return colMap;
}

export async function saveColMap(colMap: Record<string, number>): Promise<void> {
  const db = openDb();
  await execSql(db, 'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', ['col_map', JSON.stringify(colMap)]);
}

import { getValidToken } from '../auth/google';
import { getSetting, setSetting } from '../db/appSettings';
import { fetchAllRows } from './sheetsApi';
import { upsertParticipant } from '../db/participants';

export async function puller(): Promise<void> {
  const sheetId = await getSetting('sheets_id');
  const tabName = await getSetting('sheets_tab');
  const colMapJson = await getSetting('col_map');

  if (!sheetId || !tabName) {
    throw new Error('Sheet ID and tab name are required for puller');
  }

  const accessToken = await getValidToken();
  if (!accessToken) {
    throw new Error('Unable to acquire Google Sheets access token');
  }

  const rows = await fetchAllRows(accessToken, sheetId, tabName);

  let colMap: Record<string, number> | null = null;
  if (colMapJson) {
    try {
      colMap = JSON.parse(colMapJson);
    } catch (err) {
      console.warn('[puller] Stored col_map is invalid JSON, attempting auto-detect');
    }
  }

  if (!colMap) {
    colMap = detectColMap(rows);
    await saveColMap(colMap);
  }

  function getCell(row: unknown[], header: string): string {
    const index = colMap![header];
    if (typeof index !== 'number') return '';
    return String(row[index] ?? '').trim();
  }

  if (rows.length <= 1) {
    await setSetting('last_pulled_at', `${Date.now()}`);
    return;
  }

  for (let i = 1; i < rows.length; i++) {
    const row = rows[i];
    const rowNumber = i + 1;
    const id = String(row[colMap['ID']] ?? '').trim();
    if (!id) {
      continue;
    }

    const participant = {
      id,
      full_name: getCell(row, 'Name'),
      stake: getCell(row, 'Stake') || null,
      ward: getCell(row, 'Ward') || null,
      gender: getCell(row, 'Gender') || null,
      room_number: getCell(row, 'Hotel Room Number') || null,
      table_number: getCell(row, 'Table Number') || null,
      tshirt_size: getCell(row, 'T-Shirt Size') || null,
      status: getCell(row, 'Status') || null,
      medical_info: getCell(row, 'Medical/Food Info') || null,
      note: getCell(row, 'Note') || null,
      registered: getCell(row, 'Registered').toUpperCase() === 'Y' ? 1 : 0,
      verified_at: getCell(row, 'Verified At') ? Date.parse(getCell(row, 'Verified At')) : null,
      printed_at: getCell(row, 'Printed At') ? Date.parse(getCell(row, 'Printed At')) : null,
      verified_by: getCell(row, 'Registered By') || null,
      sheets_row: rowNumber,
      raw_json: JSON.stringify(row),
      updated_at: Date.now(),
    };

    await upsertParticipant(participant);
  }

  await setSetting('last_pulled_at', `${Date.now()}`);
}
