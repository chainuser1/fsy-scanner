import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite/sqflite.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
import '../db/sync_queue_dao.dart';
import '../models/participant.dart';
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
  String? _printerAddress;
  String? _lastScanResult;

  bool _soundEnabled = true;
  bool _hapticEnabled = true;
  bool _voiceEnabled = false;

  String _eventName = '';

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
  String? get printerAddress => _printerAddress;
  String? get lastScanResult => _lastScanResult;
  bool get soundEnabled => _soundEnabled;
  bool get hapticEnabled => _hapticEnabled;
  bool get voiceEnabled => _voiceEnabled;
  String get eventName => _eventName;

  void addRecentScan(Participant participant) {
    _recentScans.insert(
        0,
        RecentScan(
          participantId: participant.id,
          name: participant.fullName,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
    if (_recentScans.length > maxRecentScans) {
      _recentScans.removeLast();
    }
    notifyListeners();
  }

  Future<bool> undoRecentScan(String participantId) async {
    try {
      final db = await DatabaseHelper.database;
      final dao = ParticipantsDao(db);
      await dao.markUnverifiedLocally(participantId);
      await SyncQueueDao.enqueueTask(SyncQueueDao.typeMarkUnverified, {
        'participantId': participantId,
      });
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
    final soundResult = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['sound_enabled']);
    final hapticResult = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['haptic_enabled']);
    final voiceResult = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['voice_enabled']);
    final eventNameResult = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['event_name']);

    _soundEnabled =
        soundResult.isEmpty || soundResult.first['value'] != 'false';
    _hapticEnabled =
        hapticResult.isEmpty || hapticResult.first['value'] != 'false';
    _voiceEnabled =
        voiceResult.isNotEmpty && voiceResult.first['value'] == 'true';

    if (eventNameResult.isNotEmpty) {
      _eventName = eventNameResult.first['value'] as String? ?? '';
    } else {
      _eventName = dotenv.env['EVENT_NAME'] ?? 'FSY 2026';
    }

    notifyListeners();
  }

  Future<void> loadEventName() async {
    final db = await DatabaseHelper.database;
    final result = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['event_name']);
    if (result.isNotEmpty) {
      _eventName = result.first['value'] as String? ?? '';
    } else {
      _eventName = dotenv.env['EVENT_NAME'] ?? 'FSY 2026';
    }
    notifyListeners();
  }

  Future<void> setSoundEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings', {'key': 'sound_enabled', 'value': enabled.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace);
    _soundEnabled = enabled;
    notifyListeners();
  }

  Future<void> setHapticEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings', {'key': 'haptic_enabled', 'value': enabled.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace);
    _hapticEnabled = enabled;
    notifyListeners();
  }

  Future<void> setVoiceEnabled(bool enabled) async {
    final db = await DatabaseHelper.database;
    await db.insert(
        'app_settings', {'key': 'voice_enabled', 'value': enabled.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace);
    _voiceEnabled = enabled;
    notifyListeners();
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
