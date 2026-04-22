import { Slot } from 'expo-router';
import { useEffect } from 'react';
import { runMigrations } from './src/db/migrations';
import { startSyncEngine } from './src/sync/engine';

export default function App() {
  useEffect(() => {
    runMigrations()
      .then(() => startSyncEngine())
      .catch((error) => {
        console.error('Failed to run startup tasks:', error);
      });
  }, []);

  return <Slot />;
}
