import React, { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View, Button, useColorScheme } from 'react-native';
import { CameraView } from 'expo-camera';
import { useRouter } from 'expo-router';
import { format } from 'date-fns';
import { useScanner } from '../../src/hooks/useScanner';
import { useSyncStatus } from '../../src/hooks/useSyncStatus';
import { getParticipantById } from '../../src/db/participants';
import { startSyncEngine } from '../../src/sync/engine';

export default function Scan() {
  const router = useRouter();
  const [toast, setToast] = useState<string | null>(null);
  const [toastType, setToastType] = useState<'success' | 'warning' | 'error'>('success');
  const [toastKey, setToastKey] = useState(0);
  const [retrying, setRetrying] = useState(false);
  const scanner = useScanner();
  const { pendingCount, syncError, isInitialLoading, isOffline } = useSyncStatus();
  const colorScheme = useColorScheme();

  useEffect(() => {
    const scannedId = scanner.scannedId;
    if (!scannedId) {
      return;
    }

    async function handleScan(id: string) {
      const participant = await getParticipantById(id);
      if (!participant) {
        setToastType('error');
        setToast('Participant not found');
        setToastKey((prev) => prev + 1);
        return;
      }

      if (participant.registered === 1) {
        const checkedIn = participant.verified_at
          ? format(new Date(participant.verified_at), 'PPpp')
          : 'unknown time';
        setToastType('warning');
        setToast(`Already checked in — ${participant.full_name} at ${checkedIn}`);
        setToastKey((prev) => prev + 1);
        return;
      }

      router.push(`/confirm/${encodeURIComponent(id)}`);
    }

    handleScan(scannedId);
  }, [router, scanner.scannedId]);

  useEffect(() => {
    if (!toast) {
      return;
    }

    const timeout = setTimeout(() => setToast(null), 3000);
    return () => clearTimeout(timeout);
  }, [toast, toastKey]);

  async function handleRetry() {
    setRetrying(true);
    try {
      await startSyncEngine();
    } catch (err) {
      console.error('Retry failed:', err);
    } finally {
      setRetrying(false);
    }
  }

  if (isInitialLoading) {
    return (
      <View style={[styles.emptyContainer, { backgroundColor: colorScheme === 'dark' ? '#121212' : '#fff' }]}>
        <Text style={[styles.loadingTitle, { color: colorScheme === 'dark' ? '#fff' : '#000' }]}>Setting up for the first time...</Text>
        <Text style={[styles.loadingSubtitle, { color: colorScheme === 'dark' ? '#ccc' : '#666' }]}>Downloading participant list and configuring Sheets access.</Text>
        <ActivityIndicator size="large" style={styles.loadingSpinner} color={colorScheme === 'dark' ? '#fff' : '#000'} />
        {syncError ? (
          <View style={styles.errorContainer}>
            <Text style={[styles.errorText, { color: colorScheme === 'dark' ? '#f88' : '#f00' }]}>{syncError}</Text>
            <Button title={retrying ? 'Retrying...' : 'Retry'} onPress={handleRetry} disabled={retrying} />
          </View>
        ) : null}
      </View>
    );
  }

  if (scanner.hasPermission === false) {
    return (
      <View style={[styles.emptyContainer, { backgroundColor: colorScheme === 'dark' ? '#121212' : '#fff' }]}>
        <Text style={[styles.message, { color: colorScheme === 'dark' ? '#fff' : '#000' }]}>Camera permission is required for scanning.</Text>
      </View>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: colorScheme === 'dark' ? '#000' : '#000' }]}>
      {isOffline && (
        <View style={styles.offlineBanner}>
          <Text style={styles.offlineText}>Offline - sync paused</Text>
        </View>
      )}
      
      <CameraView
  style={styles.camera}
  facing="back"
  barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
  onBarcodeScanned={scanner.isScanning ? scanner.onBarCodeScanned : undefined}
>
  <View style={styles.overlay}>
    <View style={styles.reticle} />
  </View>
</CameraView>

      <View style={styles.topRightBadge}>
        <Text style={styles.badgeText}>Pending: {pendingCount}</Text>
        {syncError ? <Text style={styles.badgeError}>Paused</Text> : <Text style={styles.badgeOk}>Sync OK</Text>}
      </View>

      {toast ? (
        <View style={[styles.toast, toastType === 'error' ? styles.toastError : toastType === 'warning' ? styles.toastWarning : styles.toastSuccess]}>
          <Text style={styles.toastText}>{toast}</Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  camera: {
    flex: 1,
  },
  overlay: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  reticle: {
    width: 260,
    height: 260,
    borderWidth: 3,
    borderColor: '#00FF00',
    borderRadius: 12,
  },
  emptyContainer: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  message: {
    color: '#333',
    fontSize: 16,
    textAlign: 'center',
  },
  loadingTitle: {
    fontSize: 20,
    fontWeight: '700',
    marginBottom: 12,
    textAlign: 'center',
  },
  loadingSubtitle: {
    fontSize: 16,
    marginBottom: 24,
    textAlign: 'center',
    color: '#666',
    paddingHorizontal: 24,
  },
  loadingSpinner: {
    marginBottom: 24,
  },
  errorContainer: {
    width: '80%',
    alignItems: 'center',
    gap: 12,
  },
  errorText: {
    color: '#f88',
    textAlign: 'center',
    marginBottom: 12,
  },
  topRightBadge: {
    position: 'absolute',
    top: 40,
    right: 16,
    backgroundColor: 'rgba(0,0,0,0.6)',
    padding: 10,
    borderRadius: 12,
  },
  badgeText: {
    color: '#fff',
    fontWeight: '600',
  },
  badgeOk: {
    color: '#8f8',
    marginTop: 4,
  },
  badgeError: {
    color: '#f88',
    marginTop: 4,
  },
  toast: {
    position: 'absolute',
    bottom: 40,
    left: 20,
    right: 20,
    padding: 14,
    borderRadius: 12,
  },
  toastText: {
    color: '#fff',
    fontWeight: '600',
    textAlign: 'center',
  },
  toastSuccess: {
    backgroundColor: 'rgba(0,128,0,0.85)',
  },
  toastWarning: {
    backgroundColor: 'rgba(192,128,0,0.9)',
  },
  toastError: {
    backgroundColor: 'rgba(192,0,0,0.9)',
  },
  offlineBanner: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    backgroundColor: '#ffcc00',
    padding: 10,
    zIndex: 10,
    alignItems: 'center',
  },
  offlineText: {
    color: '#000',
    fontWeight: 'bold',
    textAlign: 'center',
  },
});