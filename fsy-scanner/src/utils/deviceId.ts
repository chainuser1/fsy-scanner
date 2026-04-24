import * as SQLite from 'expo-sqlite';

const DEVICE_ID_KEY = 'device_id';

function uuidv4(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

// Generate or return a stable device id and persist it in SQLite app_settings
export async function generateDeviceId(): Promise<string> {
  const db = SQLite.openDatabaseSync('fsy_scanner.db');
  
  try {
    // Try to get existing device ID from app_settings
    const existingResult = await db.getFirstAsync<{ value: string }>(
      'SELECT value FROM app_settings WHERE key = ?', 
      [DEVICE_ID_KEY]
    );
    
    if (existingResult && existingResult.value) {
      return existingResult.value;
    }
  } catch (err) {
    // ignore read errors and generate a new id
  }

  const id = uuidv4();
  try {
    // Insert or update the device ID in app_settings
    await db.runAsync(
      'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', 
      [DEVICE_ID_KEY, id]
    );
  } catch (err) {
    console.warn('Failed to persist device id to SQLite', err);
  }
  return id;
}