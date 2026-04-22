import React, { useEffect, useState } from 'react';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { ActivityIndicator, Alert, Button, ScrollView, StyleSheet, Text, View } from 'react-native';
import { getParticipantById, markRegisteredLocally, markPrintedLocally } from '../../src/db/participants';
import { enqueueTask } from '../../src/db/syncQueue';
import { generateDeviceId } from '../../src/utils/deviceId';
import { printReceipt } from '../../src/print/printer';
import { getEventName } from '../../src/auth/google';

export default function Confirm() {
  const params = useLocalSearchParams();
  const router = useRouter();
  const id = String(params.id ?? '');
  const [participant, setParticipant] = useState<any | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  useEffect(() => {
    async function loadParticipant() {
      if (!id) {
        setLoading(false);
        return;
      }
      const row = await getParticipantById(id);
      setParticipant(row);
      setLoading(false);
    }

    loadParticipant();
  }, [id]);

  useEffect(() => {
    if (!toast) return;
    const timeout = setTimeout(() => setToast(null), 3000);
    return () => clearTimeout(timeout);
  }, [toast]);

  async function handleConfirm() {
    if (!participant) {
      return;
    }

    setSaving(true);
    try {
      const deviceId = await generateDeviceId();
      const verifiedAt = Date.now();
      await markRegisteredLocally(id, deviceId);
      await enqueueTask('mark_registered', {
        participantId: id,
        sheetsRow: participant.sheets_row,
        verifiedAt: new Date(verifiedAt).toISOString(),
        registeredBy: deviceId,
      });

      const eventName = getEventName();
      printReceipt({ ...participant, verified_at: verifiedAt }, eventName)
        .then(async () => {
          await markPrintedLocally(id);
          await enqueueTask('mark_printed', {
            participantId: id,
            sheetsRow: participant.sheets_row,
            printedAt: new Date(Date.now()).toISOString(),
            registeredBy: deviceId,
          });
        })
        .catch((error) => {
          console.warn('Print failed', error);
        });

      setToast(`Checked in: ${participant.full_name}`);
      router.replace('/');
    } catch (error: any) {
      Alert.alert('Error', error?.message ?? 'Failed to confirm check-in');
    } finally {
      setSaving(false);
    }
  }

  function handleCancel() {
    router.replace('/');
  }

  if (loading) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  if (!participant) {
    return (
      <View style={styles.centered}>
        <Text style={styles.notFoundText}>Participant not found.</Text>
        <Button title="Back to scan" onPress={handleCancel} />
      </View>
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.title}>Confirm Check-In</Text>
      {participant.status ? (
        <View style={styles.statusBadge}>
          <Text style={styles.statusText}>{participant.status}</Text>
        </View>
      ) : null}
      <View style={styles.card}>
        <Text style={styles.label}>Name</Text>
        <Text style={styles.value}>{participant.full_name}</Text>
        {participant.stake ? (
          <>
            <Text style={styles.label}>Stake</Text>
            <Text style={styles.value}>{participant.stake}</Text>
          </>
        ) : null}
        {participant.ward ? (
          <>
            <Text style={styles.label}>Ward</Text>
            <Text style={styles.value}>{participant.ward}</Text>
          </>
        ) : null}
        {participant.gender ? (
          <>
            <Text style={styles.label}>Gender</Text>
            <Text style={styles.value}>{participant.gender}</Text>
          </>
        ) : null}
        <Text style={styles.label}>Room</Text>
        <Text style={styles.value}>{participant.room_number || '(not assigned)'}</Text>
        <Text style={styles.label}>Table</Text>
        <Text style={styles.value}>{participant.table_number || '(not assigned)'}</Text>
        {participant.tshirt_size ? (
          <>
            <Text style={styles.label}>Shirt Size</Text>
            <Text style={styles.value}>{participant.tshirt_size}</Text>
          </>
        ) : null}
        {participant.medical_info ? (
          <>
            <Text style={styles.label}>Medical/Food Info</Text>
            <Text style={styles.warningValue}>{participant.medical_info}</Text>
          </>
        ) : null}
        {participant.note ? (
          <>
            <Text style={styles.label}>Note</Text>
            <Text style={styles.value}>{participant.note}</Text>
          </>
        ) : null}
      </View>

      <Button title="Confirm Check-In" onPress={handleConfirm} disabled={saving} />
      <View style={styles.spacer} />
      <Button title="Cancel" onPress={handleCancel} disabled={saving} />

      {toast ? <Text style={styles.toast}>{toast}</Text> : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 20,
    minHeight: '100%',
    backgroundColor: '#fff',
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    marginBottom: 24,
  },
  card: {
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 12,
    padding: 16,
    marginBottom: 24,
    backgroundColor: '#fafafa',
  },
  statusBadge: {
    backgroundColor: '#fde68a',
    borderRadius: 10,
    paddingVertical: 8,
    paddingHorizontal: 12,
    alignSelf: 'flex-start',
    marginBottom: 16,
  },
  statusText: {
    color: '#92400e',
    fontWeight: '700',
  },
  label: {
    color: '#555',
    marginTop: 12,
    fontWeight: '600',
  },
  value: {
    fontSize: 18,
    marginTop: 4,
  },
  warningValue: {
    fontSize: 18,
    marginTop: 4,
    color: '#b91c1c',
  },
  spacer: {
    height: 14,
  },
  toast: {
    marginTop: 20,
    color: '#0b7',
    fontWeight: '700',
    textAlign: 'center',
  },
  notFoundText: {
    fontSize: 18,
    marginBottom: 20,
  },
});
