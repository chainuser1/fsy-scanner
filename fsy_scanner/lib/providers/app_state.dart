import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../models/participant.dart';
import '../print/printer_service.dart';
import '../sync/sheets_api.dart';
import '../sync/sync_engine.dart';
import '../utils/logger.dart';

class AppState extends ChangeNotifier {
  int _pendingTaskCount = 0;
  int _failedTaskCount = 0;
  int _participantsCount = 0;
  DateTime? _lastSyncedAt;
  String? _syncError;
  bool _isInitialLoading = false;
  bool _isOnline = true;
  bool _printerConnected = false;
  bool _printerHasSelection = false;
  bool _printerPermissionsGranted = true;
  bool _printerPaired = false;
  bool _printerConnecting = false;
  String? _printerAddress;
  String? _printerName;
  String _printerStateLabel = 'No Printer Selected';
  String _printerStatusMessage = 'No printer selected';
  int _printerFailedJobCount = 0;
  int _pendingPrintConfirmationCount = 0;
  int _printerActiveJobCount = 0;
  int? _lastPrintSuccessAt;
  int? _lastPrintFailureAt;
  String? _lastPrintFailureReason;
  String? _lastScanResult;

  bool _soundEnabled = true;
  bool _hapticEnabled = true;
  bool _voiceEnabled = false;
  String _receiptConfirmationPolicy =
      PrinterService.receiptConfirmationFastQueue;

  String _eventName = '';
  String _organizationName = '';

  // ── Sheet identifiers (loaded from DB or .env) ───────────────
  String _sheetsId = '';
  String _sheetsTab = '';

  /// Monotonically increasing counter bumped on every `loadPreferences()` call
  /// so downstream widgets can reliably detect external state refreshes.
  int _preferencesVersion = 0;
  int get preferencesVersion => _preferencesVersion;

  // ── Google Service Account (Advanced) ─────────────────────────
  String _googleServiceAccountEmail = '';
  String _googleServiceAccountPrivateKey = '';

  // ── Column Mapping Overrides (Advanced) ────────────────────
  /// Maps internal field key → sheet header name (user-configured).
  /// If empty, the build-time SheetColumns constants are used.
  Map<String, String> _columnHeaderOverrides = {};

  // ── Event Profiles (Advanced) ────────────────────────────────
  List<Map<String, dynamic>> _eventProfiles = [];
  int? _activeProfileId;

  StreamSubscription<PrinterServiceEvent>? _printerSubscription;

  static const int maxRecentScans = 10;
  final List<RecentScan> _recentScans = [];
  List<RecentScan> get recentScans => List.unmodifiable(_recentScans);

  int get pendingTaskCount => _pendingTaskCount;
  int get failedTaskCount => _failedTaskCount;
  int get participantsCount => _participantsCount;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get syncError => _syncError;
  bool get isInitialLoading => _isInitialLoading;
  bool get isOnline => _isOnline;
  bool get printerConnected => _printerConnected;
  bool get printerHasSelection => _printerHasSelection;
  bool get printerPermissionsGranted => _printerPermissionsGranted;
  bool get printerPaired => _printerPaired;
  bool get printerConnecting => _printerConnecting;
  String? get printerAddress => _printerAddress;
  String? get printerName => _printerName;
  String get printerStateLabel => _printerStateLabel;
  String get printerStatusMessage => _printerStatusMessage;
  int get printerFailedJobCount => _printerFailedJobCount;
  int get pendingPrintConfirmationCount => _pendingPrintConfirmationCount;
  int get printerActiveJobCount => _printerActiveJobCount;
  int? get lastPrintSuccessAt => _lastPrintSuccessAt;
  int? get lastPrintFailureAt => _lastPrintFailureAt;
  String? get lastPrintFailureReason => _lastPrintFailureReason;
  String? get lastScanResult => _lastScanResult;
  bool get soundEnabled => _soundEnabled;
  bool get hapticEnabled => _hapticEnabled;
  bool get voiceEnabled => _voiceEnabled;
  String get receiptConfirmationPolicy => _receiptConfirmationPolicy;
  String get eventName => _eventName;
  String get organizationName => _organizationName;
  String get sheetsId => _sheetsId;
  String get sheetsTab => _sheetsTab;

  // ── Google creds getters ─────────────────────────────────────
  String get googleServiceAccountEmail => _googleServiceAccountEmail;
  String get googleServiceAccountPrivateKey =>
      _googleServiceAccountPrivateKey;

  // ── Column overrides getter ──────────────────────────────────
  Map<String, String> get columnHeaderOverrides =>
      Map.unmodifiable(_columnHeaderOverrides);

  // ── Event profiles getters ───────────────────────────────────
  List<Map<String, dynamic>> get eventProfiles =>
      List.unmodifiable(_eventProfiles);
  int? get activeProfileId => _activeProfileId;

  void addRecentScan(Participant participant) {
    _recentScans.insert(
      0,
      RecentScan(
        participantId: participant.id,
        name: participant.fullName,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (_recentScans.length > maxRecentScans) {
      _recentScans.removeLast();
    }
    notifyListeners();
  }

  Future<bool> undoRecentScan(String participantId) async {
    try {
      PrinterService.cancelPendingPrint(participantId);
      await ParticipantsDao.markUnverifiedAndQueue(participantId);
      _recentScans.removeWhere((s) => s.participantId == participantId);
      await refreshParticipantsCount();
      notifyListeners();
      return true;
    } catch (e) {
      LoggerUtil.error('Undo failed: $e', error: e);
      return false;
    }
  }

  void setPendingTaskCount(int count) {
    _pendingTaskCount = count;
    notifyListeners();
  }

  void setFailedTaskCount(int count) {
    _failedTaskCount = count;
    notifyListeners();
  }

  void setParticipantsCount(int count) {
    _participantsCount = count;
    notifyListeners();
  }

  void setInitialLoading(bool val) {
    _isInitialLoading = val;
    notifyListeners();
  }

  void setIsOnline(bool online) {
    _isOnline = online;
    notifyListeners();
  }

  void setSyncError(String? msg) {
    _syncError = msg;
    notifyListeners();
  }

  void setPrinterConnected(bool val) {
    _printerConnected = val;
    notifyListeners();
  }

  void applyPrinterSnapshot(PrinterStatusSnapshot status) {
    _printerHasSelection = status.hasSelection;
    _printerPermissionsGranted = status.permissionsGranted;
    _printerPaired = status.isPaired;
    _printerConnected = status.isConnected;
    _printerConnecting = status.isConnecting;
    _printerAddress = status.selectedAddress;
    _printerName = status.selectedName;
    _printerStateLabel = status.stateLabel;
    _printerStatusMessage = status.message;
    _printerFailedJobCount = status.queuedJobCount;
    _pendingPrintConfirmationCount = status.pendingConfirmationCount;
    _printerActiveJobCount = status.activeJobCount;
    _lastPrintSuccessAt = status.lastPrintSuccessAt;
    _lastPrintFailureAt = status.lastPrintFailureAt;
    _lastPrintFailureReason = status.lastPrintFailureReason;
    notifyListeners();
  }

  void setPrinterAddress(String? addr) {
    _printerAddress = addr;
    notifyListeners();
  }

  void setLastScanResult(String? result) {
    _lastScanResult = result;
    notifyListeners();
  }

  void incrementFailedTaskCount() {
    _failedTaskCount++;
    notifyListeners();
  }

  void setLastSyncedAt(DateTime time) {
    _lastSyncedAt = time;
    notifyListeners();
  }

  Future<void> refreshParticipantsCount() async {
    _participantsCount = await ParticipantsDao.getRegisteredCount();
    notifyListeners();
  }

  Future<int> getRegisteredCount() async {
    try {
      return await ParticipantsDao.getRegisteredCount();
    } catch (e) {
      LoggerUtil.error('Error getting registered count: $e', error: e);
      return 0;
    }
  }

  Future<void> loadPreferences() async {
    final db = await DatabaseHelper.database;
    final soundResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sound_enabled'],
    );
    final hapticResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['haptic_enabled'],
    );
    final voiceResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['voice_enabled'],
    );
    final eventNameResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['event_name'],
    );
    final organizationNameResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['organization_name'],
    );
    final receiptConfirmationPolicyResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['receipt_confirmation_policy'],
    );

    _soundEnabled =
        soundResult.isEmpty || soundResult.first['value'] != 'false';
    _hapticEnabled =
        hapticResult.isEmpty || hapticResult.first['value'] != 'false';
    _voiceEnabled =
        voiceResult.isNotEmpty && voiceResult.first['value'] == 'true';
    _receiptConfirmationPolicy = receiptConfirmationPolicyResult.isEmpty
        ? PrinterService.receiptConfirmationFastQueue
        : receiptConfirmationPolicyResult.first['value'] as String? ??
            PrinterService.receiptConfirmationFastQueue;

    if (eventNameResult.isNotEmpty) {
      _eventName = eventNameResult.first['value'] as String? ?? '';
    } else {
      _eventName = dotenv.env['EVENT_NAME'] ?? 'FSY 2026';
    }

    if (organizationNameResult.isNotEmpty) {
      _organizationName =
          organizationNameResult.first['value'] as String? ?? '';
    } else {
      _organizationName = dotenv.env['ORGANIZATION_NAME'] ?? '';
    }

    // ── Load sheet identifiers ─────────────────────────────────
    final sheetsIdResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_id'],
    );
    final sheetsTabResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['sheets_tab'],
    );
    _sheetsId = sheetsIdResult.isNotEmpty
        ? sheetsIdResult.first['value'] as String? ?? ''
        : dotenv.env['SHEETS_ID'] ?? '';
    _sheetsTab = sheetsTabResult.isNotEmpty
        ? sheetsTabResult.first['value'] as String? ?? ''
        : dotenv.env['SHEETS_TAB'] ?? '';

    // ── Load Google service account credentials ────────────────
    final googleEmailResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['google_service_account_email'],
    );
    final googleKeyResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['google_service_account_private_key'],
    );
    _googleServiceAccountEmail = googleEmailResult.isNotEmpty
        ? googleEmailResult.first['value'] as String? ?? ''
        : dotenv.env['GOOGLE_SERVICE_ACCOUNT_EMAIL'] ?? '';
    _googleServiceAccountPrivateKey = googleKeyResult.isNotEmpty
        ? googleKeyResult.first['value'] as String? ?? ''
        : dotenv.env['GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY'] ?? '';

    // ── Load column header overrides ───────────────────────────
    final colOverrideResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['column_header_overrides'],
    );
    if (colOverrideResult.isNotEmpty) {
      final raw = colOverrideResult.first['value'] as String? ?? '';
      if (raw.isNotEmpty) {
        try {
          _columnHeaderOverrides =
              Map<String, String>.from(jsonDecode(raw));
        } catch (_) {
          _columnHeaderOverrides = {};
        }
      }
    }

    // ── Load event profiles ────────────────────────────────────
    _eventProfiles = await db.query('event_profiles');
    final activeResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['active_profile_id'],
    );
    if (activeResult.isNotEmpty) {
      _activeProfileId =
          int.tryParse(activeResult.first['value'] as String? ?? '');
    }

    _preferencesVersion++;
    notifyListeners();
  }

  Future<void> startPrinterAutomation() async {
    await PrinterService.startAutomation();
    await _refreshPrinterSnapshot();
    await _printerSubscription?.cancel();
    _printerSubscription = PrinterService.events.listen((event) {
      _printerHasSelection = event.hasSelection;
      _printerPermissionsGranted = event.permissionsGranted;
      _printerPaired = event.isPaired;
      _printerAddress = event.selectedAddress;
      _printerName = event.selectedName;
      _printerConnected = event.isConnected;
      _printerConnecting = event.isConnecting;
      _printerFailedJobCount = event.failedJobCount;
      _pendingPrintConfirmationCount = event.pendingConfirmationCount;
      _printerActiveJobCount = event.activeJobCount;
      _printerStateLabel = event.stateLabel;
      _printerStatusMessage = event.statusMessage;
      _lastPrintSuccessAt = event.lastPrintSuccessAt;
      _lastPrintFailureAt = event.lastPrintFailureAt;
      _lastPrintFailureReason = event.lastPrintFailureReason;
      notifyListeners();
    });
  }

  Future<void> loadEventName() async {
    final db = await DatabaseHelper.database;
    final result = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['event_name'],
    );
    if (result.isNotEmpty) {
      _eventName = result.first['value'] as String? ?? '';
    } else {
      _eventName = dotenv.env['EVENT_NAME'] ?? 'FSY 2026';
    }
    final organizationResult = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['organization_name'],
    );
    if (organizationResult.isNotEmpty) {
      _organizationName = organizationResult.first['value'] as String? ?? '';
    } else {
      _organizationName = dotenv.env['ORGANIZATION_NAME'] ?? '';
    }
    notifyListeners();
  }

  Future<void> setSoundEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings',
        {
          'key': 'sound_enabled',
          'value': enabled.toString(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    _soundEnabled = enabled;
    notifyListeners();
  }

  Future<void> setHapticEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings',
        {
          'key': 'haptic_enabled',
          'value': enabled.toString(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    _hapticEnabled = enabled;
    notifyListeners();
  }

  Future<void> setVoiceEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings',
        {
          'key': 'voice_enabled',
          'value': enabled.toString(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    _voiceEnabled = enabled;
    notifyListeners();
  }

  Future<void> setReceiptConfirmationPolicy(String policy) async {
    await PrinterService.setReceiptConfirmationPolicy(policy);
    _receiptConfirmationPolicy = policy;
    notifyListeners();
  }

  // ── Google credentials ───────────────────────────────────────
  Future<void> setGoogleServiceAccountCredentials({
    required String email,
    required String privateKey,
  }) async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'app_settings',
      {'key': 'google_service_account_email', 'value': email},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'app_settings',
      {'key': 'google_service_account_private_key', 'value': privateKey},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _googleServiceAccountEmail = email;
    _googleServiceAccountPrivateKey = privateKey;
    GoogleAuth.invalidateCache();
    notifyListeners();
  }

  // ── Column header overrides ─────────────────────────────────
  Future<void> setColumnHeaderOverrides(Map<String, String> overrides) async {
    final db = await DatabaseHelper.database;
    final raw = jsonEncode(overrides);
    await db.insert(
      'app_settings',
      {'key': 'column_header_overrides', 'value': raw},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _columnHeaderOverrides = Map.from(overrides);
    notifyListeners();
  }

  /// Clear column overrides so the next column detection uses raw headers.
  Future<void> clearColumnHeaderOverrides() async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['column_header_overrides'],
    );
    _columnHeaderOverrides = {};
    notifyListeners();
  }

  // ── Event profiles ───────────────────────────────────────────
  Future<void> refreshEventProfiles() async {
    final db = await DatabaseHelper.database;
    _eventProfiles = await db.query('event_profiles');
    notifyListeners();
  }

  Future<int> createEventProfile({
    required String name,
    required String sheetsId,
    required String sheetsTab,
    required String eventName,
    required String organizationName,
    String? colMapOverride,
    String? googleEmail,
    String? googlePrivateKey,
  }) async {
    final db = await DatabaseHelper.database;
    final id = await db.insert('event_profiles', {
      'name': name,
      'sheets_id': sheetsId,
      'sheets_tab': sheetsTab,
      'event_name': eventName,
      'organization_name': organizationName,
      'col_map_override': colMapOverride ?? '',
      'google_service_account_email': googleEmail ?? '',
      'google_service_account_private_key': googlePrivateKey ?? '',
    });
    await refreshEventProfiles();
    return id;
  }

  Future<void> updateEventProfile(
    int profileId, {
    String? name,
    String? sheetsId,
    String? sheetsTab,
    String? eventName,
    String? organizationName,
    String? colMapOverride,
    String? googleEmail,
    String? googlePrivateKey,
  }) async {
    final db = await DatabaseHelper.database;
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (sheetsId != null) updates['sheets_id'] = sheetsId;
    if (sheetsTab != null) updates['sheets_tab'] = sheetsTab;
    if (eventName != null) updates['event_name'] = eventName;
    if (organizationName != null) {
      updates['organization_name'] = organizationName;
    }
    if (colMapOverride != null) {
      updates['col_map_override'] = colMapOverride;
    }
    if (googleEmail != null) {
      updates['google_service_account_email'] = googleEmail;
    }
    if (googlePrivateKey != null) {
      updates['google_service_account_private_key'] = googlePrivateKey;
    }
    if (updates.isNotEmpty) {
      await db.update(
        'event_profiles',
        updates,
        where: 'id = ?',
        whereArgs: [profileId],
      );
    }
    await refreshEventProfiles();
  }

  Future<void> deleteEventProfile(int profileId) async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'event_profiles',
      where: 'id = ?',
      whereArgs: [profileId],
    );
    if (_activeProfileId == profileId) {
      _activeProfileId = null;
      await db.delete(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['active_profile_id'],
      );
    }
    await refreshEventProfiles();
  }

  /// Activate a profile — copies its settings into app_settings and triggers
  /// column re-detection and a full re-sync.
  Future<void> activateEventProfile(int profileId) async {
    final db = await DatabaseHelper.database;
    final profiles = await db.query(
      'event_profiles',
      where: 'id = ?',
      whereArgs: [profileId],
    );
    if (profiles.isEmpty) return;
    final profile = profiles.first;

    final sheetsId = (profile['sheets_id'] as String?) ?? '';
    final sheetsTab = (profile['sheets_tab'] as String?) ?? '';
    final eventName = (profile['event_name'] as String?) ?? '';
    final orgName = (profile['organization_name'] as String?) ?? '';
    final colMapRaw = (profile['col_map_override'] as String?) ?? '';
    final googleEmail = (profile['google_service_account_email'] as String?) ?? '';
    final googleKey = (profile['google_service_account_private_key'] as String?) ?? '';

    // Clear stale col_map so the next sync rebuilds it from scratch
    await db.delete('app_settings', where: 'key = ?', whereArgs: ['col_map']);

    // Write values into app_settings
    await db.insert(
      'app_settings',
      {'key': 'sheets_id', 'value': sheetsId},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'app_settings',
      {'key': 'sheets_tab', 'value': sheetsTab},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'app_settings',
      {'key': 'event_name', 'value': eventName},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'app_settings',
      {'key': 'organization_name', 'value': orgName},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (colMapRaw.isNotEmpty) {
      await db.insert(
        'app_settings',
        {'key': 'col_map', 'value': colMapRaw},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (googleEmail.isNotEmpty) {
      await db.insert(
        'app_settings',
        {'key': 'google_service_account_email', 'value': googleEmail},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (googleKey.isNotEmpty) {
      await db.insert(
        'app_settings',
        {'key': 'google_service_account_private_key', 'value': googleKey},
      );
    }

    _activeProfileId = profileId;
    await db.insert(
      'app_settings',
      {'key': 'active_profile_id', 'value': profileId.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    GoogleAuth.invalidateCache();
    await loadPreferences();
    SyncEngine.signalConfigChanged();
    notifyListeners();

    // Re-detect column map so the upcoming full sync can use fresh data.
    try {
      final newToken = await GoogleAuth.getValidToken();
      if (newToken != null) {
        await SheetsApi.detectColMap(db, newToken, sheetsId, sheetsTab);
      }
    } catch (e) {
      // Non-fatal: detection will be retried during the sync loop.
    }
  }

  Future<void> clearAllData() async {
    final db = await DatabaseHelper.database;
    await db.delete('participants');
    await db.delete('sync_tasks');
    _participantsCount = 0;
    _pendingTaskCount = 0;
    _failedTaskCount = 0;
    _recentScans.clear();
    notifyListeners();
  }

  Future<void> _refreshPrinterSnapshot() async {
    final status = await PrinterService.getSelectedPrinterStatus(
      requestPermissions: false,
    );
    applyPrinterSnapshot(status);
  }

  @override
  void dispose() {
    _printerSubscription?.cancel();
    super.dispose();
  }
}

class RecentScan {
  final String participantId;
  final String name;
  final int timestamp;
  RecentScan({
    required this.participantId,
    required this.name,
    required this.timestamp,
  });
}
