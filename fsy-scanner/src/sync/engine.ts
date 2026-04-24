import * as Network from 'expo-network';
import { puller } from './puller';
import { pusher } from './pusher';
import { resetInProgressTasks, getPendingCount } from '../db/syncQueue';
import { getSetting, setSetting } from '../db/appSettings';
import { useAppStore } from '../store/useAppStore';
import { AuthExpiredError, RateLimitError } from './sheetsApi';
import { getSheetsId, getSheetsTab, getEventName } from '../auth/google';

let intervalId: number | null = null;
let currentIntervalMs = 15000;
const MAX_INTERVAL_MS = 120000;

function getSyncIntervalMs(): number {
  return Math.min(currentIntervalMs, MAX_INTERVAL_MS);
}

function clearSyncInterval() {
  if (intervalId !== null) {
    clearInterval(intervalId);
    intervalId = null;
  }
}

function scheduleSyncInterval() {
  clearSyncInterval();
  intervalId = setInterval(() => {
    runSyncTick().catch((error) => {
      console.error('Sync tick error:', error);
    });
  }, getSyncIntervalMs()) as unknown as number;
}

async function updatePendingCount() {
  try {
    const pendingCount = await getPendingCount();
    (useAppStore as any).getState().setPendingTaskCount(pendingCount);
  } catch (err) {
    console.error('Failed to update pending count', err);
  }
}

async function runSyncTick(): Promise<void> {
  const networkState = await Network.getNetworkStateAsync();
  if (!networkState.isConnected || networkState.isInternetReachable === false) {
    (useAppStore as any).getState().setSyncError('Offline - sync paused');
    (useAppStore as any).getState().setIsOffline(true);
    await updatePendingCount();
    return;
  }

  (useAppStore as any).getState().setSyncError(null);
  (useAppStore as any).getState().setIsOffline(false);

  try {
    const sheetId = await getSetting('sheets_id');
    const tabName = await getSetting('sheets_tab');
    if (!sheetId || !tabName) {
      (useAppStore as any).getState().setSyncError('Sheet configuration incomplete');
      return;
    }

    await puller();
    await pusher();
    (useAppStore as any).getState().setLastSyncedAt(Date.now());
    (useAppStore as any).getState().setSyncError(null);
    await updatePendingCount();
  } catch (error: any) {
    const message = error?.message ? String(error.message) : 'Unknown sync error';
    (useAppStore as any).getState().setSyncError(message);

    if (error instanceof RateLimitError) {
      currentIntervalMs = Math.min(currentIntervalMs * 2, MAX_INTERVAL_MS);
      scheduleSyncInterval();
    }

    if (error instanceof AuthExpiredError) {
      // Service account auth should refresh automatically, but surface the error.
      console.warn('Auth expired during sync:', message);
    }

    console.error('Sync loop error:', message);
  }
}

async function seedSettingsFromEnv(): Promise<void> {
  const envKeys: Array<{ key: string; value: string }> = [
    { key: 'sheets_id', value: getSheetsId() },
    { key: 'sheets_tab', value: getSheetsTab() },
    { key: 'event_name', value: getEventName() },
  ];

  for (const item of envKeys) {
    if (!item.value) {
      continue;
    }

    const existing = await getSetting(item.key);
    if (!existing) {
      await setSetting(item.key, item.value);
    }
  }
}

export async function startSyncEngine(): Promise<void> {
  await resetInProgressTasks();
  await updatePendingCount();
  await seedSettingsFromEnv();

  const lastPulledAt = await getSetting('last_pulled_at');
  const parsedLastPulledAt = lastPulledAt ? parseInt(lastPulledAt, 10) : NaN;
  const isFirstRun = !lastPulledAt || Number.isNaN(parsedLastPulledAt) || parsedLastPulledAt === 0;
  (useAppStore as any).getState().setInitialLoading(isFirstRun);

  try {
    await runSyncTick();
  } finally {
    (useAppStore as any).getState().setInitialLoading(false);
  }

  const intervalSetting = await getSetting('sync_interval_ms');
  if (intervalSetting) {
    const parsed = parseInt(intervalSetting, 10);
    if (!Number.isNaN(parsed) && parsed > 0) {
      currentIntervalMs = parsed;
    }
  }
  scheduleSyncInterval();
}