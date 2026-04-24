# FSY Check-In Scanner — Flutter Rebuild Plan
**Version:** 1.0  
**Framework:** Flutter (Dart)  
**Prepared by:** Jayson (ML Engineer · Dagami Ward FSY Organizer)  
**For:** QweCoder AI Agent — Read every word. Follow exactly.  
**Branch:** `main` (Flutter only — no React Native code)  
**Status:** Active

---

## ⚠️ CRITICAL AI AGENT RULES — READ FIRST, NEVER SKIP

1. **This is a Flutter/Dart project.** There is zero React Native, zero JavaScript, zero TypeScript. If you find any `.js`, `.ts`, `.tsx` files — ignore them. Do not reference them.
2. **DO NOT hallucinate Flutter packages.** Before using any package, verify it exists on pub.dev. If unsure — stop and say so.
3. **DO NOT proceed to the next task until the current task passes its VERIFY check.**
4. **DO NOT rename files, folders, or database columns** from what is specified here.
5. **After completing each task**, append an entry to `DEVLOG.md` using the format in Section 12.
6. **Before writing any code**, re-read the full task spec. Then write. Then verify. Then log.
7. **If anything is ambiguous** — stop and ask. Do not guess.
8. **Think step by step.** Write a one-line comment above every function describing what it does.
9. **Never overwrite `DEVLOG.md`** — always append.
10. **Run `flutter analyze` after every task.** Zero errors required before proceeding.
11. **This plan was migrated from React Native.** The architecture, schema, and API logic are proven. Only the language changes — Dart instead of TypeScript.

---

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-04-23 | Initial Flutter plan — migrated from React Native plan v1.6 |

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [System Architecture](#2-system-architecture)
3. [SQLite Schema](#3-sqlite-schema)
4. [Google Sheets Contract](#4-google-sheets-contract)
5. [Folder Structure](#5-folder-structure)
6. [Dependencies](#6-dependencies)
7. [Module Specifications](#7-module-specifications)
8. [Implementation Phases](#8-implementation-phases)
9. [QR Code Format](#9-qr-code-format)
10. [Google Sheets Setup](#10-google-sheets-setup)
11. [Testing Checklist](#11-testing-checklist)
12. [DEVLOG Format](#12-devlog-format)
13. [Known Risks & Mitigations](#13-known-risks--mitigations)
14. [Hard Constraints](#14-hard-constraints)

---
## 0 Some Note:


Flutter devices shows:

V2250 (mobile)  • android-arm64 • Android 15 (API 35) ← USE THIS
Linux (desktop) ← ignore
Chrome (web) ← ignore


## 1. Project Overview

### 1.1 What This App Does

A **mobile check-in scanner app** for FSY (For the Strength of Youth) events:
- Scans participant QR codes at check-in stations
- Instantly confirms registration from local SQLite (no network wait)
- Marks participant as registered in Google Sheets in the background
- Prints a receipt to a paired Bluetooth ESC/POS thermal printer
- Supports multiple devices simultaneously — no central server

### 1.2 Scale & Hardware

- ~1,000 participants
- 2+ scanning devices, one Bluetooth thermal printer per device
- ESC/POS thermal printer (same type used in grocery stores — 80mm paper)
- Android 11 through current (API 30+)
- Hotel WiFi environment

### 1.3 Core Design Principles

| Principle | Implementation |
|---|---|
| **Local-First** | All reads hit SQLite. Network is background only. Never block UI on network. |
| **Resilient Queue** | Sync tasks in SQLite survive crashes. Only deleted after Sheets confirms HTTP 200. |
| **No Backend Server** | Devices talk directly to Google Sheets API only. No intermediary server. |
| **One Printer Per Device** | Each phone pairs its own Bluetooth printer. Print is fire-and-forget. |
| **Idempotent Writes** | Registering same participant twice is safe — SQLite and Sheets both guard against it. |

---

## 2. System Architecture

### 2.1 Data Flow

```
READ PATH (must be < 50ms):
  QR Scan → SQLite lookup → UI confirmation → Bluetooth print

WRITE PATH (background, non-blocking):
  SQLite write (immediate) → enqueue sync task → background worker
  → Sheets API → task marked complete + deleted
```

### 2.2 Component Map

```
┌─────────────────────────────────────┐
│          Google Sheets              │
│    (remote source of truth)         │
└──────────────┬──────────────────────┘
               │  Sheets API v4 (http only)
               │  Pull deltas every 15s
               │  Push registrations from queue
┌──────────────▼──────────────────────┐
│         Local SQLite                │
│  participants | sync_tasks          │
│  app_settings                       │
│  (source of truth FOR THE APP)      │
└──────┬──────────────────┬───────────┘
       │                  │
┌──────▼──────┐   ┌───────▼────────┐
│ QR Scanner  │   │  Sync Engine   │
│  (instant)  │   │  (background)  │
└──────┬──────┘   └────────────────┘
       │
┌──────▼──────┐
│  BT Printer │
│(fire+forget)│
└─────────────┘
```

### 2.3 Multi-Device Strategy

- Each device has its own SQLite database and its own Bluetooth printer
- Devices do NOT talk to each other
- Convergence through Google Sheets — Device A writes → Sheets → Device B reads on next tick
- Duplicate registration handled by: SQLite check before registering + puller never overwrites `registered = 1` with `0`

### 2.4 First Run vs Subsequent Runs

**First Run:**
```
App launches → runMigrations() → startSyncEngine()
  → seed app_settings from .env values
  → detect col_map from Sheet header row
  → full pull (~1,000 rows) → seed SQLite
  → show loading indicator during pull
  → scanner activates when done
```

**Subsequent Runs:**
```
App launches → runMigrations() (skips — already done)
  → startSyncEngine()
  → col_map already in DB — skip detection
  → delta pull (only changed rows)
  → scanner ready immediately
  → drain any queued sync tasks from before restart
```

---

## 3. SQLite Schema

> **AI AGENT:** Use `sqflite` package. These are the exact table definitions. Do not add, rename, or change columns without explicit approval. Any schema change requires a migration — never modify the base DDL after first run.

### 3.1 Table: `participants`

```sql
CREATE TABLE IF NOT EXISTS participants (
  id              TEXT PRIMARY KEY,
  full_name       TEXT NOT NULL,
  stake           TEXT,
  ward            TEXT,
  gender          TEXT,
  room_number     TEXT,
  table_number    TEXT,
  tshirt_size     TEXT,
  medical_info    TEXT,
  note            TEXT,
  status          TEXT,
  registered      INTEGER DEFAULT 0,
  verified_at     INTEGER,
  printed_at      INTEGER,
  registered_by   TEXT,
  sheets_row      INTEGER NOT NULL,
  raw_json        TEXT,
  updated_at      INTEGER
);
```

**Column notes:**
- `id` — exact value encoded in QR code
- `registered` — 0 = not checked in, 1 = checked in
- `verified_at` — Unix ms timestamp when QR was scanned and confirmed
- `printed_at` — Unix ms timestamp when receipt was printed (null if print failed)
- `registered_by` — device_id of the scanner phone
- `sheets_row` — 1-based row index in Google Sheets
- `medical_info` — shown as warning on confirm screen if not empty
- `note` — shown on confirm screen if not empty

### 3.2 Table: `sync_tasks`

```sql
CREATE TABLE IF NOT EXISTS sync_tasks (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  type          TEXT NOT NULL,
  payload       TEXT NOT NULL,
  status        TEXT DEFAULT 'pending',
  attempts      INTEGER DEFAULT 0,
  last_error    TEXT,
  created_at    INTEGER,
  completed_at  INTEGER
);
```

**Valid `type` values:** `mark_registered` | `mark_printed`  
**Valid `status` values:** `pending` | `in_progress` | `complete`

**Payload schemas:**

```dart
// type: 'mark_registered'
{
  'participantId': String,   // matches participants.id
  'sheetsRow': int,          // 1-based row index
  'verifiedAt': int,         // Unix ms timestamp
  'registeredBy': String     // device_id
}

// type: 'mark_printed'
{
  'participantId': String,
  'sheetsRow': int,
  'printedAt': int           // Unix ms timestamp
}
```

### 3.3 Table: `app_settings`

```sql
CREATE TABLE IF NOT EXISTS app_settings (
  key   TEXT PRIMARY KEY,
  value TEXT
);
```

**Required keys:**

| Key | Value Format | Source |
|---|---|---|
| `device_id` | UUID v4 string | Generated on first migration |
| `sheets_id` | String | Seeded from env on first launch |
| `sheets_tab` | String | Seeded from env on first launch |
| `event_name` | String | Seeded from env on first launch |
| `last_pulled_at` | Unix ms as string | Set by puller after each pull |
| `printer_address` | Bluetooth MAC address | Set by user in Settings screen |
| `col_map` | JSON string | Auto-detected by engine on first launch |
| `sync_interval_ms` | Number as string (default 15000) | Default value |
| `db_version` | Number as string | Set by migration runner |

### 3.4 Migration Strategy

- `DatabaseHelper` class runs migrations on every app launch
- Each migration is numbered and gated by `db_version` in `app_settings`
- Migrations only run forward — never roll back
- If a migration fails: log the error and show a fatal error screen
- Migration v1: create all 3 tables, generate device_id UUID, set db_version = 1

---

## 4. Google Sheets Contract

### 4.1 Sheet Columns (exact header names — case-sensitive)

| Header | SQLite Field | Written By |
|---|---|---|
| `ID` | `id` | Registration team |
| `QR Code` | — (ignored) | Registration team |
| `Stake` | `stake` | Registration team |
| `Ward` | `ward` | Registration team |
| `Name` | `full_name` | Registration team |
| `Gender` | `gender` | Registration team |
| `Registered` | `registered` | **App writes `Y`** |
| `Signed by` | — (ignored) | Registration team |
| `Status` | `status` | Registration team |
| `Medical/Food Info` | `medical_info` | Registration team |
| `Note` | `note` | Registration team |
| `T-Shirt Size` | `tshirt_size` | Registration team |
| `Table Number` | `table_number` | Registration team |
| `Hotel Room Number` | `room_number` | Registration team |
| `Verified At` | `verified_at` | **App writes ISO timestamp** |
| `Printed At` | `printed_at` | **App writes ISO timestamp** |

### 4.2 Required Write Headers for col_map

The app must find these headers to write back — if missing, halt sync and show error:
```
Registered, Verified At, Printed At
```

### 4.3 Column Map Detection

On first launch (col_map empty):
1. Fetch row 1 from Sheets
2. Build map: `{ 'ID': 0, 'Name': 1, ... }` (0-based)
3. Verify `Registered`, `Verified At`, `Printed At` exist
4. If missing: show error listing missing headers — halt sync
5. Save as JSON to `app_settings.col_map`

On subsequent launches: col_map exists — skip detection.

> **AI AGENT:** Never hardcode column letters. Always read from col_map.

### 4.4 Service Account Authentication

The app uses a **Google Service Account** — no user login, no browser, no OAuth flow.

**How it works:**
1. Read `GOOGLE_SERVICE_ACCOUNT_EMAIL` and `GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY` from environment
2. Build a JWT and sign it with RS256 using the private key
3. Exchange the JWT for an access token at `https://oauth2.googleapis.com/token`
4. Use that token in all Sheets API calls: `Authorization: Bearer {token}`
5. Token lasts 1 hour — refresh silently when expired

**Dart JWT signing:** Use `dart_jsonwebtoken` package for RS256 signing with PKCS#8 keys.

**Environment variables (from `.env` file via `flutter_dotenv`):**
```
GOOGLE_SERVICE_ACCOUNT_EMAIL=fsy-scanner-bot@fsy-scanner-2026.iam.gserviceaccount.com
GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----
SHEETS_ID=11QHtmj2_O_ZpHH6RZcwD6ygJ6KKD4SPp4mUa1mKLfwA
SHEETS_TAB=Scanner Copy
EVENT_NAME=FSY 2026 Tacloban and Tolosa
```

---

## 5. Folder Structure

> **AI AGENT:** Create every file at exactly this path. Do not reorganize.

```
fsy_scanner/
├── lib/
│   ├── main.dart                    # App entry point — calls dotenv, migrations, sync engine
│   ├── app.dart                     # MaterialApp + router setup
│   │
│   ├── db/
│   │   ├── database_helper.dart     # SQLite open, migration runner
│   │   ├── schema.dart              # SQL DDL strings only
│   │   ├── participants_dao.dart    # CRUD for participants table
│   │   └── sync_queue_dao.dart      # CRUD for sync_tasks table
│   │
│   ├── sync/
│   │   ├── sync_engine.dart         # Orchestrator — startup + 15s loop
│   │   ├── sheets_api.dart          # Google Sheets API v4 http wrapper
│   │   ├── puller.dart              # Delta pull: Sheets → SQLite
│   │   └── pusher.dart              # Queue drain: sync_tasks → Sheets
│   │
│   ├── auth/
│   │   └── google_auth.dart         # Service account JWT → access token
│   │
│   ├── print/
│   │   ├── printer_service.dart     # BT printer connect + print wrapper
│   │   └── receipt_builder.dart     # ESC/POS receipt document builder
│   │
│   ├── models/
│   │   ├── participant.dart         # Participant data class
│   │   └── sync_task.dart           # SyncTask data class
│   │
│   ├── providers/
│   │   └── app_state.dart           # ChangeNotifier global state
│   │
│   ├── screens/
│   │   ├── scan_screen.dart         # Main QR scanner screen
│   │   ├── confirm_screen.dart      # Registration confirmation screen
│   │   ├── participants_screen.dart # Searchable participant list
│   │   └── settings_screen.dart    # Printer pairing + sheet config
│   │
│   └── utils/
│       ├── device_id.dart           # Stable UUID per device
│       └── time_utils.dart          # Timestamp helpers
│
├── assets/
│   └── .env                         # Environment variables — gitignored
│
├── android/
│   └── app/
│       └── src/main/
│           └── AndroidManifest.xml  # Bluetooth + camera permissions
│
├── DEVLOG.md                        # Append-only execution log
├── pubspec.yaml                     # Flutter dependencies
└── analysis_options.yaml            # Dart strict analysis
```

---

## 6. Dependencies

> **AI AGENT:** Add these to `pubspec.yaml` exactly. Verify each exists on pub.dev before adding.

```yaml
dependencies:
  flutter:
    sdk: flutter

  # Database
  sqflite: ^2.3.3
  path: ^1.9.0

  # Google Sheets API (HTTP only — no SDK)
  http: ^1.2.1

  # JWT signing for Service Account auth
  dart_jsonwebtoken: ^2.8.2

  # Environment variables
  flutter_dotenv: ^5.1.0

  # QR scanning
  mobile_scanner: ^5.2.3

  # Bluetooth ESC/POS printing
  flutter_thermal_printer: ^0.2.1

  # State management
  provider: ^6.1.2

  # UUID generation
  uuid: ^4.4.0

  # Date formatting
  intl: ^0.19.0

  # Network connectivity check
  connectivity_plus: ^6.0.3

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

---

## 7. Module Specifications

### 7.1 `lib/db/schema.dart`

Export SQL DDL strings as constants only — no logic:

```dart
const String participantsDDL = '''
  CREATE TABLE IF NOT EXISTS participants (
    id TEXT PRIMARY KEY,
    full_name TEXT NOT NULL,
    stake TEXT, ward TEXT, gender TEXT,
    room_number TEXT, table_number TEXT,
    tshirt_size TEXT, medical_info TEXT, note TEXT, status TEXT,
    registered INTEGER DEFAULT 0,
    verified_at INTEGER, printed_at INTEGER,
    registered_by TEXT, sheets_row INTEGER NOT NULL,
    raw_json TEXT, updated_at INTEGER
  )
''';

const String syncTasksDDL = '''
  CREATE TABLE IF NOT EXISTS sync_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL, payload TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    attempts INTEGER DEFAULT 0, last_error TEXT,
    created_at INTEGER, completed_at INTEGER
  )
''';

const String appSettingsDDL = '''
  CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY, value TEXT
  )
''';
```

---

### 7.2 `lib/db/database_helper.dart`

**Purpose:** Open SQLite database and run migrations.

```dart
class DatabaseHelper {
  static const String _dbName = 'fsy_scanner.db';
  static Database? _database;

  // Returns the open database instance (opens if not yet open)
  static Future<Database> get database async { ... }

  // Runs all pending migrations in order on every app launch
  static Future<void> runMigrations(Database db) async { ... }
}
```

**Migration v1 must:**
1. Create `app_settings` table first
2. Create `participants` table
3. Create `sync_tasks` table
4. Generate UUID v4 and save to `app_settings` key `device_id`
5. Set `db_version = 1`

---

### 7.3 `lib/db/participants_dao.dart`

**Export these functions only:**

```dart
// Insert or update participant. NEVER overwrite registered=1 with registered=0.
Future<void> upsertParticipant(Database db, Participant p);

// Look up participant by id. Returns null if not found.
Future<Participant?> getParticipantById(Database db, String id);

// Mark participant as registered locally.
Future<void> markRegisteredLocally(Database db, String id, String deviceId, int verifiedAt);

// Mark participant as printed locally.
Future<void> markPrintedLocally(Database db, String id, int printedAt);

// Return all participants ordered by full_name ASC.
Future<List<Participant>> getAllParticipants(Database db);

// Search participants by name (case-insensitive). Returns up to 50 results.
Future<List<Participant>> searchParticipants(Database db, String query);

// Return count of registered participants.
Future<int> getRegisteredCount(Database db);
```

> **AI AGENT:** The upsert guard is critical. Use this exact WHERE clause:
> ```sql
> UPDATE participants SET ... WHERE id = ? AND registered = 0
> ```
> Then INSERT OR IGNORE for new rows. Never use INSERT OR REPLACE — it deletes and reinserts, losing the registered=1 guard.

---

### 7.4 `lib/db/sync_queue_dao.dart`

**Export these functions only:**

```dart
// Add new task. Returns new task id.
Future<int> enqueueTask(Database db, String type, Map<String, dynamic> payload);

// Fetch next pending task and set status to 'in_progress'. Returns null if empty.
Future<Map<String, dynamic>?> claimNextTask(Database db);

// Mark task complete and delete it.
Future<void> completeTask(Database db, int id);

// Increment attempts, store error, reset to 'pending'.
Future<void> failTask(Database db, int id, String error);

// On app start: reset all 'in_progress' tasks to 'pending'.
Future<void> resetInProgressTasks(Database db);

// Return count of pending + in_progress tasks.
Future<int> getPendingCount(Database db);
```

---

### 7.5 `lib/auth/google_auth.dart`

**Purpose:** Service Account JWT authentication. No user login. No browser.

```dart
class GoogleAuth {
  static String? _cachedToken;
  static int _expiresAt = 0;

  // Returns valid access token. Fetches new one if expired.
  // Returns null on failure — never throws to caller.
  static Future<String?> getValidToken() async { ... }
}
```

**Implementation:**

```dart
static Future<String?> getValidToken() async {
  // 1. Return cached token if still valid (60s buffer)
  if (_cachedToken != null && DateTime.now().millisecondsSinceEpoch < _expiresAt - 60000) {
    return _cachedToken;
  }

  // 2. Read credentials from .env
  final email = dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'];
  final rawKey = dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'];
  if (email == null || rawKey == null) {
    debugPrint('[GoogleAuth] Missing service account credentials in .env');
    return null;
  }

  // 3. Replace literal \n with real newlines
  final privateKey = rawKey.replaceAll(r'\n', '\n');

  try {
    // 4. Build and sign JWT using dart_jsonwebtoken RS256
    final jwt = JWT({
      'iss': email,
      'scope': 'https://www.googleapis.com/auth/spreadsheets',
      'aud': 'https://oauth2.googleapis.com/token',
      'exp': (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    final signedJwt = jwt.sign(RSAPrivateKey(privateKey), algorithm: JWTAlgorithm.RS256);

    // 5. Exchange JWT for access token
    final response = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': signedJwt,
      },
    );

    if (response.statusCode != 200) {
      debugPrint('[GoogleAuth] Token exchange failed ${response.statusCode}: ${response.body}');
      return null;
    }

    // 6. Cache and return token
    final data = jsonDecode(response.body);
    _cachedToken = data['access_token'] as String;
    _expiresAt = DateTime.now().millisecondsSinceEpoch + 3500000;
    debugPrint('[GoogleAuth] Token obtained for $email');
    return _cachedToken;
  } catch (e) {
    debugPrint('[GoogleAuth] Error: $e');
    _cachedToken = null;
    _expiresAt = 0;
    return null;
  }
}
```

---

### 7.6 `lib/sync/sheets_api.dart`

**Purpose:** Thin wrapper around Google Sheets API v4. All methods accept a token string.

```dart
// Fetch all rows. Returns raw 2D list (List<List<String>>).
Future<List<List<String>>> fetchAllRows(String token, String sheetId, String tabName);

// Detect column map from header row. Saves to app_settings.
// Throws SheetsColMapException if required write headers missing.
Future<Map<String, int>> detectColMap(Database db, String token, String sheetId, String tabName);

// Write registration data to a specific row.
Future<void> updateRegistrationRow(String token, String sheetId, String tabName,
    int sheetsRow, Map<String, int> colMap, Map<String, String> values);
```

**Error handling:**
- HTTP 401/403 → throw `SheetsAuthException`
- HTTP 429 → throw `SheetsRateLimitException`
- HTTP 5xx → throw `SheetsServerException`
- Network failure → throw `SheetsNetworkException`

**Sheets API endpoints (no SDK — use `http` package):**
```
Read:  GET https://sheets.googleapis.com/v4/spreadsheets/{id}/values/{tab}!A1:Z1000
Write: PUT https://sheets.googleapis.com/v4/spreadsheets/{id}/values/{range}?valueInputOption=RAW
Auth header: Authorization: Bearer {token}
```

---

### 7.7 `lib/sync/puller.dart`

**Purpose:** Pull changes from Sheets into local SQLite.

**Algorithm:**
```
1. Fetch all rows via sheetsApi.fetchAllRows()
2. Skip row 0 (header)
3. For each data row:
   a. Parse fields using col_map
   b. Call upsertParticipant() — registered=1 guard prevents overwrite
4. Update app_settings.last_pulled_at = DateTime.now().millisecondsSinceEpoch
```

> First launch (`last_pulled_at = 0`): pulls all ~1,000 rows — expected and correct.

---

### 7.8 `lib/sync/pusher.dart`

**Purpose:** Drain sync_tasks queue to Sheets.

**Algorithm:**
```
1. claimNextTask() — returns one task or null
2. If null: return (queue empty)
3. Parse payload JSON
4. If type = 'mark_registered':
   Write: Registered=Y, Verified At=ISO timestamp, Registered By=device_id
5. If type = 'mark_printed':
   Write: Printed At=ISO timestamp
6. On HTTP 200: completeTask(), repeat from step 1
7. On SheetsRateLimitException: failTask(), throw upward for backoff
8. On other error: failTask(), if attempts >= 10 notify AppState, continue to next task
```

---

### 7.9 `lib/sync/sync_engine.dart`

**Purpose:** Orchestrate the sync loop.

**Startup sequence (call once from `main.dart`):**

```
1. resetInProgressTasks()

2. Seed app_settings from .env if keys missing:
   sheets_id ← dotenv.env['SHEETS_ID']
   sheets_tab ← dotenv.env['SHEETS_TAB']
   event_name ← dotenv.env['EVENT_NAME']

3. If col_map empty:
   → getValidToken()
   → detectColMap() — save to app_settings
   → on SheetsColMapException: set AppState.syncError, halt sync

4. If last_pulled_at = 0: AppState.isInitialLoading = true

5. Run immediate sync tick

6. AppState.isInitialLoading = false

7. Start Timer.periodic(Duration(seconds: 15), _tick)
```

**Each tick:**
```
1. Check connectivity via connectivity_plus — if none: skip
2. getValidToken() — if null: skip tick, log error
3. puller.pull(token)
4. pusher.drainQueue(token)
5. AppState.pendingTaskCount = getPendingCount()
6. AppState.lastSyncedAt = DateTime.now()
7. On SheetsRateLimitException: double interval (max 120s)
8. On any other error: set AppState.syncError, continue loop
```

---

### 7.10 `lib/providers/app_state.dart`

```dart
class AppState extends ChangeNotifier {
  // Sync status
  int pendingTaskCount = 0;
  int failedTaskCount = 0;
  DateTime? lastSyncedAt;
  String? syncError;

  // First-run loading
  bool isInitialLoading = false;

  // Printer
  bool printerConnected = false;
  String? printerAddress;

  // Last scan result
  String? lastScanResult; // 'success' | 'already_registered' | 'not_found'

  // Setters that call notifyListeners()
  void setPendingTaskCount(int count) { pendingTaskCount = count; notifyListeners(); }
  void setInitialLoading(bool val) { isInitialLoading = val; notifyListeners(); }
  void setSyncError(String? msg) { syncError = msg; notifyListeners(); }
  void setPrinterConnected(bool val) { printerConnected = val; notifyListeners(); }
  void setPrinterAddress(String? addr) { printerAddress = addr; notifyListeners(); }
  void setLastScanResult(String? result) { lastScanResult = result; notifyListeners(); }
  void incrementFailedTaskCount() { failedTaskCount++; notifyListeners(); }
}
```

---

### 7.11 `lib/print/receipt_builder.dart`

**Purpose:** Build ESC/POS receipt for 80mm thermal printer.

**Receipt layout:**
```
================================
  FSY 2026 Tacloban and Tolosa
       CHECK-IN RECEIPT
================================
Name:  Juan dela Cruz
Room:  204
Table: 7
Shirt: M
================================
⚠ MEDICAL: Allergic to shellfish
================================
Verified: 15 Jun 2026 09:42
Device: a1b2c3d4
================================
    Welcome to FSY 2026!
================================
[PAPER CUT]
```

**Rules:**
- Event name from `app_settings.event_name`
- If `room_number` null/empty: print `Room:  (not assigned)`
- If `table_number` null/empty: print `Table: (not assigned)`
- If `tshirt_size` null/empty: omit Shirt line entirely
- If `medical_info` not empty: print warning block
- Device ID: first 8 characters only
- Print AFTER SQLite write and task enqueue — never before

---

### 7.12 `lib/print/printer_service.dart`

**Purpose:** Bluetooth printer wrapper using `flutter_thermal_printer`.

```dart
class PrinterService {
  // Scan for nearby Bluetooth printers. Returns list of discovered devices.
  static Future<List<PrinterDevice>> scanPrinters();

  // Print receipt for a participant. Fire-and-forget — never awaited by UI.
  // On success: returns true, records printed_at in SQLite, enqueues mark_printed task.
  // On failure: returns false, does NOT block registration flow.
  static Future<bool> printReceipt(Participant participant, String eventName, String deviceId);
}
```

---

### 7.13 `lib/screens/scan_screen.dart`

**Scanner screen rules:**
- Use `MobileScanner` widget from `mobile_scanner` package
- Camera preview fills full screen
- Centered scanning reticle: 260×260 square overlay
- After scan: pause scanning 2 seconds (set `controller.stop()`, resume after 2s)
- On scan: call `getParticipantById(scannedId)`
  - `null` → show SnackBar "Participant not found" — no navigation
  - `registered = 1` → show SnackBar "Already checked in — [Name] at [time]"
  - `registered = 0` → navigate to `ConfirmScreen`
- SnackBar auto-dismisses after 3 seconds
- Top-right badge: pending sync task count from AppState
- **First-run loading state:**
  - If `AppState.isInitialLoading = true`: show full-screen overlay:
    ```
    Setting up for the first time...
    Downloading participant list
    [CircularProgressIndicator]
    ```
  - If `AppState.syncError != null` during loading: show error + Retry button

---

### 7.14 `lib/screens/confirm_screen.dart`

**Confirmation flow:**
1. Display participant card: Name, Stake, Ward, Room, Table, T-Shirt Size
2. If `medical_info` not empty: show prominent yellow warning card
3. If `note` not empty: show note card
4. Two buttons: **Confirm Check-In** (primary) and **Cancel**
5. On Confirm:
   - `markRegisteredLocally()` — immediate SQLite write
   - `enqueueTask('mark_registered', payload)` — sync queue
   - `PrinterService.printReceipt()` — fire and forget (do NOT await)
   - Navigate back to scan screen
   - Show success SnackBar
6. **Entire flow from button tap to back-on-scan: under 500ms** (steps 1–4 only)
7. Cancel: navigate back, no changes

---

### 7.15 `lib/screens/settings_screen.dart`

**Two sections:**

**Section 1 — Sheet Config (pre-populated from .env, editable):**
- Sheet ID field (pre-filled from `SHEETS_ID` env)
- Tab Name field (pre-filled from `SHEETS_TAB` env)
- Event Name field (pre-filled from `EVENT_NAME` env)
- "Save & Detect Columns" button
- Shows detected column list after success
- Shows clear error if required headers missing

**Section 2 — Printer:**
- "Scan for Printers" button — calls `PrinterService.scanPrinters()`
- List of discovered printers (name + MAC address)
- Tap to select and save to `app_settings.printer_address`
- "Test Print" button
- Shows connection status

**No login button. No sign-out button. No auth UI.**

---

## 8. Implementation Phases

> **AI AGENT RULE:** Complete every task. Run every VERIFY. Append to DEVLOG.md. Only then start next task.

---

### Phase 1 — Project Setup & Database

#### Task 1.1 — Create Flutter Project

```
ACTION:
  flutter create fsy_scanner --org com.fsy.tacandtol --platforms android
  cd fsy_scanner
  Add analysis_options.yaml with strict linting

VERIFY:
  flutter run --dry-run
  Expected: No errors, project structure created
  flutter analyze
  Expected: No issues
```

#### Task 1.2 — Add Dependencies

```
ACTION:
  Add all packages from Section 6 to pubspec.yaml
  flutter pub get

VERIFY:
  flutter pub get completes with no errors
  flutter pub deps | grep -E "sqflite|mobile_scanner|dart_jsonwebtoken|flutter_thermal_printer"
  Expected: All four packages appear in dependency tree
```

#### Task 1.3 — Create Folder Structure

```
ACTION:
  Create every folder and empty file from Section 5.

VERIFY:
  find lib/ -name "*.dart" | sort
  Expected: All files from Section 5 appear
```

#### Task 1.4 — Setup .env File

```
ACTION:
  Create assets/.env with all 5 environment variables.
  Add to pubspec.yaml assets section:
    assets:
      - assets/.env
  Add assets/.env to .gitignore

VERIFY:
  cat assets/.env — confirm all 5 keys present
  cat .gitignore | grep .env — confirm gitignored
  flutter pub get — no errors
```

#### Task 1.5 — Implement SQLite Schema + Migrations

```
ACTION:
  Implement lib/db/schema.dart with exact DDL from Section 3.
  Implement lib/db/database_helper.dart with runMigrations().
  Migration v1: create tables, generate UUID, set db_version=1.

VERIFY:
  flutter analyze — zero issues
  Write a temporary test:
    Open DB, run migrations, query sqlite_master for table names.
    Expected: participants, sync_tasks, app_settings all exist
    Expected: app_settings has device_id (UUID) and db_version='1'
  Delete test after.
```

#### Task 1.6 — Implement participants_dao.dart

```
ACTION:
  Implement all 7 functions from Section 7.3.
  Critical: upsertParticipant uses WHERE registered=0 guard.

VERIFY:
  Temporary tests:
    1. upsertParticipant registered=0 → getParticipantById → confirm registered=0
    2. markRegisteredLocally → getParticipantById → confirm registered=1
    3. upsertParticipant registered=0 again → confirm registered still=1 (guard works)
  All 3 must pass. Delete tests after.
  flutter analyze — zero issues
```

#### Task 1.7 — Implement sync_queue_dao.dart

```
ACTION:
  Implement all 6 functions from Section 7.4.

VERIFY:
  Temporary tests:
    1. enqueueTask → getPendingCount → expect 1
    2. claimNextTask → status is 'in_progress'
    3. completeTask → getPendingCount → expect 0
    4. enqueueTask → manually set in_progress → resetInProgressTasks → status is 'pending'
  All 4 must pass. Delete tests after.
  flutter analyze — zero issues
```

**→ PHASE 1 COMPLETE WHEN:** All 7 tasks verified. DEVLOG updated.

---

### Phase 2 — Authentication & Sheets API

#### Task 2.1 — Implement google_auth.dart

```
ACTION:
  Implement GoogleAuth.getValidToken() per Section 7.5 exactly.
  Use dart_jsonwebtoken for RS256 signing.
  Token cached in static variables only — no SharedPreferences, no SQLite.
  Read credentials from flutter_dotenv.

VERIFY:
  Run on physical Android device (required — network call):
  flutter run

  Call getValidToken() once.
  Expected: logs show "[GoogleAuth] Token obtained for fsy-scanner-bot@..."
  Expected: returns non-null String

  Call getValidToken() again immediately.
  Expected: returns cached token — no second network call in logs

  If token fetch fails: logs show error with HTTP status.
  STOP — do not proceed to Task 2.2 until token is obtained successfully.
```

#### Task 2.2 — Implement sheets_api.dart fetchAllRows()

```
ACTION:
  Implement fetchAllRows() per Section 7.6.
  Fetch range: {tabName}!A1:Z1000
  Parse response['values'] as List<List<String>>

VERIFY:
  Call getValidToken() then fetchAllRows() on real Sheet.
  Expected: returns List with 1 header row + data rows
  Expected: first row contains 'ID', 'Name', 'Table Number', etc.
  Log row count and confirm manually.
```

#### Task 2.3 — Implement Column Map Detection

```
ACTION:
  Implement detectColMap() in sheets_api.dart.
  Required write headers: Registered, Verified At, Printed At
  Throw SheetsColMapException listing missing headers if not found.
  Save col_map JSON to app_settings.

VERIFY:
  Test with real Sheet — all required headers present.
  Expected: col_map saved with correct 0-based indices.
  Test with a Sheet missing 'Verified At'.
  Expected: SheetsColMapException thrown naming missing header.
```

#### Task 2.4 — Implement updateRegistrationRow()

```
ACTION:
  Implement updateRegistrationRow() per Section 7.6.
  Must use col_map for column positions — never hardcode.
  Support both mark_registered and mark_printed payloads.

VERIFY:
  Call updateRegistrationRow() on a test row in real Sheet.
  Expected: HTTP 200 returned.
  Open Google Sheet — confirm cells updated correctly.
```

#### Task 2.5 — Settings Screen (Sheet Config)

```
ACTION:
  Implement settings_screen.dart Sheet config section only.
  Pre-populate fields from dotenv values.
  "Save & Detect Columns" button saves and calls detectColMap().
  Show detected columns list on success.
  Show clear error on SheetsColMapException.
  NO login/logout UI.

VERIFY:
  Open settings. Fields pre-populated from .env — confirmed.
  Tap Save & Detect Columns.
  Expected: col_map saved, columns displayed.
```

**→ PHASE 2 COMPLETE WHEN:** All 5 tasks verified on physical device. DEVLOG updated.

---

### Phase 3 — Sync Engine

#### Task 3.1 — Implement puller.dart

```
ACTION:
  Implement pull() per Section 7.7.
  Call upsertParticipant() for every data row.
  Update last_pulled_at after successful pull.

VERIFY:
  Add 5 test rows to Sheet. Call pull() once.
  Expected: All 5 appear in SQLite participants table.
  Expected: last_pulled_at updated in app_settings.
```

#### Task 3.2 — Implement pusher.dart

```
ACTION:
  Implement drainQueue() per Section 7.8.
  Handle both mark_registered and mark_printed task types.
  Handle SheetsRateLimitException with backoff.
  On attempts >= 10: notify AppState.

VERIFY:
  Manually insert mark_registered task into sync_tasks.
  Call drainQueue() once.
  Expected: task deleted from sync_tasks.
  Expected: Row in Sheet shows Registered=Y, Verified At=timestamp.
```

#### Task 3.3 — Implement sync_engine.dart

```
ACTION:
  Implement full 7-step startup sequence per Section 7.9.
  Implement 15s periodic tick.
  Wire to AppState for isInitialLoading, pendingTaskCount, syncError.

VERIFY:
  FIRST RUN TEST (clear app data):
  Expected: col_map detected automatically
  Expected: isInitialLoading=true during first pull
  Expected: ~1000 participants in SQLite after first tick
  Expected: isInitialLoading=false after first tick
  Expected: scanner screen activates

  SUBSEQUENT RUN TEST (restart without clearing data):
  Expected: col_map detection skipped
  Expected: scanner ready immediately — no loading overlay

  CRASH RECOVERY:
  Manually set task to in_progress, restart app.
  Expected: task resets to pending and retries.
```

**→ PHASE 3 COMPLETE WHEN:** All 3 tasks verified on physical device. DEVLOG updated.

---

### Phase 4 — QR Scanner & Registration Flow

#### Task 4.1 — Implement scan_screen.dart

```
ACTION:
  Implement per Section 7.13.
  Use MobileScanner widget.
  Full-screen camera, 260x260 reticle overlay.
  2-second scan cooldown.
  First-run loading overlay.
  Sync status badge top-right.

VERIFY:
  Scan valid QR → confirm screen opens in < 100ms
  Scan unknown QR → SnackBar "not found" — no navigation
  Scan already-registered → SnackBar with name and time
  Scan same QR twice in < 2s → only one action fires
  First run: loading overlay shown until participants loaded
```

#### Task 4.2 — Implement confirm_screen.dart

```
ACTION:
  Implement per Section 7.14.
  Show participant card with all fields.
  Show medical_info warning if not empty.
  Show note if not empty.
  Confirm: markRegisteredLocally → enqueueTask → printReceipt (async) → navigate back.

VERIFY:
  Tap Confirm. Measure time to back-on-scan.
  Expected: < 500ms
  Expected: SQLite shows registered=1
  Expected: sync_tasks has pending mark_registered task
  Expected: Within 15s, Sheet shows Registered=Y and Verified At
```

#### Task 4.3 — Implement participants_screen.dart

```
ACTION:
  Show all participants sorted by full_name.
  Show registered badge (green/grey).
  Search bar — case-insensitive name filter.
  Total count and registered count at top.

VERIFY:
  Load with 1000 participants — no lag.
  Search — results filter correctly.
  Register participant — badge updates.
```

**→ PHASE 4 COMPLETE WHEN:** All 3 tasks verified. DEVLOG updated.

---

### Phase 5 — Bluetooth Printing

#### Task 5.1 — Implement receipt_builder.dart

```
ACTION:
  Implement per Section 7.11.
  Handle null room, table, shirt gracefully.
  Show medical warning block if not empty.

VERIFY:
  Build receipt for participant with all fields — layout matches spec.
  Build receipt with null room and table — shows "(not assigned)".
  Build receipt with medical_info — warning block shown.
```

#### Task 5.2 — Implement printer_service.dart

```
ACTION:
  Implement scanPrinters() and printReceipt() per Section 7.12.
  printReceipt() records printed_at in SQLite on success.
  printReceipt() enqueues mark_printed task on success.
  All print errors caught — never crash the app.

VERIFY:
  Pair printer in settings. Call printReceipt with test participant.
  Expected: receipt prints matching layout from Section 7.11.
  Turn printer off. Call printReceipt.
  Expected: returns false, error logged — registration NOT affected.
```

#### Task 5.3 — Printer Settings UI

```
ACTION:
  Add printer section to settings_screen.dart.
  Scan button calls PrinterService.scanPrinters().
  Show discovered devices list.
  Tap to save address to app_settings.
  Test Print button.

VERIFY:
  Scan finds printer. Tap to select.
  Expected: address saved to app_settings.
  Tap Test Print — receipt prints.
  Restart app — saved printer address pre-loaded.
```

**→ PHASE 5 COMPLETE WHEN:** All 3 tasks verified. DEVLOG updated.

---

### Phase 6 — Polish & Edge Cases

- **Task 6.1** — Offline banner: show yellow banner when no connectivity. Scanner still works.
- **Task 6.2** — Failed tasks alert: red badge on Settings tab if `failedTaskCount > 0`.
- **Task 6.3** — Manual sync button in settings.
- **Task 6.4** — Dark mode support via `Theme.of(context).brightness`.
- **Task 6.5** — Loading skeleton on participant list while SQLite loads.

```
VERIFY ALL:
  Each feature works without crashing.
  flutter analyze — zero issues.
  DEVLOG updated for each.
```

---

## 9. QR Code Format

**Payload:** Plain UTF-8 string. No JSON. No URL. No prefix. No suffix.

**Example:** `FSY2026-001`

The app does: `SELECT * FROM participants WHERE id = ?`

Any mismatch (extra space, different case) = "Not Found".

---

## 10. Google Sheets Setup

### 10.1 Sheet Structure

Row 1 header (exact, case-sensitive):
```
ID | QR Code | Stake | Ward | Name | Gender | Registered | Signed by | Status |
Medical/Food Info | Note | T-Shirt Size | Table Number | Hotel Room Number |
Verified At | Printed At
```

- Data starts row 2
- `Registered`, `Verified At`, `Printed At` start empty — app writes them

### 10.2 Service Account Setup

1. Google Cloud Console → `FSY Scanner 2026` project
2. IAM & Admin → Service Accounts → `fsy-scanner-bot`
3. Share Google Sheet with `fsy-scanner-bot@fsy-scanner-2026.iam.gserviceaccount.com` as **Editor**
4. Credentials stored in `assets/.env` — never committed to git

### 10.3 Android Permissions Required

In `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.BLUETOOTH"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

---

## 11. Testing Checklist

### 11.1 Sync Engine
- [ ] Kill app mid-sync → restart → pending tasks retry and complete
- [ ] Disconnect WiFi → scan → reconnect → Sheet updated within 15s
- [ ] 429 rate limit → interval doubles, no API spam
- [ ] Two devices register different participants → both in Sheet within 30s
- [ ] Device A registers participant X → Device B scans X → "Already checked in"

### 11.2 Scanner
- [ ] Valid QR → confirm screen < 100ms
- [ ] Unknown QR → not found SnackBar, no crash
- [ ] Already registered → SnackBar with name and time
- [ ] Double scan < 2s → only one action

### 11.3 Printing
- [ ] Paired printer → receipt prints with all fields correct
- [ ] Printer off → check-in completes, error logged
- [ ] Printer reconnects → next registration prints
- [ ] `Printed At` written to Sheet after successful print

### 11.4 Multi-Device
- [ ] 2 devices scan simultaneously → SQLite converges within 30s
- [ ] One device offline → scan + print work → syncs on reconnect
- [ ] Same participant scanned on two devices → one registration recorded

### 11.5 Data Integrity
- [ ] 1,000 participants → full pull → all in SQLite → list renders without lag
- [ ] Pull when local participant registered → registered stays 1

### 11.6 First Run
- [ ] Fresh install → loading overlay → col_map detected → participants load → scanner activates
- [ ] Restart → scanner ready immediately, no loading overlay
- [ ] Missing Sheet header → error shown listing missing column

---

## 12. DEVLOG Format

> **AI AGENT:** Create `DEVLOG.md` at project root on Task 1.1. This is a fresh Flutter project — no React Native history. Append after every task.

### 12.1 File Header

```markdown
# FSY Scanner App — Development Log (Flutter)
Project: FSY Check-In Scanner — Flutter Rebuild
Plan Version: 1.0
Branch: main
Started: [DATE]
AI Agent: [Your name/model]
Note: Fresh start — no React Native code. All Dart.

---
```

### 12.2 Entry Format

```markdown
## [PHASE].[TASK] — [Task Name]
**Date/Time:** [timestamp]
**Status:** ✅ Complete | ⚠️ Complete with notes | ❌ Failed

### What I Did
[Exact description — which functions, which files, what logic]

### How I Followed the Plan
[Quote the specific plan rule followed]

### Verification Result
[Paste the VERIFY check and its result]

### Issues Encountered
[None. / Problem + resolution]

### Corrections Made
[None. / What was wrong and what changed]

### Deviations from Plan
[None — followed plan exactly. / State deviation and justification]

---
```

### 12.3 Phase Summary

```markdown
## PHASE [N] SUMMARY
**Completed:** [DATE]
**Tasks completed:** [N]/[N]
**Issues:** [summary or "None"]
**Ready for Phase [N+1]:** ✅ Yes | ❌ No (reason)

---
```

---

## 13. Known Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Sheets API rate limit (100 req/100sec) | Medium | 15s interval + exponential backoff on 429 |
| Two devices register same participant simultaneously | Low | Local registered=1 guard + puller convergence within 15s |
| Bluetooth printer disconnects mid-event | Medium | Non-blocking print, manual reconnect in settings, mark_printed only on success |
| Hotel WiFi instability | Low–Medium | Local-first — scanning works offline, queue drains on reconnect |
| Service account token exchange fails | Low | Silent retry on next tick, error shown in sync badge |
| Sheet column headers renamed before event | Medium | Col_map auto-detection with clear error message listing missing headers |
| room_number or table_number null at event | Possible | Show "(not assigned)" on receipt and confirm screen |
| dart_jsonwebtoken RS256 incompatibility | Low | Tested in Task 2.1 before any other phase — blocker caught early |

---

## 14. Hard Constraints

| # | Constraint | Reason |
|---|---|---|
| 1 | No backend server | SDC requirement |
| 2 | All QR lookups from local SQLite only | Scanning must be instant |
| 3 | Sync tasks never deleted until Sheets HTTP 200 | Prevents data loss |
| 4 | Never overwrite registered=1 with 0 from any source | Race condition prevention |
| 5 | Print is fire-and-forget — registration never waits on print | Print failure must not block check-in |
| 6 | Column positions always from col_map — never hardcoded | Column order varies |
| 7 | DEVLOG.md is append-only | Audit trail |
| 8 | Never guess column names — throw SheetsColMapException | Data integrity |
| 9 | flutter analyze must pass with zero issues after every task | Code quality |
| 10 | assets/.env is never committed to git | Security |

---

*End of FSY Scanner Flutter Plan v1.0*
*For questions or amendments, contact Jayson before proceeding.*