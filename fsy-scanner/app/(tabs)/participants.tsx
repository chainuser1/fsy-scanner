import React, { useEffect, useState } from 'react';
import { FlatList, StyleSheet, Text, TextInput, View } from 'react-native';
import { getAllParticipants, getRegisteredCount, searchParticipants } from '../../src/db/participants';

export default function Participants() {
  const [query, setQuery] = useState('');
  const [participants, setParticipants] = useState<any[]>([]);
  const [registeredCount, setRegisteredCount] = useState(0);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadParticipants() {
      setLoading(true);
      if (query.trim().length > 0) {
        setParticipants(await searchParticipants(query.trim()));
      } else {
        setParticipants(await getAllParticipants());
      }
      setRegisteredCount(await getRegisteredCount());
      setLoading(false);
    }

    loadParticipants();
  }, [query]);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Participants</Text>
      <Text style={styles.summary}>Registered: {registeredCount}</Text>
      <TextInput
        style={styles.search}
        placeholder="Search by name"
        value={query}
        onChangeText={setQuery}
        autoCorrect={false}
        autoCapitalize="words"
      />

      {loading ? (
        <Text style={styles.loading}>Loading...</Text>
      ) : (
        <FlatList
          data={participants}
          keyExtractor={(item) => item.id}
          renderItem={({ item }) => (
            <View style={styles.row}>
              <View style={styles.rowText}>
                <Text style={styles.name}>{item.full_name}</Text>
                <Text style={styles.meta}>Room: {item.room_number || '(not assigned)'}</Text>
                <Text style={styles.meta}>Table: {item.table_number || '(not assigned)'}</Text>
              </View>
              <View style={[styles.badge, item.registered === 1 ? styles.badgeRegistered : styles.badgePending]}>
                <Text style={styles.badgeText}>{item.registered === 1 ? 'Registered' : 'Pending'}</Text>
              </View>
            </View>
          )}
          contentContainerStyle={styles.list}
          ListEmptyComponent={<Text style={styles.empty}>No participants found.</Text>}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: '#fff',
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    marginBottom: 8,
  },
  summary: {
    fontSize: 16,
    marginBottom: 16,
    color: '#555',
  },
  search: {
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 10,
    padding: 12,
    marginBottom: 16,
    fontSize: 16,
  },
  loading: {
    textAlign: 'center',
    marginTop: 20,
    color: '#666',
  },
  list: {
    paddingBottom: 40,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderWidth: 1,
    borderColor: '#eee',
    borderRadius: 12,
    padding: 14,
    marginBottom: 12,
    backgroundColor: '#fafafa',
  },
  rowText: {
    flex: 1,
    paddingRight: 12,
  },
  name: {
    fontSize: 16,
    fontWeight: '600',
  },
  meta: {
    color: '#666',
    marginTop: 4,
  },
  badge: {
    borderRadius: 999,
    paddingVertical: 6,
    paddingHorizontal: 12,
  },
  badgeRegistered: {
    backgroundColor: '#d8f8dc',
  },
  badgePending: {
    backgroundColor: '#f8ebd8',
  },
  badgeText: {
    fontSize: 12,
    fontWeight: '700',
    color: '#333',
  },
  empty: {
    textAlign: 'center',
    color: '#666',
    marginTop: 20,
  },
});
