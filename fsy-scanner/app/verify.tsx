import React, { useState } from 'react';
import { StyleSheet, Text, View, Button, ScrollView, ActivityIndicator } from 'react-native';
import { runVerificationChecks } from '../src/verify/runtimeVerification';

export default function Verify() {
  const [running, setRunning] = useState(false);
  const [results, setResults] = useState<Array<{ name: string; success: boolean; details?: string }> | null>(null);

  async function handleRunVerification() {
    setRunning(true);
    setResults(null);

    try {
      const checks = await runVerificationChecks();
      setResults(checks);
    } catch (error: any) {
      setResults([{ name: 'Verification runner', success: false, details: error?.message ?? String(error) }]);
    } finally {
      setRunning(false);
    }
  }

  return (
    <ScrollView contentContainerStyle={styles.container} keyboardShouldPersistTaps="handled">
      <Text style={styles.title}>Runtime Verification</Text>
      <Text style={styles.description}>
        This screen runs a set of runtime checks for database migrations, app settings, queue logic, and receipt generation.
      </Text>

      <View style={styles.buttonContainer}>
        <Button title={running ? 'Running verification…' : 'Run Verification'} onPress={handleRunVerification} disabled={running} />
      </View>

      {running && <ActivityIndicator style={styles.spinner} size="large" />}

      {results ? (
        <View style={styles.results}>
          {results.map((result) => (
            <View key={result.name} style={styles.resultRow}>
              <Text style={styles.resultName}>{result.name}</Text>
              <Text style={[styles.resultStatus, result.success ? styles.success : styles.failure]}>
                {result.success ? 'PASS' : 'FAIL'}
              </Text>
              {result.details ? <Text style={styles.resultDetails}>{result.details}</Text> : null}
            </View>
          ))}
        </View>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 20,
    backgroundColor: '#fff',
    minHeight: '100%',
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    marginBottom: 12,
  },
  description: {
    fontSize: 16,
    color: '#555',
    marginBottom: 24,
  },
  buttonContainer: {
    marginBottom: 24,
  },
  spinner: {
    marginTop: 20,
  },
  results: {
    marginTop: 16,
  },
  resultRow: {
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#eee',
  },
  resultName: {
    fontSize: 16,
    fontWeight: '700',
  },
  resultStatus: {
    marginTop: 4,
    fontSize: 14,
  },
  success: {
    color: 'green',
  },
  failure: {
    color: 'red',
  },
  resultDetails: {
    marginTop: 6,
    fontSize: 13,
    color: '#555',
  },
});
