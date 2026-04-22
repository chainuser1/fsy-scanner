import { useCallback, useEffect, useState } from 'react';
import { Camera, PermissionStatus } from 'expo-camera';
import { BarCodeScannerResult } from 'expo-barcode-scanner';

export function useScanner() {
  const [hasPermission, setHasPermission] = useState<boolean | null>(null);
  const [isScanning, setIsScanning] = useState(true);
  const [scannedId, setScannedId] = useState<string | null>(null);

  useEffect(() => {
    async function requestPermission() {
      try {
        const { status } = await Camera.requestCameraPermissionsAsync();
        setHasPermission(status === PermissionStatus.GRANTED);
      } catch (error) {
        setHasPermission(false);
      }
    }

    requestPermission();
  }, []);

  const onBarCodeScanned = useCallback(
    (result: BarCodeScannerResult) => {
      if (!isScanning || !result.data) {
        return;
      }

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
    hasPermission,
    isScanning,
    scannedId,
    onBarCodeScanned,
    resetScanner,
  };
}
