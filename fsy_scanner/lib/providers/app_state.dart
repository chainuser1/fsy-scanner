import 'package:flutter/foundation.dart';

import '../db/participants_dao.dart';
import '../db/database_helper.dart';

class AppState extends ChangeNotifier {
  int _participantsCount = 0;
  bool _isInitialLoading = false;
  bool _syncError = false;
  DateTime? _lastSyncedAt;

  int get participantsCount => _participantsCount;
  bool get isInitialLoading => _isInitialLoading;
  bool get syncError => _syncError;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  set isInitialLoading(bool value) {
    _isInitialLoading = value;
    notifyListeners();
  }

  set syncError(bool value) {
    _syncError = value;
    notifyListeners();
  }

  set lastSyncedAt(DateTime? value) {
    _lastSyncedAt = value;
    notifyListeners();
  }

  Future<void> refreshParticipantsCount() async {
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    _participantsCount = await dao.getRegisteredCount();
    notifyListeners();
  }

  Future<void> clearAllData() async {
    final db = await DatabaseHelper.database;
    final dao = ParticipantsDao(db);
    await dao.clearParticipants();
    _participantsCount = 0;
    notifyListeners();
  }
}