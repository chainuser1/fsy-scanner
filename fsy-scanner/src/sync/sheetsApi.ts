// Thin wrapper for Google Sheets API (placeholder)
export async function fetchAllRows(accessToken: string, sheetId: string, tabName: string): Promise<string[][]> {
  throw new Error('Not implemented');
}

export async function updateRegistrationRow(accessToken: string, sheetId: string, tabName: string, range: string, values: { registeredAt: string, registeredBy: string }): Promise<void> {
  throw new Error('Not implemented');
}
