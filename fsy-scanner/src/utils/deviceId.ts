import * as Crypto from 'expo-crypto';

// Generate or return a stable device id (placeholder)
export async function generateDeviceId(): Promise<string> {
  // TODO: persist this value (expo-secure-store)
  const now = Date.now().toString();
  const hash = await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, now);
  return hash.slice(0, 36);
}
