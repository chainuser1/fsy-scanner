import { useAppStore } from '../store/useAppStore';

export function useSyncStatus() {
  const store = useAppStore as any;
  const pendingCount = store((state: any) => state.pendingTaskCount);
  const failedTaskCount = store((state: any) => state.failedTaskCount);
  const lastSync = store((state: any) => state.lastSyncedAt);
  const syncError = store((state: any) => state.syncError);

  return {
    pendingCount,
    failedTaskCount,
    lastSync,
    syncError,
  };
}
