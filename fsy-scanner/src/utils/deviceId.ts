import * as SecureStore from 'expo-secure-store';

const DEVICE_ID_KEY = 'fsy_device_id';

function uuidv4(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

// Generate or return a stable device id and persist it in SecureStore
export async function generateDeviceId(): Promise<string> {
  try {
    const existing = await SecureStore.getItemAsync(DEVICE_ID_KEY);
    if (existing) return existing;
  } catch (err) {
    // ignore read errors and generate a new id
  }

  const id = uuidv4();
  try {
    await SecureStore.setItemAsync(DEVICE_ID_KEY, id);
  } catch (err) {
    console.warn('Failed to persist device id to SecureStore', err);
  }
  return id;
}
