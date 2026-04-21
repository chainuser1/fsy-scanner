# FSY Check-In Scanner App — AI Coder Project Plan
**Version:** 1.1  
**Prepared by:** Jayson (ML Engineer · Dagami Ward FSY Organizer)  
**For:** AI Coders — Cursor, Copilot, Trae SOLO  
**Status:** Active — Follow exactly as written

---

## ⚠️ CRITICAL AI CODER RULES — READ FIRST, FOLLOW ALWAYS

These rules apply to every single task in this document. There are no exceptions.

1. **DO NOT hallucinate APIs, libraries, or file paths.** If you are not 100% certain a function, method, or module exists in the specified version, stop and say so. Do not invent alternatives silently.
2. **DO NOT proceed to the next task until the current task passes its verification check.** Every task has a `VERIFY:` line. Run it. If it fails, fix it before moving on.
3. **DO NOT rename files, folders, or database columns** from what is specified in this document. Names are contracts between modules.
4. **DO NOT install alternative libraries** to those listed in Section 6. If a listed library has a breaking issue, stop and report it — do not silently substitute.
5. **DO NOT hardcode column letters or positions** for Google Sheets. Always read from `app_settings.col_map`.
6. **After completing each task**, append an entry to `DEVLOG.md` (see Section 12 for format). This is mandatory, not optional.
7. **Before writing any code for a task**, re-read the full task specification including its constraints and verification. Then write the code. Then verify. Then log.
8. **If anything in this plan is ambiguous**, stop and ask. Do not guess.
9. **Never overwrite `DEVLOG.md` — always append to it.**
10. **Think step by step.** Before writing any function, write a one-line comment describing what it does. If you cannot describe it in one line, break it into smaller functions.

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

## 1. Project Overview

### 1.1 What This App Does

This is a **mobile check-in scanner app** for FSY (For the Strength of Youth) events. It:

- Scans a participant's QR code at check-in stations
- Instantly confirms registration from a **local SQLite database** (fast, no network wait)
- Marks the participant as registered in **Google Sheets** in the background
- Prints a receipt to a **paired Bluetooth thermal printer** (name, room number, table number)
- Supports **multiple devices and printers simultaneously** with no central server

### 1.2 Scale

- ~1,000 participants
- Multiple scanning devices operating simultaneously
- One Bluetooth thermal printer paired per device
- Event runs in a hotel with strong WiFi

### 1.3 Core Design Principles

| Principle | What It Means in Code |
|---|---|
| **Local-First** | All reads hit SQLite. Network is background-only. Never block the UI on a network call. |
| **Resilient Sync Queue** | Sync tasks are written to SQLite and survive app crashes. Only deleted after Sheets confirms HTTP 200. |
| **No Backend Server** | Devices talk directly to Google Sheets API only. No Fastify, no Express, no intermediary server. |
| **One Printer Per Device** | Each phone pairs its own Bluetooth printer. Print calls are fire-and-forget. |
| **Idempotent Writes** | Registering the same participant twice must be safe. Both SQLite and Sheets must guard against duplicate registration. |

---

## 2. System Architecture

### 2.1 Data Flow

```
READ PATH (must be < 50ms):
  QR Scan → SQLite lookup → UI confirmation → Bluetooth print

WRITE PATH (background, non-blocking):
  SQLite write (immediate) → enqueue sync_task → background worker → Sheets API → task marked complete + deleted
```

### 2.2 Component Map

```
┌─────────────────────────────────────────────────────┐
│                   Google Sheets                     │
│          (remote source of truth — background)      │
└──────────────────────┬──────────────────────────────┘
                       │  Sheets API v4 (fetch only)
                       │  Pull deltas every 15s
                       │  Push registrations from queue
┌──────────────────────▼──────────────────────────────┐
│              Local SQLite Database                  │
│    participants | sync_tasks | app_settings         │
│         (source of truth FOR THE APP)               │
└──────┬───────────────────────────┬──────────────────┘
       │                           │
┌──────▼──────┐           ┌────────▼────────┐
│ QR Scanner  │           │  Sync Engine    │
│  (instant)  │           │  (background)   │
└──────┬──────┘           └─────────────────┘
       │
┌──────▼──────┐
│  BT Printer │
│ (fire+forget│
└─────────────┘
```

### 2.3 Multi-Device Strategy

- Each device has its own SQLite database and its own Bluetooth printer.
- Devices do NOT talk to each other directly.
- Convergence happens through Google Sheets: Device A writes a registration → Sheets → Device B's puller reads it on next tick.
- Duplicate registration of the same participant is handled by: (a) local SQLite check before registering, and (b) puller never overwriting `registered = 1` with `registered = 0`.

---

## 3. SQLite Schema

> **AI CODER:** These are the exact table definitions. Do not add columns, rename columns, or change types without explicit approval. Any schema change requires a migration — do not modify `schema.ts` directly after first run.

### 3.1 Table: `participants`

```sql
CREATE TABLE IF NOT EXISTS participants (
  id              TEXT PRIMARY KEY,     -- exact value encoded in QR code
  full_name       TEXT NOT NULL,        -- participant full name
  room_number     TEXT,                 -- hotel room number (may be null if not yet assigned)
  table_number    TEXT,                 -- table number (may be null if not yet assigned)
  registered      INTEGER DEFAULT 0,   -- 0 = not checked in, 1 = checked in
  registered_at   INTEGER,             -- Unix timestamp in milliseconds (Date.now())
  registered_by   TEXT,                -- device_id of the scanner that checked them in
  sheets_row      INTEGER NOT NULL,    -- 1-based row index in Google Sheets (row 1 = header, so first participant = row 2)
  raw_json        TEXT,                -- full row as JSON string (for debugging)
  updated_at      INTEGER              -- timestamp of last local modification
);
```

### 3.2 Table: `sync_tasks`

```sql
CREATE TABLE IF NOT EXISTS sync_tasks (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  type          TEXT NOT NULL,          -- only valid values: "mark_registered" | "pull_delta"
  payload       TEXT NOT NULL,          -- JSON string — schema depends on type (see Section 7.3)
  status        TEXT DEFAULT 'pending', -- only valid values: "pending" | "in_progress" | "complete"
  attempts      INTEGER DEFAULT 0,      -- number of times this task has been attempted
  last_error    TEXT,                   -- error message from last failed attempt (nullable)
  created_at    INTEGER,                -- Unix timestamp ms
  completed_at  INTEGER                 -- Unix timestamp ms — set when status = "complete"
);
```

### 3.3 Table: `app_settings`

```sql
CREATE TABLE IF NOT EXISTS app_settings (
  key   TEXT PRIMARY KEY,
  value TEXT
);
```

**Required keys and their value formats:**

| Key | Value Format | Example |
|---|---|---|
| `device_id` | UUID v4 string | `"a1b2c3d4-..."` |
| `sheets_id` | Google Sheets document ID string | `"1BxiMVs0XRA..."` |
| `sheets_tab` | Tab/sheet name string | `"Participants"` |
| `last_pulled_at` | Unix timestamp ms as string | `"1718000000000"` |
| `printer_address` | Bluetooth MAC address string | `"00:11:22:33:44:55"` |
| `col_map` | JSON string of header→column-index map | `"{\"id\":0,\"full_name\":1,...}"` |
| `event_name` | String shown on receipt header | `"FSY 2026 Leyte"` |
| `sync_interval_ms` | Number as string (default 15000) | `"15000"` |

### 3.4 Migration Strategy

- `migrations.ts` runs on every app launch.
- Each migration is numbered (`v1`, `v2`, etc.) and gated by a version check in `app_settings`.
- Migrations only run forward — never roll back.
- If a migration fails, log the error and crash with a clear message. Do not silently continue with a broken schema.

---

## 4. Google Sheets Contract

### 4.1 Minimum Required Columns

The registration team has confirmed these 4 columns. Additional columns may be added. The app must handle extra columns gracefully (ignore them).

| Logical Field | Expected Header Text | SQLite Field | Notes |
|---|---|---|---|
| Participant ID | `ID` | `id` | Must exactly match QR code payload |
| Full Name | `Name` | `full_name` | Printed on receipt |
| Table Number | `Table Number` | `table_number` | Printed on receipt — may be empty |
| Hotel Room Number | `Hotel Room Number` | `room_number` | Printed on receipt — may be empty |
| Registered | `Registered` | `registered` | App writes `Y` here — add this column if not present |
| Registered At | `Registered At` | `registered_at` | App writes ISO 8601 timestamp |
| Registered By | `Registered By` | `registered_by` | App writes device_id |

> **AI CODER:** The app must auto-detect column positions from row 1 (header row) on first sync. Never hardcode column letters like `A`, `B`, `C`. Always read from `app_settings.col_map`. If a required header is missing from Sheets, alert the user and halt sync — do not guess which column to use.

### 4.2 Column Map Detection

On first launch (or when `col_map` is empty in `app_settings`):

1. Fetch row 1 of the configured sheet tab
2. Build a map: `{ header_text: column_index }` (0-based)
3. Verify all required headers are present
4. If any required header is missing: show error screen listing missing headers, halt sync
5. Save map as JSON to `app_settings` key `col_map`

---

## 5. Folder Structure

> **AI CODER:** This is the exact folder and file structure. Create every file at exactly this path. Do not reorganize. Do not rename.

```
fsy-scanner/
├── app/                              # Expo Router screens
│   ├── (tabs)/
│   │   ├── scan.tsx                  # Main QR scanner screen (default tab)
│   │   ├── participants.tsx          # Searchable participant list
│   │   └── settings.tsx             # Printer pairing, Sheets config, manual sync
│   ├── confirm/
│   │   └── [id].tsx                  # Registration confirmation screen
│   └── _layout.tsx                   # Root layout with tab navigator
│
├── src/
│   ├── db/
│   │   ├── schema.ts                 # SQL DDL strings only — no logic
│   │   ├── migrations.ts             # Version-gated migration runner
│   │   ├── participants.ts           # CRUD operations for participants table
│   │   └── syncQueue.ts             # CRUD operations for sync_tasks table
│   │
│   ├── sync/
│   │   ├── engine.ts                 # Sync loop orchestrator — runs puller then pusher
│   │   ├── sheetsApi.ts             # Google Sheets API v4 fetch wrapper
│   │   ├── puller.ts                 # Delta pull: Sheets → SQLite
│   │   └── pusher.ts                 # Queue drain: SQLite sync_tasks → Sheets
│   │
│   ├── print/
│   │   ├── printer.ts               # BT printer connect/disconnect/reconnect
│   │   └── receipt.ts               # ESC/POS receipt byte builder
│   │
│   ├── auth/
│   │   └── google.ts                # Google OAuth 2.0 via expo-auth-session
│   │
│   ├── store/
│   │   └── useAppStore.ts           # Zustand global state
│   │
│   ├── hooks/
│   │   ├── useScanner.ts            # Camera + barcode decode hook
│   │   └── useSyncStatus.ts         # Pending task count, last sync time
│   │
│   └── utils/
│       ├── deviceId.ts              # Generate and persist stable device UUID
│       └── time.ts                  # Timestamp helpers (now(), formatDisplay())
│
├── assets/                           # Icons, splash screens
├── DEVLOG.md                         # AI coder execution log — append only, never overwrite
├── app.json
├── tsconfig.json                     # Must have strict: true
└── package.json
```

---

## 6. Dependencies

> **AI CODER:** Install exactly these packages at exactly these versions. Use `npx expo install` for Expo-managed packages (it pins compatible versions automatically). Do not substitute libraries.

### 6.1 Expo-Managed Packages (use `npx expo install`)

```
expo-sqlite
expo-camera
expo-barcode-scanner
expo-auth-session
expo-secure-store
expo-network
expo-crypto
```

### 6.2 npm Packages (use `npm install`)

```
zustand@^4.5.0
react-native-thermal-receipt-printer-image-qr@^1.2.0
date-fns@^3.6.0
@react-native-async-storage/async-storage@^1.23.0
```

### 6.3 Google Sheets API — No SDK

Do **not** install any Google API client library. Use `fetch()` directly.

```
Base URL: https://sheets.googleapis.com/v4/spreadsheets

Read rows:
  GET {base}/{sheetId}/values/{tabName}!A1:Z1000
  Header: Authorization: Bearer {access_token}

Update a cell range:
  PUT {base}/{sheetId}/values/{tabName}!{range}?valueInputOption=RAW
  Header: Authorization: Bearer {access_token}
  Body: { "range": "...", "majorDimension": "ROWS", "values": [[...]] }
```

### 6.4 Build Requirement

> **AI CODER:** This project cannot run in Expo Go. It requires native modules (Bluetooth printing, camera). Always use a **development build**:

```bash
npx expo prebuild
npx expo run:android   # or run:ios
```

---

## 7. Module Specifications

### 7.1 `src/db/schema.ts`

- Export the 3 SQL DDL strings as named constants: `PARTICIPANTS_DDL`, `SYNC_TASKS_DDL`, `APP_SETTINGS_DDL`
- No logic, no functions — only string constants
- These strings are imported by `migrations.ts`

---

### 7.2 `src/db/migrations.ts`

**Purpose:** Run database migrations on every app launch in order.

**Algorithm:**
1. Open SQLite database named `fsy_scanner.db`
2. Read current `db_version` from `app_settings` (default to `0` if not found)
3. Run all migrations where migration version > current version, in order
4. After each migration succeeds, update `db_version` in `app_settings`
5. If any migration throws, log the error and rethrow — do not swallow errors

**Migration v1 must:**
- Create `app_settings` table first (other migrations may need it)
- Create `participants` table
- Create `sync_tasks` table
- Set `db_version = 1`
- Set `device_id` to a new UUID v4 (using `src/utils/deviceId.ts`) if not already set

---

### 7.3 `src/db/syncQueue.ts`

Export these functions. No others.

```typescript
// Add a new task to the queue. Returns the new task id.
enqueueTask(type: 'mark_registered' | 'pull_delta', payload: object): Promise<number>

// Fetch the next pending task and set its status to 'in_progress'. Returns null if queue is empty.
claimNextTask(): Promise<SyncTask | null>

// Mark a task as complete and delete it from the table.
completeTask(id: number): Promise<void>

// Increment attempts and reset status to 'pending'. Store error message.
failTask(id: number, error: string): Promise<void>

// On app start: reset any 'in_progress' tasks back to 'pending'.
resetInProgressTasks(): Promise<void>

// Return count of tasks with status = 'pending' or 'in_progress'.
getPendingCount(): Promise<number>
```

**Payload schemas by type:**

```typescript
// type: 'mark_registered'
{
  participantId: string,   // matches participants.id
  sheetsRow: number,       // 1-based row index
  registeredAt: number,    // Unix ms timestamp
  registeredBy: string     // device_id
}
```

---

### 7.4 `src/db/participants.ts`

Export these functions. No others.

```typescript
// Insert or update a participant row from Sheets data. Never overwrite registered=1 with registered=0.
upsertParticipant(data: ParticipantRow): Promise<void>

// Look up a participant by id. Returns null if not found.
getParticipantById(id: string): Promise<Participant | null>

// Mark a participant as registered locally. Sets registered=1, registered_at, registered_by, updated_at.
markRegisteredLocally(id: string, deviceId: string): Promise<void>

// Return all participants, ordered by full_name ASC.
getAllParticipants(): Promise<Participant[]>

// Search participants by name (case-insensitive LIKE). Returns up to 50 results.
searchParticipants(query: string): Promise<Participant[]>

// Return count of registered participants.
getRegisteredCount(): Promise<number>
```

> **AI CODER:** The upsert rule is critical: if `registered = 1` already exists in SQLite, never set it to `0` regardless of what comes from Sheets. Add an explicit `WHERE registered = 0` guard on the registered field update.

---

### 7.5 `src/sync/sheetsApi.ts`

**Purpose:** Thin wrapper around Google Sheets API v4. All functions accept an `accessToken` parameter.

```typescript
// Fetch all rows from the sheet. Returns raw 2D array (string[][]).
fetchAllRows(accessToken: string, sheetId: string, tabName: string): Promise<string[][]>

// Update a single row's registration columns (Registered, Registered At, Registered By).
// Uses the column positions from col_map in app_settings.
updateRegistrationRow(
  accessToken: string,
  sheetId: string,
  tabName: string,
  sheetsRow: number,       // 1-based
  colMap: ColMap,
  values: { registeredAt: string, registeredBy: string }
): Promise<void>
```

**Error handling rules:**
- HTTP 401 → throw `AuthExpiredError` (caller will re-auth)
- HTTP 429 → throw `RateLimitError` (caller will backoff)
- HTTP 5xx → throw `SheetsServerError` (caller will retry)
- Network failure → throw `NetworkError` (caller will skip tick)

---

### 7.6 `src/sync/puller.ts`

**Purpose:** Pull remote changes from Sheets into local SQLite.

**Full algorithm:**

```
1. Fetch all rows from Sheets via sheetsApi.fetchAllRows()
2. Skip row 0 (header row)
3. For each data row:
   a. Parse fields using col_map from app_settings
   b. Call participants.upsertParticipant() — upsert guard handles registered conflict
4. Update app_settings.last_pulled_at to Date.now()
```

> **AI CODER:** On first launch (`last_pulled_at = 0`), this pulls all ~1,000 rows. This is intentional and expected. Do not paginate or limit the initial pull.

---

### 7.7 `src/sync/pusher.ts`

**Purpose:** Drain the sync_tasks queue by writing pending registrations to Sheets.

**Full algorithm:**

```
1. Call syncQueue.claimNextTask() — returns one task or null
2. If null: return (queue is empty)
3. Parse task.payload as JSON
4. Call sheetsApi.updateRegistrationRow() with payload values
5. On success (HTTP 200):
   a. Call syncQueue.completeTask(task.id)
   b. Repeat from step 1 (drain next task in same tick)
6. On RateLimitError:
   a. Call syncQueue.failTask(task.id, error.message)
   b. Throw RateLimitError upward so engine can backoff
7. On any other error:
   a. Call syncQueue.failTask(task.id, error.message)
   b. If task.attempts >= 10: update Zustand store failedTaskCount
   c. Continue to next task (do not stop the whole queue for one failed task)
```

---

### 7.8 `src/sync/engine.ts`

**Purpose:** Orchestrate the sync loop.

**Startup sequence (call once on app launch):**
1. Call `syncQueue.resetInProgressTasks()`
2. Run one immediate sync tick
3. Start interval (`sync_interval_ms` from settings, default 15000)

**Each tick:**
1. Check network availability via `expo-network`. If offline, skip and log.
2. Get valid access token (refresh if expired via `src/auth/google.ts`)
3. Call `puller.pull()`
4. Call `pusher.drainQueue()`
5. On `RateLimitError`: clear current interval, restart with doubled interval (max 120000ms)
6. On `AuthExpiredError`: trigger re-auth flow via Zustand store flag
7. On any other error: log it, continue (do not crash the loop)

---

### 7.9 `src/auth/google.ts`

**Purpose:** Google OAuth 2.0 using `expo-auth-session`.

- Scopes required: `https://www.googleapis.com/auth/spreadsheets`
- Store access token and refresh token in `expo-secure-store`
- Implement `getValidToken()`: returns access token, refreshing silently if expired
- Implement `signIn()`: launches OAuth browser flow
- Implement `signOut()`: clears stored tokens

---

### 7.10 `src/store/useAppStore.ts`

**Zustand store shape:**

```typescript
{
  // Auth
  isAuthenticated: boolean,
  setAuthenticated: (val: boolean) => void,

  // Sync status
  pendingTaskCount: number,
  setPendingTaskCount: (count: number) => void,
  failedTaskCount: number,
  incrementFailedTaskCount: () => void,
  lastSyncedAt: number | null,
  setLastSyncedAt: (ts: number) => void,
  needsReAuth: boolean,
  setNeedsReAuth: (val: boolean) => void,

  // Printer
  printerConnected: boolean,
  setPrinterConnected: (val: boolean) => void,
  printerAddress: string | null,
  setPrinterAddress: (addr: string) => void,

  // Last scan result (for UI feedback)
  lastScanResult: 'success' | 'already_registered' | 'not_found' | null,
  setLastScanResult: (result: ...) => void,
}
```

---

### 7.11 `src/print/receipt.ts`

**Purpose:** Build ESC/POS byte commands for the receipt.

**Receipt layout (80mm paper, ~48 chars wide):**

```
================================
      FSY 2026 Leyte
      CHECK-IN RECEIPT
================================
Name:  Juan dela Cruz
Room:  204
Table: 7
================================
Checked in: 15 Jun 2026 09:42
Device: [device_id short form]
================================
    Welcome to FSY 2026!
================================
[FULL CUT]
```

**Rules:**
- Event name comes from `app_settings.event_name`
- If `room_number` is null/empty: print `Room:  (not assigned)`
- If `table_number` is null/empty: print `Table: (not assigned)`
- Device ID on receipt: first 8 characters only
- Print is triggered after SQLite write and sync task enqueue — never before

---

### 7.12 `app/(tabs)/scan.tsx`

**Scanner screen rules:**

- Camera preview fills the full screen
- Scanning reticle: centered square overlay, 260×260px
- After successful scan: pause camera for 2 seconds (prevent double-scan)
- After 2 seconds: automatically resume camera
- On scan: call `participants.getParticipantById(scannedId)`
  - If `null`: show toast "Participant not found" — do NOT navigate
  - If `registered = 1`: show toast "Already checked in — [Name] at [time]" — do NOT navigate
  - If `registered = 0`: navigate to `confirm/[id]`
- Toast messages auto-dismiss after 3 seconds
- Show sync status badge in top-right corner (pending task count from Zustand)

---

### 7.13 `app/confirm/[id].tsx`

**Confirmation screen rules:**

- Display participant card: Name, Room, Table
- Show two buttons: "Confirm Check-In" (primary) and "Cancel" (secondary)
- On "Confirm Check-In":
  1. Call `participants.markRegisteredLocally(id, deviceId)` — this is synchronous from UI perspective
  2. Call `syncQueue.enqueueTask('mark_registered', payload)`
  3. Call `printer.printReceipt(participant)` — fire and forget, do not await in UI thread
  4. Navigate back to scan screen
  5. Show success toast "Checked in: [Name]"
- Entire flow from button tap to back-on-scan: **must complete in under 500ms** (steps 1–4 only; print is async)
- On "Cancel": navigate back to scan screen, no changes

---

## 8. Implementation Phases

> **AI CODER RULE:** Complete every task in a phase. Run every `VERIFY` check. Append to `DEVLOG.md`. Only then start the next phase. Do not skip tasks. Do not merge phases.

---

### Phase 1 — Bootstrap & Database

**Goal:** Project runs, SQLite schema is created, basic CRUD works.

#### Task 1.1 — Initialize Expo Project

```
ACTION:
  npx create-expo-app fsy-scanner --template expo-template-blank-typescript
  cd fsy-scanner

VERIFY:
  npx expo start
  Expected: Metro bundler starts with no errors
```

#### Task 1.2 — Install All Dependencies

```
ACTION:
  npx expo install expo-sqlite expo-camera expo-barcode-scanner \
    expo-auth-session expo-secure-store expo-network expo-crypto

  npm install zustand@^4.5.0 \
    react-native-thermal-receipt-printer-image-qr@^1.2.0 \
    date-fns@^3.6.0 \
    @react-native-async-storage/async-storage@^1.23.0

VERIFY:
  npm ls --depth=0
  Expected: All packages listed above appear with no peer dependency errors
  
  Check package.json — confirm versions match Section 6
```

#### Task 1.3 — Enable TypeScript Strict Mode

```
ACTION:
  In tsconfig.json set:
    "strict": true
    "noImplicitAny": true
    "strictNullChecks": true

VERIFY:
  npx tsc --noEmit
  Expected: Zero errors (project is empty so this should pass)
```

#### Task 1.4 — Create Folder Structure

```
ACTION:
  Create every folder and empty file listed in Section 5.
  Files can be empty stubs (just export a placeholder).

VERIFY:
  Manually confirm every path in Section 5 exists.
  Run: find . -type f -name "*.ts" -o -name "*.tsx" | sort
  Expected: All files from Section 5 appear in output
```

#### Task 1.5 — Implement SQLite Schema

```
ACTION:
  Implement src/db/schema.ts with exactly the DDL from Section 3.
  Export: PARTICIPANTS_DDL, SYNC_TASKS_DDL, APP_SETTINGS_DDL

VERIFY:
  npx tsc --noEmit
  Expected: No errors
  Code review: Confirm column names match Section 3 exactly — diff against spec
```

#### Task 1.6 — Implement Migrations

```
ACTION:
  Implement src/db/migrations.ts per Section 7.2.
  Migration v1: create all 3 tables, set device_id UUID, set db_version=1.

VERIFY:
  Write a temporary test: call runMigrations() then query sqlite_master for table names.
  Expected: participants, sync_tasks, app_settings all exist
  Expected: app_settings contains device_id (non-null UUID) and db_version = '1'
  Delete the test after verification.
```

#### Task 1.7 — Implement participants.ts CRUD

```
ACTION:
  Implement all 6 functions from Section 7.4.
  Pay special attention to upsertParticipant — enforce registered=1 never overwritten.

VERIFY:
  Write temporary tests:
    1. upsertParticipant with registered=0 → getParticipantById → confirm registered=0
    2. markRegisteredLocally → getParticipantById → confirm registered=1
    3. upsertParticipant with registered=0 again → confirm registered is still 1 (the guard works)
  All 3 must pass. Delete tests after.
```

#### Task 1.8 — Implement syncQueue.ts CRUD

```
ACTION:
  Implement all 6 functions from Section 7.3.

VERIFY:
  Write temporary tests:
    1. enqueueTask → getPendingCount → expect 1
    2. claimNextTask → check status is 'in_progress'
    3. completeTask → getPendingCount → expect 0
    4. enqueueTask → set status to 'in_progress' manually → resetInProgressTasks → check status is 'pending'
  All 4 must pass. Delete tests after.
```

#### Task 1.9 — Implement deviceId.ts

```
ACTION:
  Implement src/utils/deviceId.ts.
  On first call: generate UUID v4 using expo-crypto, store in app_settings, return it.
  On subsequent calls: read from app_settings, return cached value.

VERIFY:
  Call getDeviceId() twice. Confirm both calls return the same string.
  Expected: stable UUID like "a1b2c3d4-e5f6-..."
```

**→ PHASE 1 COMPLETE WHEN:** All 9 tasks verified. DEVLOG updated.

---

### Phase 2 — Google Auth & Sheets API

**Goal:** App can authenticate to Google and read/write the Sheet.

#### Task 2.1 — Implement Google OAuth

```
ACTION:
  Implement src/auth/google.ts per Section 7.9.
  Required scope: https://www.googleapis.com/auth/spreadsheets
  Store tokens in expo-secure-store.

VERIFY:
  Run on device. Tap sign-in. Complete OAuth flow in browser.
  Expected: access token is returned and stored
  Expected: calling getValidToken() returns a non-null string
```

#### Task 2.2 — Implement sheetsApi.fetchAllRows()

```
ACTION:
  Implement fetchAllRows() in src/sync/sheetsApi.ts.
  Fetch range: {tabName}!A1:Z1000 (covers up to 26 columns, 1000 rows)
  Parse response.values (string[][])

VERIFY:
  Call fetchAllRows() with a real test sheet containing 3 rows.
  Expected: returns array of 4 items (1 header + 3 data rows)
  Expected: each item is a string array matching sheet content
  Log the result and confirm manually.
```

#### Task 2.3 — Implement Column Map Detection

```
ACTION:
  Implement in sheetsApi.ts or puller.ts (your choice — be consistent).
  Read row 0 from fetchAllRows result.
  Build col_map: { 'ID': 0, 'Name': 1, 'Table Number': 2, ... }
  Required headers (Section 4.1): ID, Name, Table Number, Hotel Room Number
  If any required header is missing: throw ColMapError listing which headers are missing
  Save col_map JSON to app_settings.

VERIFY:
  Test with a sheet that has all required headers → col_map saved correctly
  Test with a sheet missing 'Table Number' → ColMapError thrown with message naming the missing header
```

#### Task 2.4 — Implement sheetsApi.updateRegistrationRow()

```
ACTION:
  Implement updateRegistrationRow() in src/sync/sheetsApi.ts per Section 7.5.
  Must use col_map to determine which columns to write — never hardcode column letters.
  Write to: Registered = 'Y', Registered At = ISO string, Registered By = device_id

VERIFY:
  Call updateRegistrationRow() on a test row in a real sheet.
  Expected: HTTP 200 returned
  Expected: Open Google Sheets — the 3 cells are updated correctly
```

#### Task 2.5 — Settings Screen (Sheet Config)

```
ACTION:
  Implement app/(tabs)/settings.tsx.
  Fields: Sheet ID (text input), Tab Name (text input), Event Name (text input)
  Button: Save & Sync — saves to app_settings and triggers column map detection

VERIFY:
  Enter a Sheet ID and Tab Name. Tap Save & Sync.
  Expected: col_map is saved to app_settings
  Expected: No crash, success confirmation shown
```

**→ PHASE 2 COMPLETE WHEN:** All 5 tasks verified. DEVLOG updated.

---

### Phase 3 — Sync Engine

**Goal:** App automatically pulls from Sheets and pushes registrations in the background.

#### Task 3.1 — Implement puller.ts

```
ACTION:
  Implement pull() in src/sync/puller.ts per Section 7.6.
  Must call upsertParticipant() for every data row.
  Must update last_pulled_at after successful pull.

VERIFY:
  Add 5 test rows to Sheets. Call pull() once.
  Expected: All 5 rows appear in SQLite participants table
  Expected: app_settings.last_pulled_at is updated to current timestamp
```

#### Task 3.2 — Implement pusher.ts

```
ACTION:
  Implement drainQueue() in src/sync/pusher.ts per Section 7.7.
  Must process tasks one at a time.
  Must handle RateLimitError, AuthExpiredError, and generic errors per spec.

VERIFY:
  Manually insert a mark_registered task into sync_tasks.
  Call drainQueue() once.
  Expected: Task status becomes 'complete' and is deleted from sync_tasks
  Expected: The row in Google Sheets shows Registered = 'Y'
```

#### Task 3.3 — Implement Crash Recovery

```
ACTION:
  Ensure resetInProgressTasks() is called in engine.ts startup sequence.

VERIFY:
  Manually set a task to status = 'in_progress' in SQLite.
  Restart the app (kill and reopen).
  Expected: Task status is reset to 'pending' on startup
  Expected: Task is processed normally on next sync tick
```

#### Task 3.4 — Implement Sync Engine Loop

```
ACTION:
  Implement engine.ts per Section 7.8.
  Startup: resetInProgressTasks → immediate tick → start interval
  Each tick: check network → refresh token → pull → push
  Backoff on RateLimitError: double interval, max 120000ms

VERIFY:
  Launch app. Check logs every 15 seconds.
  Expected: "Sync tick" log appears every 15 seconds
  Expected: After pull, participant count in SQLite matches Sheets
  Expected: After registering locally, task appears in Sheets within 15 seconds
```

#### Task 3.5 — Sync Status in Zustand

```
ACTION:
  After each tick: update pendingTaskCount and lastSyncedAt in Zustand store.
  Update failedTaskCount when a task exceeds 10 attempts.

VERIFY:
  Add a failing task (wrong sheetsRow). Attempt it 10 times.
  Expected: useAppStore.failedTaskCount increments to 1
  Expected: This does NOT stop the sync loop — other tasks still process
```

**→ PHASE 3 COMPLETE WHEN:** All 5 tasks verified. DEVLOG updated.

---

### Phase 4 — Scanner & Registration Flow

**Goal:** Full scan → confirm → register → print flow works end-to-end.

#### Task 4.1 — Implement useScanner.ts Hook

```
ACTION:
  Implement src/hooks/useScanner.ts.
  Use expo-camera and expo-barcode-scanner.
  Expose: { scannedId, isScanning, resetScanner }
  After scan: set scannedId, pause scanning for 2 seconds, then auto-reset.

VERIFY:
  Use the hook in a test screen. Scan a QR code.
  Expected: scannedId is set to the exact string encoded in QR
  Expected: Scanning is paused — scanning same code twice within 2s only fires once
```

#### Task 4.2 — Implement Scan Screen UI

```
ACTION:
  Implement app/(tabs)/scan.tsx per Section 7.12.
  Full-screen camera preview, centered 260×260 reticle, sync status badge.
  On scan result: show correct toast per spec.

VERIFY:
  Scan a valid QR → confirm screen opens
  Scan an unknown QR → toast "Participant not found" — no navigation
  Scan already-registered ID → toast "Already checked in — [Name]" — no navigation
  Scan same QR twice in < 2s → only one action fires
```

#### Task 4.3 — Implement Confirm Screen

```
ACTION:
  Implement app/confirm/[id].tsx per Section 7.13.
  Show participant card: Name, Room, Table.
  Confirm button: markRegisteredLocally → enqueueTask → printReceipt (async) → navigate back → success toast.
  Cancel button: navigate back, no changes.

VERIFY:
  Tap Confirm. Measure time from tap to back-on-scan-screen.
  Expected: < 500ms (not counting print)
  Expected: SQLite shows registered = 1 for participant
  Expected: sync_tasks has one pending mark_registered task
  Expected: Within 15s, Google Sheets shows Registered = Y for that row
```

#### Task 4.4 — Implement Participant List Screen

```
ACTION:
  Implement app/(tabs)/participants.tsx.
  Show all participants sorted by name. Show registered badge.
  Search bar filters by name (case-insensitive, uses searchParticipants()).
  Show total count and registered count at top.

VERIFY:
  Load screen with 1000 participants. Confirm it renders without lag.
  Type a name in search bar. Confirm results filter correctly.
  Register a participant. Navigate to list. Confirm their badge shows registered.
```

**→ PHASE 4 COMPLETE WHEN:** All 4 tasks verified. DEVLOG updated.

---

### Phase 5 — Bluetooth Printing

**Goal:** Receipt prints automatically after each confirmed check-in.

#### Task 5.1 — Implement printer.ts

```
ACTION:
  Implement src/print/printer.ts.
  Functions: connect(address), disconnect(), printReceipt(data), isConnected()
  Auto-reconnect: if print is called and printer is disconnected, attempt reconnect once before failing.
  All print errors must be caught and surfaced to Zustand store — never crash the app.

VERIFY:
  Connect to printer. Call printReceipt with test data.
  Expected: Receipt prints with correct content.
  Turn printer off. Call printReceipt.
  Expected: Error toast shown. App does not crash. Registration is still complete in SQLite.
```

#### Task 5.2 — Implement receipt.ts

```
ACTION:
  Implement src/print/receipt.ts per Section 7.11.
  Build ESC/POS byte sequence matching the layout in Section 7.11.
  Handle null/empty room_number and table_number with "(not assigned)".

VERIFY:
  Print a receipt for a participant with all fields populated.
  Print a receipt for a participant with null room and table.
  Expected: Layout matches spec. "(not assigned)" shown for missing fields.
```

#### Task 5.3 — Printer Settings UI

```
ACTION:
  Add printer section to app/(tabs)/settings.tsx.
  "Scan for Printers" button: lists nearby Bluetooth printers by name and MAC address.
  Tap a printer to pair and save address to app_settings.
  Show connection status (connected / disconnected).

VERIFY:
  Open settings. Tap scan. Select printer.
  Expected: Printer address saved to app_settings.printer_address
  Expected: Status shows "Connected"
  Restart app. Expected: App reconnects to saved printer automatically.
```

**→ PHASE 5 COMPLETE WHEN:** All 3 tasks verified. DEVLOG updated.

---

### Phase 6 — Polish & Edge Cases

#### Task 6.1 — Offline Banner
Show a persistent yellow banner when `expo-network` reports no internet. Scanner still works. Sync badge shows "Paused".

#### Task 6.2 — Failed Tasks Alert
If `failedTaskCount > 0` in Zustand store, show a red badge on the Settings tab. Tapping opens a list of failed tasks with their last error message.

#### Task 6.3 — Manual Sync Button
Add "Sync Now" button to settings screen. Calls one sync tick immediately outside the 15s interval.

#### Task 6.4 — Dark Mode
Use Expo's `useColorScheme()` hook. Apply dark background and light text when system is in dark mode.

#### Task 6.5 — Loading State on Participant List
Show a skeleton loader while SQLite is loading participants on first launch.

```
VERIFY ALL PHASE 6 TASKS:
  Each feature works as described above without crashing the app.
  DEVLOG updated with results of each.
```

**→ PHASE 6 COMPLETE WHEN:** All 5 tasks verified. DEVLOG updated.

---

## 9. QR Code Format

### 9.1 Payload Specification

> The QR code encodes the participant's `ID` value **exactly as it appears in the Google Sheet**, column `ID` (header row).

**Format:** Plain UTF-8 text string. No JSON. No URL encoding. No prefix. No suffix.

**Example:**
```
FSY2026-001
```

**Lookup:** The app does `SELECT * FROM participants WHERE id = ?` with the scanned string. Any mismatch (extra space, different case, added prefix) = "Not Found".

### 9.2 QR Code Generation

The event coordinator generates QR codes before the event. Recommended: Node.js script using the `qrcode` npm package reading IDs from a Sheets export.

---

## 10. Google Sheets Setup

### 10.1 Minimum Sheet Structure

Row 1 must be a header row with exactly these column names (case-sensitive):

```
ID | Name | Table Number | Hotel Room Number | Registered | Registered At | Registered By
```

- `Registered`, `Registered At`, `Registered By` columns must exist but can be empty — the app writes to them.
- Data starts from row 2.
- Column order does not matter — the app detects positions from the header row.

### 10.2 Google Cloud Project Setup

1. Go to [console.cloud.google.com](https://console.cloud.google.com) → Create project: `FSY Scanner 2026`
2. Enable **Google Sheets API**
3. Create **OAuth 2.0 credentials** → Application type: Android (or iOS)
4. Add the Expo redirect URI to Authorized Redirect URIs
5. Note the **Client ID** — enter it in `src/auth/google.ts`
6. Share the Google Sheet with the account that will sign in on the devices

---

## 11. Testing Checklist

> **AI CODER:** Run every item in this checklist before declaring the project complete. Log results in DEVLOG.md under a "Final Testing" section.

### 11.1 Sync Engine

- [ ] Kill app while a task is `in_progress` → restart → task retries and completes
- [ ] Disconnect WiFi during event → scan participant → reconnect → Sheets updated within 15s
- [ ] Simulate 429 response → interval doubles, API not spammed
- [ ] Two devices register different participants simultaneously → both appear in Sheets within 30s
- [ ] Device A registers participant X → Device B scans X → B shows "Already checked in"

### 11.2 Scanner

- [ ] Valid QR scan → confirm screen in < 100ms
- [ ] Unknown QR → "Not Found" toast, no crash
- [ ] Already registered QR → "Already Checked In" toast with name and time
- [ ] Rapid double-scan (< 2s) → only first scan fires

### 11.3 Printing

- [ ] Paired printer → receipt prints with all fields correct
- [ ] Printer off during registration → check-in completes, error toast shown
- [ ] Printer reconnects → next registration prints

### 11.4 Multi-Device (test with 2+ physical devices)

- [ ] 3 devices scan simultaneously → all SQLite DBs converge within 30s
- [ ] One device offline → scan + print still work → syncs on reconnect
- [ ] Same participant scanned on two devices within 1s → only one registration recorded in Sheets

### 11.5 Data Integrity

- [ ] 1,000 participants in Sheets → full initial pull → all 1,000 in SQLite → participant list renders without lag
- [ ] Pull from Sheets when local participant is already registered → `registered` stays `1`

---

## 12. DEVLOG Format

> **AI CODER:** Create `DEVLOG.md` in the project root on Phase 1 Task 1.1. Append an entry after every completed task. Never overwrite previous entries. This file is how the project owner reviews progress without seeing source code.

### 12.1 File Header (write once on creation)

```markdown
# FSY Scanner App — Development Log
Project: FSY Check-In Scanner
Plan Version: 1.1
Started: [DATE]
AI Coder: [Your name/model]

---
```

### 12.2 Entry Format (append after every task)

```markdown
## [PHASE].[TASK] — [Task Name]
**Date/Time:** [timestamp]  
**Status:** ✅ Complete | ⚠️ Complete with notes | ❌ Failed  

### What I Did
[Describe exactly what was implemented. Be specific: which functions, which files, what logic.]

### How I Followed the Plan
[Quote the specific rule from the plan you followed. Example: "Per Section 7.4, upsertParticipant() uses WHERE registered = 0 guard to prevent overwriting a registered participant."]

### Verification Result
[Paste the exact verify check from the plan and its result. Example: "VERIFY: Call getParticipantById after upsert with registered=0. Result: registered = 0 ✅"]

### Issues Encountered
[If none: write "None." If any: describe the problem, what you tried, and how you resolved it.]

### Corrections Made
[If the first implementation was wrong and required fixing: describe what was wrong and what was changed. If none: write "None."]

### Deviations from Plan
[If you deviated from the plan for any reason: state the deviation explicitly and justify it. If none: write "None — followed plan exactly."]

---
```

### 12.3 Phase Summary Entry (append after each phase)

```markdown
## PHASE [N] SUMMARY
**Completed:** [DATE]  
**Tasks completed:** [N]/[N]  
**Issues encountered:** [brief summary or "None"]  
**Ready for Phase [N+1]:** ✅ Yes | ❌ No (reason)

---
```

### 12.4 Final Testing Entry

```markdown
## FINAL TESTING LOG
**Date:** [DATE]  
**Tester:** [AI coder or human]  

| Test | Result | Notes |
|---|---|---|
| [test name] | ✅ Pass / ❌ Fail | [notes] |
...

**Overall Status:** ✅ All tests passed | ⚠️ Passed with known issues | ❌ Blocked

---
```

---

## 13. Known Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Sheets API rate limit (100 req / 100 sec per project) | Medium | 15s sync interval + per-task batching + exponential backoff on 429 |
| Two devices register same participant simultaneously | Low | Local `registered = 1` guard prevents double-write; puller convergence resolves within 15s |
| Bluetooth printer disconnects mid-event | Medium | Auto-reconnect in `printer.ts`; non-blocking print; manual reconnect in settings |
| Hotel WiFi instability | Low–Medium | Local-first design: scanning and printing work offline; queue drains on reconnect |
| Google OAuth token expires mid-event | Low | Silent refresh via `getValidToken()`; re-auth prompt if refresh fails |
| Registration team changes column names before event | Medium | Column auto-detect from header row; `ColMapError` shown clearly if headers don't match |
| `room_number` or `table_number` null at event time | Possible | App handles null gracefully: shows "(not assigned)" on receipt and confirm screen |

---

## 14. Hard Constraints

> **AI CODER:** These are non-negotiable. If implementing a feature would require violating any constraint below, stop and report it. Do not find a workaround silently.

| # | Constraint | Reason |
|---|---|---|
| 1 | No backend server of any kind | SDC requirement |
| 2 | All QR lookups resolve from local SQLite only — never wait on network | Scanning must be instant regardless of WiFi state |
| 3 | Sync tasks are never deleted until Sheets returns HTTP 200 | Prevents silent data loss |
| 4 | Never overwrite `registered = 1` with `0` from any source | Prevents race condition between devices |
| 5 | Print is always fire-and-forget — registration never waits on print result | Print failure must not block check-in |
| 6 | Column positions always read from `app_settings.col_map` — never hardcoded | Column order varies per event Sheet |
| 7 | Must use development build — not Expo Go | Native modules required |
| 8 | TypeScript strict mode enabled at all times | No `any`, no `ts-ignore` without an explanatory comment |
| 9 | `DEVLOG.md` is append-only — never overwrite or delete entries | Audit trail for project owner |
| 10 | Never guess or assume column names — throw `ColMapError` if headers don't match | Data integrity |

---

*End of FSY Scanner App Project Plan v1.1*  
*For questions or plan amendments, contact Jayson before proceeding.*
