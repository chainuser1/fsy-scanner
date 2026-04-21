import React from 'react';
import { View, Text } from 'react-native';
import { useLocalSearchParams } from 'expo-router';

export default function Confirm() {
  const params = useLocalSearchParams();
  const id = params.id ?? 'unknown';
  return (
    <View style={{flex:1,alignItems:'center',justifyContent:'center'}}>
      <Text>Confirm screen for {id} (placeholder)</Text>
    </View>
  );
}
