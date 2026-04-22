import base64 from 'base-64';
import * as SecureStore from 'expo-secure-store';

const SERVICE_ACCOUNT_EMAIL = process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL;
const SERVICE_ACCOUNT_PRIVATE_KEY = process.env.GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY;
const SHEETS_ID = process.env.EXPO_PUBLIC_SHEETS_ID;
const SHEETS_TAB = process.env.EXPO_PUBLIC_SHEETS_TAB;
const EVENT_NAME = process.env.EXPO_PUBLIC_EVENT_NAME;

const ACCESS_TOKEN_KEY = 'fsy_service_account_access_token';
const ACCESS_TOKEN_EXPIRES_AT_KEY = 'fsy_service_account_access_token_expires_at';
const TOKEN_URI = 'https://oauth2.googleapis.com/token';
const SCOPE = 'https://www.googleapis.com/auth/spreadsheets';

function requireEnv(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(`Missing required env var ${name}`);
  }
  return value;
}

function encodeBase64Url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const chunkSize = 0x8000;

  for (let i = 0; i < bytes.length; i += chunkSize) {
    const slice = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...slice);
  }

  return base64
    .encode(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function encodeBase64UrlString(value: string): string {
  return base64
    .encode(value)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function getCryptoSubtle(): SubtleCrypto {
  const globalCrypto = (globalThis as any).crypto;
  if (!globalCrypto || !globalCrypto.subtle) {
    throw new Error('WebCrypto SubtleCrypto is unavailable in this environment');
  }
  return globalCrypto.subtle as SubtleCrypto;
}

function getTextEncoder(): TextEncoder {
  if (typeof TextEncoder === 'undefined') {
    throw new Error('TextEncoder is unavailable in this environment');
  }
  return new TextEncoder();
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const header = '-----BEGIN PRIVATE KEY-----';
  const footer = '-----END PRIVATE KEY-----';
  const start = pem.indexOf(header);
  const end = pem.indexOf(footer, start + header.length);

  if (start < 0 || end < 0) {
    throw new Error('Invalid PKCS#8 private key format');
  }

  const base64Key = pem.slice(start + header.length, end).replace(/\s+/g, '');
  const binary = base64.decode(base64Key);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }

  return bytes.buffer;
}

async function importPrivateKey(): Promise<CryptoKey> {
  const privateKeyPem = requireEnv('GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY', SERVICE_ACCOUNT_PRIVATE_KEY);
  const keyData = pemToArrayBuffer(privateKeyPem);

  return getCryptoSubtle().importKey(
    'pkcs8',
    keyData,
    {
      name: 'RSASSA-PKCS1-v1_5',
      hash: 'SHA-256',
    },
    false,
    ['sign']
  );
}

function createJwtHeader(): string {
  return encodeBase64UrlString(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
}

function createJwtPayload(): string {
  const nowSeconds = Math.floor(Date.now() / 1000);
  return encodeBase64UrlString(
    JSON.stringify({
      iss: requireEnv('GOOGLE_SERVICE_ACCOUNT_EMAIL', SERVICE_ACCOUNT_EMAIL),
      scope: SCOPE,
      aud: TOKEN_URI,
      exp: nowSeconds + 3600,
      iat: nowSeconds,
    })
  );
}

async function signJwt(unsignedToken: string): Promise<string> {
  const key = await importPrivateKey();
  const encoder = getTextEncoder();
  const signature = await getCryptoSubtle().sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    key,
    encoder.encode(unsignedToken)
  );
  return encodeBase64Url(signature);
}

async function fetchServiceAccountToken(): Promise<string> {
  const jwt = `${createJwtHeader()}.${createJwtPayload()}`;
  const signedJwt = await signJwt(jwt);
  const assertion = `${jwt}.${signedJwt}`;

  const response = await fetch(TOKEN_URI, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }).toString(),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Google token request failed (${response.status}): ${text}`);
  }

  const json = await response.json();
  const accessToken = json.access_token as string | undefined;
  const expiresIn = json.expires_in as number | undefined;

  if (!accessToken || !expiresIn) {
    throw new Error('Google token response is missing access_token or expires_in');
  }

  const expiresAt = Date.now() + expiresIn * 1000;
  await SecureStore.setItemAsync(ACCESS_TOKEN_KEY, accessToken);
  await SecureStore.setItemAsync(ACCESS_TOKEN_EXPIRES_AT_KEY, `${expiresAt}`);

  return accessToken;
}

async function getCachedToken(): Promise<string | null> {
  const token = await SecureStore.getItemAsync(ACCESS_TOKEN_KEY);
  const expiresAtValue = await SecureStore.getItemAsync(ACCESS_TOKEN_EXPIRES_AT_KEY);

  if (!token || !expiresAtValue) {
    return null;
  }

  const expiresAt = parseInt(expiresAtValue, 10);
  if (Number.isNaN(expiresAt) || Date.now() + 60000 >= expiresAt) {
    return null;
  }

  return token;
}

export async function signIn(): Promise<void> {
  requireEnv('GOOGLE_SERVICE_ACCOUNT_EMAIL', SERVICE_ACCOUNT_EMAIL);
  requireEnv('GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY', SERVICE_ACCOUNT_PRIVATE_KEY);
  await getValidToken();
}

export async function getValidToken(): Promise<string | null> {
  const cached = await getCachedToken();
  if (cached) {
    return cached;
  }
  return fetchServiceAccountToken();
}

export async function signOut(): Promise<void> {
  await Promise.all([
    SecureStore.deleteItemAsync(ACCESS_TOKEN_KEY),
    SecureStore.deleteItemAsync(ACCESS_TOKEN_EXPIRES_AT_KEY),
  ]);
}

export function getSheetsId(): string {
  return requireEnv('EXPO_PUBLIC_SHEETS_ID', SHEETS_ID);
}

export function getSheetsTab(): string {
  return requireEnv('EXPO_PUBLIC_SHEETS_TAB', SHEETS_TAB);
}

export function getEventName(): string {
  return requireEnv('EXPO_PUBLIC_EVENT_NAME', EVENT_NAME);
}
