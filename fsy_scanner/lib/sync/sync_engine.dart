import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite/sqflite.dart';
import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import 'puller.dart';
import 'pusher.dart';

class SyncEngine {
  static int _intervalMs = 30000;
  static bool _isSyncing = false;
  static final _syncStatusController = StreamController<bool>.broadcast();

  static bool get isSyncing => _isSyncing;
  static Stream<bool> get syncStatusStream => _syncStatusController.stream;

  static void _setSyncing(bool value) {
    _isSyncing = value;
    _syncStatusController.add(value);
  }

  static Future<void> startup() async {
    debugPrint('[SyncEngine] Initializing...');
    await dotenv.load(fileName: 'assets/.env');

    final db = await DatabaseHelper.database;
    await SyncQueueDao.resetInProgressTasks();

    // Seed app_settings from .env if keys missing
    final settingsToSeed = {
      'sheets_id': dotenv.env['SHEETS_ID'],
      'sheets_tab': dotenv.env['SHEETS_TAB'],
      'event_name': dotenv.env['EVENT_NAME'],
    };

    for (final entry in settingsToSeed.entries) {
      if (entry.value != null) {
        await db.insert(
          'app_settings',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }

    // Load interval from .env or default to 15s
    final configuredInterval = dotenv.env['SYNC_INTERVAL_MS'];
    _intervalMs = int.tryParse(configuredInterval ?? '') ?? 15000;
    debugPrint('[SyncEngine] Interval set to $_intervalMs ms');

    // Initial sync after 3s
    await Future.delayed(const Duration(seconds: 3));
    _syncLoop(); // Don't await the loop
  }

  static Future<bool> performFullSync() async {
    if (_isSyncing) return false;
    _setSyncing(true);
    debugPrint('[SyncEngine] Performing full sync...');
    try {
      final pushSuccess = await Pusher.pushPendingUpdates();
      
      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;
      
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) return false;

      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      
      return pushSuccess;
    } catch (e) {
      debugPrint('[SyncEngine] Error during full sync: $e');
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  static Future<bool> performPullSync() async {
    if (_isSyncing) return false;
    _setSyncing(true);
    debugPrint('[SyncEngine] Performing pull sync...');
    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;
      
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) return false;

      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      debugPrint('[SyncEngine] Pull sync completed.');
      return true;
    } catch (e) {
      debugPrint('[SyncEngine] Error during pull sync: $e');
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  static Future<void> _syncLoop() async {
    // Run sync loop indefinitely
    while (true) {
      if (_isSyncing) {
        await Future.delayed(Duration(milliseconds: _intervalMs));
        continue;
      }

      // Wait for connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult.contains(ConnectivityResult.none)) {
        debugPrint('[SyncEngine] No connectivity, waiting...');
        await Future.delayed(const Duration(seconds: 10));
        continue;
      }

      // Verify auth token works
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        debugPrint('[SyncEngine] No auth token, waiting...');
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }

      // Get latest values from settings
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) {
        debugPrint('[SyncEngine] Missing sheet config, waiting...');
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }

      // Perform sync
      final pushSuccess = await Pusher.pushPendingUpdates();
      
      final db = await DatabaseHelper.database;
      bool pullSuccess = false;
      try {
        await Puller.pull(db, token, sheetId, sheetName);
        pullSuccess = true;
      } catch (e) {
        debugPrint('[SyncEngine] Error during pull: $e');
      }
      
      final success = pushSuccess && pullSuccess;

      // Log results
      final pendingCount = await SyncQueueDao.getPendingCount();
      debugPrint('[SyncEngine] Sync ${success ? 'success' : 'fail'}. Pending: $pendingCount');

      // Wait for next sync
      await Future.delayed(Duration(milliseconds: _intervalMs));
    }
  }

  // Add the missing _getSettingValue method
  static Future<String?> _getSettingValue(String key) async {
    // This would typically retrieve setting from the database
    // For now, returning null to indicate the setting is not found
    // In a real implementation, this would query the settings table
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery(
        'SELECT value FROM app_settings WHERE key = ?',
        [key]
      );
      if (result.isNotEmpty) {
        return result.first['value'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('[SyncEngine] Error retrieving setting $key: $e');
      return null;
    }
  }
}