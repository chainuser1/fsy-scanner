import { useState, useCallback } from 'react';
import { useCameraPermissions } from 'expo-camera';

export interface BarcodeScanResult {
  data: string;
  type: string;
}

export function useScanner() {
  const [scannedId, setScannedId] = useState<string | null>(null);
  const [hasPermission, setHasPermission] = useState<boolean | null>(null);
  const [isScanning, setIsScanning] = useState<boolean>(true);

  const [permission, requestPermission] = useCameraPermissions();

  const checkPermission = useCallback(async () => {
    if (permission?.granted) {
      setHasPermission(true);
      return true;
    }
    
    const result = await requestPermission();
    setHasPermission(result.granted);
    return result.granted;
  }, [permission]);

  const onBarCodeScanned = useCallback(({ data }: BarcodeScanResult) => {
    if (!isScanning) return;

    setScannedId(data);
    setIsScanning(false);

    // Pause scanning for 2 seconds to prevent double scans
    setTimeout(() => {
      setIsScanning(true);
    }, 2000);
  }, [isScanning]);

  const resetScanner = useCallback(() => {
    setScannedId(null);
    setIsScanning(true);
  }, []);

  return {
    scannedId,
    hasPermission,
    isScanning,
    checkPermission,
    onBarCodeScanned,
    resetScanner,
  };
}