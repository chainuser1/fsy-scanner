import React, { useEffect } from 'react';
import { Stack } from 'expo-router';
import { runMigrations } from '../src/db/migrations';
import { startSyncEngine } from '../src/sync/engine';

export default function Layout() {
  useEffect(() => {
    runMigrations()
      .then(() => startSyncEngine())
      .catch((error) => {
        console.error('Failed to run startup tasks:', error);
      });
  }, []);

  return <Stack />;
}
