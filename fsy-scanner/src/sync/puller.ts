import * as SQLite from 'expo-sqlite';
import { ColMapError } from './sheetsApi';

const REQUIRED_HEADERS = ['ID', 'Name', 'Table Number', 'Hotel Room Number'];
const REQUIRED_WRITE_HEADERS = ['Registered', 'Registered At', 'Registered By'];

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

  const missingWriteHeaders = REQUIRED_WRITE_HEADERS.filter((header) => !(header in colMap));
  if (missingWriteHeaders.length > 0) {
    throw new ColMapError(`Missing required sheet columns before sync: ${missingWriteHeaders.join(', ')}`);
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

  if (!colMapJson) {
    throw new Error('Column map is missing. Please save sheet configuration first.');
  }

  let colMap: Record<string, number>;
  try {
    colMap = JSON.parse(colMapJson);
  } catch (err) {
    throw new Error('Stored col_map is invalid JSON');
  }

  const accessToken = await getValidToken();
  if (!accessToken) {
    throw new Error('Unable to acquire Google Sheets access token');
  }

  const rows = await fetchAllRows(accessToken, sheetId, tabName);
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
      full_name: String(row[colMap['Name']] ?? '').trim(),
      room_number: String(row[colMap['Hotel Room Number']] ?? '').trim() || null,
      table_number: String(row[colMap['Table Number']] ?? '').trim() || null,
      registered: String(row[colMap['Registered']] ?? '').toUpperCase() === 'Y' ? 1 : 0,
      registered_at: String(row[colMap['Registered At']] ?? '').trim() ? Date.parse(String(row[colMap['Registered At']] ?? '')) : null,
      registered_by: String(row[colMap['Registered By']] ?? '').trim() || null,
      sheets_row: rowNumber,
      raw_json: JSON.stringify(row),
      updated_at: Date.now(),
    };

    await upsertParticipant(participant);
  }

  await setSetting('last_pulled_at', `${Date.now()}`);
}
