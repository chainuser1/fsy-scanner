import create from 'zustand';

interface AppState {
  pendingTaskCount: number;
  failedTaskCount: number;
  lastSyncedAt: number | null;
  syncError: string | null;
  isInitialLoading: boolean;
  setPendingTaskCount: (n: number) => void;
  incrementFailedTaskCount: () => void;
  setLastSyncedAt: (ts: number) => void;
  setSyncError: (error: string | null) => void;
  setInitialLoading: (loading: boolean) => void;
}

export const useAppStore = create<AppState>((set: any) => ({
  pendingTaskCount: 0,
  failedTaskCount: 0,
  lastSyncedAt: null,
  syncError: null,
  isInitialLoading: false,
  setPendingTaskCount: (n: number) => set({ pendingTaskCount: n }),
  incrementFailedTaskCount: () => set((state: AppState) => ({ failedTaskCount: state.failedTaskCount + 1 })),
  setLastSyncedAt: (ts: number) => set({ lastSyncedAt: ts }),
  setSyncError: (error: string | null) => set({ syncError: error }),
  setInitialLoading: (loading: boolean) => set({ isInitialLoading: loading }),
}));
