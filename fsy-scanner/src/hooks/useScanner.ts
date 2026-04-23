import { useCallback, useEffect, useState } from 'react';
import { useCameraPermissions } from 'expo-camera';

interface BarcodeScanResult {
  type: string;
  data: string;
}

export function useScanner() {
  const [permission, requestPermission] = useCameraPermissions();
  const [isScanning, setIsScanning] = useState(true);
  const [scannedId, setScannedId] = useState<string | null>(null);

  useEffect(() => {
    if (permission && !permission.granted && permission.canAskAgain) {
      requestPermission();
    }
  }, [permission, requestPermission]);

  const onBarCodeScanned = useCallback(
    (result: BarcodeScanResult) => {
      if (!isScanning || !result.data) return;
      setIsScanning(false);
      setScannedId(result.data);
      setTimeout(() => {
        setIsScanning(true);
        setScannedId(null);
      }, 2000);
    },
    [isScanning]
  );

  const resetScanner = useCallback(() => {
    setScannedId(null);
    setIsScanning(true);
  }, []);

  return {
    hasPermission: permission?.granted ?? false,
    isScanning,
    scannedId,
    onBarCodeScanned,
    resetScanner,
  };
}