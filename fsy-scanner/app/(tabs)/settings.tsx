import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Button,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useRouter } from 'expo-router';
import { ThermalPrinter } from '@finan-me/react-native-thermal-printer';
import { getSetting, setSetting } from '../../src/db/appSettings';
import { detectColMap, saveColMap } from '../../src/sync/puller';
import { fetchAllRows } from '../../src/sync/sheetsApi';
import { getValidToken, getSheetsId, getSheetsTab, getEventName } from '../../src/auth/google';

export default function Settings() {
  const router = useRouter();
  const [sheetId, setSheetId] = useState('');
  const [tabName, setTabName] = useState('');
  const [eventName, setEventName] = useState('');
  const [printerAddress, setPrinterAddress] = useState('');
  const [scanResults, setScanResults] = useState<{ paired: Array<{ name?: string | null; address: string }>; found: Array<{ name?: string | null; address: string }> } | null>(null);
  const [scanning, setScanning] = useState(false);
  const [detectedColumns, setDetectedColumns] = useState<Record<string, number> | null>(null);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function loadSettings() {
      try {
        const values = await getSetting('sheets_id');
        if (values) {
          setSheetId(values);
        } else {
          const envSheetsId = getSheetsId();
          if (envSheetsId) setSheetId(envSheetsId);
        }

        const savedTab = await getSetting('sheets_tab');
        if (savedTab) {
          setTabName(savedTab);
        } else {
          const envTabName = getSheetsTab();
          if (envTabName) setTabName(envTabName);
        }

        const savedEvent = await getSetting('event_name');
        if (savedEvent) {
          setEventName(savedEvent);
        } else {
          const envEventName = getEventName();
          if (envEventName) setEventName(envEventName);
        }

        const savedPrinter = await getSetting('printer_address');
        if (savedPrinter) setPrinterAddress(savedPrinter);
      } catch (err) {
        setError('Failed to load settings');
      }
    }

    loadSettings();
  }, []);

  async function handleSaveAndDetect() {
    setLoading(true);
    setError(null);
    setMessage(null);
    setDetectedColumns(null);

    const trimmedSheetId = sheetId.trim();
    const trimmedTabName = tabName.trim();
    const trimmedEventName = eventName.trim();

    if (!trimmedSheetId || !trimmedTabName) {
      setError('Sheet ID and Tab Name are required.');
      setLoading(false);
      return;
    }

    try {
      await setSetting('sheets_id', trimmedSheetId);
      await setSetting('sheets_tab', trimmedTabName);
      await setSetting('event_name', trimmedEventName);

      const accessToken = await getValidToken();
      if (!accessToken) {
        throw new Error('Failed to acquire Google Sheets access token');
      }

      const rows = await fetchAllRows(accessToken, trimmedSheetId, trimmedTabName);
      const colMap = detectColMap(rows);
      await saveColMap(colMap);
      setDetectedColumns(colMap);
      setMessage('Column detection succeeded.');
    } catch (err: any) {
      const message = err?.message ? String(err.message) : 'An unknown error occurred.';
      setError(message);
    } finally {
      setLoading(false);
    }
  }

  async function handleSavePrinterAddress() {
    setLoading(true);
    setError(null);
    setMessage(null);

    const trimmedAddress = printerAddress.trim();
    if (!trimmedAddress) {
      setError('Printer address is required.');
      setLoading(false);
      return;
    }

    try {
      await setSetting('printer_address', trimmedAddress);
      setMessage('Printer address saved.');
    } catch (err: any) {
      setError(err?.message ? String(err.message) : 'Failed to save printer address.');
    } finally {
      setLoading(false);
    }
  }

  async function handleScanPrinters() {
    setScanning(true);
    setError(null);
    setMessage(null);
    setScanResults(null);

    try {
      const result = await ThermalPrinter.scanDevices();
      setScanResults(result);

      if (!result.paired.length && !result.found.length) {
        setMessage('No Bluetooth printers found.');
      }
    } catch (err: any) {
      setError(err?.message ? String(err.message) : 'Bluetooth scan failed.');
    } finally {
      setScanning(false);
    }
  }

  function handleSelectPrinter(address: string, name?: string | null) {
    setPrinterAddress(address);
    setMessage(`Selected printer ${name ?? address}`);
  }

  return (
    <ScrollView contentContainerStyle={styles.container} keyboardShouldPersistTaps="handled">
      <Text style={styles.label}>Google Sheet ID</Text>
      <TextInput
        style={styles.input}
        value={sheetId}
        onChangeText={setSheetId}
        placeholder="Enter Sheet ID"
        autoCapitalize="none"
        autoCorrect={false}
      />

      <Text style={styles.label}>Tab Name</Text>
      <TextInput
        style={styles.input}
        value={tabName}
        onChangeText={setTabName}
        placeholder="Enter Tab Name"
        autoCapitalize="none"
        autoCorrect={false}
      />

      <Text style={styles.label}>Event Name</Text>
      <TextInput
        style={styles.input}
        value={eventName}
        onChangeText={setEventName}
        placeholder="Enter Event Name"
        autoCapitalize="words"
      />

      <Text style={styles.label}>Bluetooth Printer Address</Text>
      <TextInput
        style={styles.input}
        value={printerAddress}
        onChangeText={setPrinterAddress}
        placeholder="Enter printer MAC / address"
        autoCapitalize="none"
        autoCorrect={false}
      />

      <View style={styles.buttonContainer}>
        <Button title="Save Printer Address" onPress={handleSavePrinterAddress} disabled={loading} />
      </View>

      <View style={styles.buttonContainer}>
        <Button
          title={scanning ? 'Scanning for Printers...' : 'Scan Bluetooth Printers'}
          onPress={handleScanPrinters}
          disabled={loading || scanning}
        />
      </View>

      {scanResults ? (
        <View style={styles.columnList}>
          <Text style={styles.sectionTitle}>Printer Scan Results</Text>
          {scanResults.paired.length > 0 ? (
            <View style={styles.columnList}>
              <Text style={styles.sectionSubtitle}>Paired devices</Text>
              {scanResults.paired.map((device) => (
                <View key={device.address} style={styles.scanRow}>
                  <View style={styles.scanTextContainer}>
                    <Text style={styles.columnHeader}>{device.name || 'Unnamed device'}</Text>
                    <Text style={styles.columnIndex}>{device.address}</Text>
                  </View>
                  <Button
                    title="Use"
                    onPress={() => handleSelectPrinter(device.address, device.name)}
                  />
                </View>
              ))}
            </View>
          ) : null}

          {scanResults.found.length > 0 ? (
            <View style={styles.columnList}>
              <Text style={styles.sectionSubtitle}>Found devices</Text>
              {scanResults.found.map((device) => (
                <View key={device.address} style={styles.scanRow}>
                  <View style={styles.scanTextContainer}>
                    <Text style={styles.columnHeader}>{device.name || 'Unnamed device'}</Text>
                    <Text style={styles.columnIndex}>{device.address}</Text>
                  </View>
                  <Button
                    title="Use"
                    onPress={() => handleSelectPrinter(device.address, device.name)}
                  />
                </View>
              ))}
            </View>
          ) : null}
        </View>
      ) : null}

      <View style={styles.divider} />

      <View style={styles.buttonContainer}>
        <Button title="Save & Detect Columns" onPress={handleSaveAndDetect} disabled={loading} />
      </View>

      <View style={styles.buttonContainer}>
        <Button title="Run Runtime Verification" onPress={() => router.push('/verify')} disabled={loading} />
      </View>

      {loading && <ActivityIndicator style={styles.spinner} size="large" />}

      {message ? <Text style={styles.success}>{message}</Text> : null}
      {error ? <Text style={styles.error}>{error}</Text> : null}

      {detectedColumns ? (
        <View style={styles.columnList}>
          <Text style={styles.sectionTitle}>Detected Columns</Text>
          {Object.entries(detectedColumns)
            .sort(([, a], [, b]) => a - b)
            .map(([header, index]) => (
              <View key={header} style={styles.columnRow}>
                <Text style={styles.columnHeader}>{header}</Text>
                <Text style={styles.columnIndex}>{index}</Text>
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
  },
  label: {
    fontSize: 16,
    fontWeight: '600',
    marginTop: 16,
    marginBottom: 8,
  },
  input: {
    borderWidth: 1,
    borderColor: '#ccc',
    borderRadius: 8,
    padding: 12,
    fontSize: 16,
    backgroundColor: '#fafafa',
  },
  buttonContainer: {
    marginTop: 24,
  },
  spinner: {
    marginTop: 20,
  },
  success: {
    marginTop: 20,
    color: 'green',
    fontWeight: '600',
  },
  error: {
    marginTop: 20,
    color: 'red',
    fontWeight: '600',
  },
  columnList: {
    marginTop: 24,
    paddingTop: 16,
    borderTopWidth: 1,
    borderTopColor: '#eee',
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: '700',
    marginBottom: 12,
  },
  sectionSubtitle: {
    fontSize: 14,
    fontWeight: '700',
    marginTop: 12,
    marginBottom: 8,
  },
  scanRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 8,
  },
  scanTextContainer: {
    flex: 1,
    marginRight: 12,
  },
  divider: {
    marginTop: 20,
    borderTopWidth: 1,
    borderTopColor: '#ececec',
  },
  columnRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 4,
  },
  columnHeader: {
    fontSize: 14,
    color: '#333',
  },
  columnIndex: {
    fontSize: 14,
    color: '#666',
  },
});
