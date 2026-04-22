import QuickCrypto, { Buffer } from 'react-native-quick-crypto';

// ─── Environment variables ────────────────────────────────────────────────────
const SERVICE_ACCOUNT_EMAIL = process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL;
const SERVICE_ACCOUNT_PRIVATE_KEY = process.env.GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY;

export const SHEETS_ID = process.env.EXPO_PUBLIC_SHEETS_ID ?? '';
export const SHEETS_TAB = process.env.EXPO_PUBLIC_SHEETS_TAB ?? '';
export const EVENT_NAME = process.env.EXPO_PUBLIC_EVENT_NAME ?? '';

// ─── In-memory token cache ────────────────────────────────────────────────────
let cachedToken: string | null = null;
let expiresAt: number = 0;

// ─── JWT helpers ──────────────────────────────────────────────────────────────
function base64UrlEncode(str: string): string {
  return Buffer.from(str, 'utf8')
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function signRS256(input: string, privateKeyPem: string): string {
  const signer = QuickCrypto.createSign('RSA-SHA256');
  signer.update(input);
  return signer
    .sign(privateKeyPem, 'base64')
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function buildSignedJwt(email: string, privateKeyPem: string): string {
  const header = base64UrlEncode(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const claims = base64UrlEncode(
    JSON.stringify({
      iss: email,
      scope: 'https://www.googleapis.com/auth/spreadsheets',
      aud: 'https://oauth2.googleapis.com/token',
      exp: now + 3600,
      iat: now,
    })
  );
  const unsigned = `${header}.${claims}`;
  const signature = signRS256(unsigned, privateKeyPem);
  return `${unsigned}.${signature}`;
}

async function fetchNewToken(email: string, privateKey: string): Promise<string> {
  const signedJwt = buildSignedJwt(email, privateKey);

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body:
      'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer' +
      `&assertion=${encodeURIComponent(signedJwt)}`,
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Token exchange failed HTTP ${response.status}: ${body}`);
  }

  const data = await response.json();
  if (!data.access_token) {
    throw new Error('Token response missing access_token');
  }

  return data.access_token as string;
}

export async function getValidToken(): Promise<string | null> {
  if (cachedToken && Date.now() < expiresAt - 60_000) {
    return cachedToken;
  }

  if (!SERVICE_ACCOUNT_EMAIL || !SERVICE_ACCOUNT_PRIVATE_KEY) {
    console.error('[google.ts] Missing GOOGLE_SERVICE_ACCOUNT_EMAIL or GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY in .env');
    return null;
  }

  const privateKey = SERVICE_ACCOUNT_PRIVATE_KEY.replace(/\\n/g, '\n');

  try {
    const token = await fetchNewToken(SERVICE_ACCOUNT_EMAIL, privateKey);
    cachedToken = token;
    expiresAt = Date.now() + 3_500_000;
    console.log(`[google.ts] Token obtained for ${SERVICE_ACCOUNT_EMAIL}`);
    return cachedToken;
  } catch (error) {
    console.error('[google.ts] Token fetch failed:', error);
    cachedToken = null;
    expiresAt = 0;
    return null;
  }
}

export function getSheetsId(): string {
  return SHEETS_ID;
}

export function getSheetsTab(): string {
  return SHEETS_TAB;
}

export function getEventName(): string {
  return EVENT_NAME;
}
