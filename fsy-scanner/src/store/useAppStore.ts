import create from 'zustand';

interface AppState {
  pendingTaskCount: number;
  failedTaskCount: number;
  lastSyncedAt: number | null;
  syncError: string | null;
  setPendingTaskCount: (n: number) => void;
  incrementFailedTaskCount: () => void;
  setLastSyncedAt: (ts: number) => void;
  setSyncError: (error: string | null) => void;
}

export const useAppStore = create<AppState>((set: any) => ({
  pendingTaskCount: 0,
  failedTaskCount: 0,
  lastSyncedAt: null,
  syncError: null,
  setPendingTaskCount: (n: number) => set({ pendingTaskCount: n }),
  incrementFailedTaskCount: () => set((state: AppState) => ({ failedTaskCount: state.failedTaskCount + 1 })),
  setLastSyncedAt: (ts: number) => set({ lastSyncedAt: ts }),
  setSyncError: (error: string | null) => set({ syncError: error }),
}));
