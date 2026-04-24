import React, { useEffect } from 'react';
import { Stack } from 'expo-router';
import { Appearance } from 'react-native';
import { runMigrations } from '../src/db/migrations';
import { startSyncEngine } from '../src/sync/engine';
import { useAppStore } from '../src/store/useAppStore';

export default function Layout() {
  useEffect(() => {
    // Set initial dark mode based on system preference
    const initialColorScheme = Appearance.getColorScheme();
    if (initialColorScheme === 'dark') {
      useAppStore.setState({ darkMode: true });
    }

    // Listen to system theme changes
    const subscription = Appearance.addChangeListener(({ colorScheme }) => {
      useAppStore.setState({ darkMode: colorScheme === 'dark' });
    });

    return () => subscription.remove();
  }, []);

  useEffect(() => {
    runMigrations()
      .then(() => startSyncEngine())
      .catch((error) => {
        console.error('Failed to run startup tasks:', error);
      });
  }, []);

  return <Stack />;
}