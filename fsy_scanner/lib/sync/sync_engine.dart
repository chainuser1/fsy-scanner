import 'dart:async';

import '../db/database_helper.dart';
import 'puller.dart';
import 'pusher.dart';
import '../auth/google_auth.dart';

class SyncEngine {
  static bool _isSyncing = false;
  static final StreamController<String> _syncStatusController = StreamController<String>.broadcast();

  static bool get isSyncing => _isSyncing;
  static Stream<String> get syncStatusStream => _syncStatusController.stream;

  static Future<void> performFullSync() async {
    _isSyncing = true;
    _syncStatusController.add('Syncing...');

    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        throw Exception('Could not get authentication token');
      }

      // Load sheetId and tabName from environment or settings
      // This is simplified - in reality you'd load these from settings
      const sheetId = 'your-sheet-id'; // Would come from settings
      const tabName = 'your-tab-name'; // Would come from settings

      final db = await DatabaseHelper.database;

      // Perform pull
      await pull(db, token, sheetId, tabName);

      // Perform push
      await drainQueue(db, token, sheetId, tabName);
    } finally {
      _isSyncing = false;
      _syncStatusController.add('Ready');
    }
  }

  static Future<void> performPullSync() async {
    _isSyncing = true;
    _syncStatusController.add('Syncing...');

    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        throw Exception('Could not get authentication token');
      }

      // Load sheetId and tabName from environment or settings
      const sheetId = 'your-sheet-id'; // Would come from settings
      const tabName = 'your-tab-name'; // Would come from settings

      final db = await DatabaseHelper.database;

      // Perform pull only
      await pull(db, token, sheetId, tabName);
    } finally {
      _isSyncing = false;
      _syncStatusController.add('Ready');
    }
  }
}