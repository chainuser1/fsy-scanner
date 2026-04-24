import create from 'zustand';

export interface AppState {
  pendingTaskCount: number;
  failedTaskCount: number;
  lastSyncedAt: number | null;
  syncError: string | null;
  isInitialLoading: boolean;
  isOffline: boolean;
  darkMode: boolean;
  setPendingTaskCount: (n: number) => void;
  incrementFailedTaskCount: () => void;
  setLastSyncedAt: (ts: number) => void;
  setSyncError: (error: string | null) => void;
  setInitialLoading: (loading: boolean) => void;
  setIsOffline: (offline: boolean) => void;
  setDarkMode: (dark: boolean) => void;
}

export const useAppStore = create<AppState>((set: any) => ({
  pendingTaskCount: 0,
  failedTaskCount: 0,
  lastSyncedAt: null,
  syncError: null,
  isInitialLoading: false,
  isOffline: false,
  darkMode: false,
  setPendingTaskCount: (n: number) => set({ pendingTaskCount: n }),
  incrementFailedTaskCount: () => set((state: AppState) => ({ failedTaskCount: state.failedTaskCount + 1 })),
  setLastSyncedAt: (ts: number) => set({ lastSyncedAt: ts }),
  setSyncError: (error: string | null) => set({ syncError: error }),
  setInitialLoading: (loading: boolean) => set({ isInitialLoading: loading }),
  setIsOffline: (offline: boolean) => set({ isOffline: offline }),
  setDarkMode: (dark: boolean) => set({ darkMode: dark }),
})) as any;