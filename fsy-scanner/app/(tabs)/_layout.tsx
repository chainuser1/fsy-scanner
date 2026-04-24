import React from 'react';
import { Tabs } from 'expo-router';
import { View, Text, StyleSheet } from 'react-native';
import { useAppStore } from '../../src/store/useAppStore';
import type { AppState } from '../../src/store/useAppStore';

type TabIconProps = {
  color: string;
  focused: boolean;
};

export default function TabLayout() {
  const failedTaskCount = useAppStore((state: AppState) => state.failedTaskCount);

  // Custom badge component for failed tasks
  const FailedTasksBadge = () => {
    if (failedTaskCount <= 0) return null;
    
    return (
      <View style={styles.badge}>
        <Text style={styles.badgeText}>{failedTaskCount}</Text>
      </View>
    );
  };

  return (
    <Tabs screenOptions={{
      tabBarActiveTintColor: '#007AFF',
      headerShown: false,
    }}>
      <Tabs.Screen
        name="scan"
        options={{
          title: 'Scan',
          tabBarIcon: ({ color, focused }: TabIconProps) => (
            <></>
          ),
        }}
      />
      <Tabs.Screen
        name="participants"
        options={{
          title: 'Participants',
          tabBarIcon: ({ color, focused }: TabIconProps) => (
            <></>
          ),
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: 'Settings',
          tabBarIcon: ({ color, focused }: TabIconProps) => (
            <View style={{ position: 'relative' }}>
              <FailedTasksBadge />
            </View>
          ),
        }}
      />
    </Tabs>
  );
}

const styles = StyleSheet.create({
  badge: {
    position: 'absolute',
    right: -6,
    top: -6,
    backgroundColor: '#FF3B30',
    borderRadius: 10,
    minWidth: 20,
    height: 20,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 3,
    zIndex: 1,
  },
  badgeText: {
    color: 'white',
    fontSize: 12,
    fontWeight: 'bold',
  },
});