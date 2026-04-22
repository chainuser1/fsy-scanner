import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { StyleSheet, Text, View } from 'react-native';
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

  return (
    <View style={styles.container}>
      <Text>Open up App.tsx to start working on app!</Text>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
