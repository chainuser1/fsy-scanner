import 'package:flutter/foundation.dart';

import '../db/database_helper.dart';
import '../db/participants_dao.dart';
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

  Future<void> clearAllData() async {
    final db = await DatabaseHelper.database;
    await db.delete('participants');
    await db.delete('sync_tasks');
    _participantsCount = 0;
    _pendingTaskCount = 0;
    _failedTaskCount = 0;
    notifyListeners();
  }
}
