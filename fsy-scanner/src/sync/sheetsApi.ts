export class AuthExpiredError extends Error {
  constructor(message = 'Authentication expired') {
    super(message);
    this.name = 'AuthExpiredError';
  }
}

export class RateLimitError extends Error {
  constructor(message = 'Google Sheets rate limit exceeded') {
    super(message);
    this.name = 'RateLimitError';
  }
}

export class SheetsServerError extends Error {
  constructor(status: number, message: string) {
    super(`Google Sheets server error ${status}: ${message}`);
    this.name = 'SheetsServerError';
  }
}

export class NetworkError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NetworkError';
  }
}

export class ColMapError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ColMapError';
  }
}

const SHEETS_BASE_URL = 'https://sheets.googleapis.com/v4/spreadsheets';

function toSheetRange(tabName: string, startColumn: number, endColumn: number, row: number): string {
  const startColumnLetter = columnIndexToLetter(startColumn);
  const endColumnLetter = columnIndexToLetter(endColumn);
  return `${tabName}!${startColumnLetter}${row}:${endColumnLetter}${row}`;
}

function columnIndexToLetter(index: number): string {
  let result = '';
  let current = index + 1;

  while (current > 0) {
    const remainder = (current - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    current = Math.floor((current - 1) / 26);
  }

  return result;
}

async function handleResponse(response: Response): Promise<any> {
  const text = await response.text();

  if (response.status === 401) {
    throw new AuthExpiredError(text || 'Unauthorized');
  }

  if (response.status === 429) {
    throw new RateLimitError(text || 'Too many requests');
  }

  if (response.status >= 500) {
    throw new SheetsServerError(response.status, text || response.statusText);
  }

  if (!response.ok) {
    throw new Error(`Google Sheets API request failed (${response.status}): ${text}`);
  }

  return text ? JSON.parse(text) : {};
}

export async function fetchAllRows(accessToken: string, sheetId: string, tabName: string): Promise<string[][]> {
  const encodedTabName = encodeURIComponent(tabName);
  const url = `${SHEETS_BASE_URL}/${encodeURIComponent(sheetId)}/values/${encodedTabName}!A1:Z1000`;

  let response: Response;
  try {
    response = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    });
  } catch (error: any) {
    throw new NetworkError(error?.message ?? 'Network request failed');
  }

  const data = await handleResponse(response);
  const values = Array.isArray(data.values) ? data.values : [];
  return values.map((row: unknown[]) => row.map((cell) => (cell == null ? '' : String(cell))));
}

export async function updateRegistrationRow(
  accessToken: string,
  sheetId: string,
  tabName: string,
  sheetsRow: number,
  colMap: Record<string, number>,
  values: { registeredAt: string; registeredBy: string }
): Promise<void> {
  const requiredColumns = ['Registered', 'Registered At', 'Registered By'];
  const missingColumns = requiredColumns.filter((column) => !(column in colMap));

  if (missingColumns.length > 0) {
    throw new ColMapError(`Missing required columns in col_map: ${missingColumns.join(', ')}`);
  }

  const registeredCol = colMap['Registered'];
  const registeredAtCol = colMap['Registered At'];
  const registeredByCol = colMap['Registered By'];

  const minCol = Math.min(registeredCol, registeredAtCol, registeredByCol);
  const maxCol = Math.max(registeredCol, registeredAtCol, registeredByCol);

  const rowValues = new Array(maxCol - minCol + 1).fill('');
  rowValues[registeredCol - minCol] = 'Y';
  rowValues[registeredAtCol - minCol] = values.registeredAt;
  rowValues[registeredByCol - minCol] = values.registeredBy;

  const range = toSheetRange(tabName, minCol, maxCol, sheetsRow);
  const url = `${SHEETS_BASE_URL}/${encodeURIComponent(sheetId)}/values/${encodeURIComponent(range)}?valueInputOption=RAW`;

  let response: Response;
  try {
    response = await fetch(url, {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        range,
        majorDimension: 'ROWS',
        values: [rowValues],
      }),
    });
  } catch (error: any) {
    throw new NetworkError(error?.message ?? 'Network request failed');
  }

  await handleResponse(response);
}
