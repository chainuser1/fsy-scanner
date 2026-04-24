import React, { useEffect, useState } from 'react';
import { FlatList, StyleSheet, Text, TextInput, View, useColorScheme } from 'react-native';
import { getAllParticipants, getRegisteredCount, searchParticipants } from '../../src/db/participants';

export default function Participants() {
  const [query, setQuery] = useState('');
  const [participants, setParticipants] = useState<any[]>([]);
  const [registeredCount, setRegisteredCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const colorScheme = useColorScheme();

  // Define styles based on color scheme
  const backgroundColor = colorScheme === 'dark' ? '#121212' : '#fff';
  const textColor = colorScheme === 'dark' ? '#fff' : '#000';
  const inputBackgroundColor = colorScheme === 'dark' ? '#1e1e1e' : '#fafafa';
  const inputBorderColor = colorScheme === 'dark' ? '#333' : '#ddd';
  const rowBackgroundColor = colorScheme === 'dark' ? '#1e1e1e' : '#fafafa';
  const metaTextColor = colorScheme === 'dark' ? '#aaa' : '#666';

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

  // Skeleton loader component
  const SkeletonLoader = () => {
    return (
      <>
        {[...Array(5)].map((_, index) => (
          <View 
            key={index} 
            style={[
              styles.row, 
              { backgroundColor: colorScheme === 'dark' ? '#333' : '#f0f0f0' }
            ]}
          >
            <View style={styles.skeletonContent}>
              <View 
                style={[
                  styles.skeletonLine, 
                  { backgroundColor: colorScheme === 'dark' ? '#444' : '#ddd' }
                ]} 
              />
              <View 
                style={[
                  styles.skeletonLine, 
                  { backgroundColor: colorScheme === 'dark' ? '#444' : '#ddd', width: '70%' }
                ]} 
              />
              <View 
                style={[
                  styles.skeletonLine, 
                  { backgroundColor: colorScheme === 'dark' ? '#444' : '#ddd', width: '50%' }
                ]} 
              />
            </View>
          </View>
        ))}
      </>
    );
  };

  return (
    <View style={[styles.container, { backgroundColor }]}>
      <Text style={[styles.title, { color: textColor }]}>Participants</Text>
      <Text style={[styles.summary, { color: textColor }]}>Registered: {registeredCount}</Text>
      <TextInput
        style={[styles.search, { backgroundColor: inputBackgroundColor, borderColor: inputBorderColor, color: textColor }]}
        placeholder={colorScheme === 'dark' ? 'Search by name...' : 'Search by name'}
        placeholderTextColor={colorScheme === 'dark' ? '#aaa' : '#888'}
        value={query}
        onChangeText={setQuery}
        autoCorrect={false}
        autoCapitalize="words"
      />

      {loading ? (
        <SkeletonLoader />
      ) : (
        <FlatList
          data={participants}
          keyExtractor={(item) => item.id}
          renderItem={({ item }) => (
            <View style={[styles.row, { backgroundColor: rowBackgroundColor }]}>
              <View style={styles.rowText}>
                <Text style={[styles.name, { color: textColor }]}>{item.full_name}</Text>
                <Text style={[styles.meta, { color: metaTextColor }]}>Room: {item.room_number || '(not assigned)'}</Text>
                <Text style={[styles.meta, { color: metaTextColor }]}>Table: {item.table_number || '(not assigned)'}</Text>
              </View>
              <View style={[styles.badge, item.registered === 1 ? styles.badgeRegistered : styles.badgePending]}>
                <Text style={styles.badgeText}>{item.registered === 1 ? 'Registered' : 'Pending'}</Text>
              </View>
            </View>
          )}
          contentContainerStyle={styles.list}
          ListEmptyComponent={<Text style={[styles.empty, { color: textColor }]}>No participants found.</Text>}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: '700',
    marginBottom: 8,
  },
  summary: {
    fontSize: 16,
    marginBottom: 16,
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
  },
  skeletonContent: {
    flex: 1,
    paddingRight: 12,
  },
  skeletonLine: {
    height: 16,
    borderRadius: 4,
    marginBottom: 8,
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
    marginTop: 20,
  },
});