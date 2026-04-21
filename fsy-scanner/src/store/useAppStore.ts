import create from 'zustand';

interface AppState {
  pendingCount: number;
  setPendingCount: (n: number) => void;
}

export const useAppStore = create<AppState>((set) => ({
  pendingCount: 0,
  setPendingCount: (n: number) => set({ pendingCount: n }),
}));
