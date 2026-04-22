import { useEffect } from 'react';
import { useRouter } from 'expo-router';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

export default function Index() {
  const router = useRouter();

  useEffect(() => {
    router.replace('/scan');
  }, [router]);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Opening scanner…</Text>
      <ActivityIndicator size="large" style={styles.spinner} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 24,
    backgroundColor: '#fff',
  },
  title: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 16,
  },
  spinner: {
    marginTop: 16,
  },
});
