import { useAppStore } from '../store/useAppStore';

export function useSyncStatus() {
  const store = useAppStore as any;
  const pendingCount = store((state: any) => state.pendingTaskCount);
  const failedTaskCount = store((state: any) => state.failedTaskCount);
  const lastSync = store((state: any) => state.lastSyncedAt);
  const syncError = store((state: any) => state.syncError);
  const isInitialLoading = store((state: any) => state.isInitialLoading);
  const isOffline = store((state: any) => state.isOffline);

  return {
    pendingCount,
    failedTaskCount,
    lastSync,
    syncError,
    isInitialLoading,
    isOffline,
  };
}