import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import '../providers/app_state.dart';
import 'puller.dart';
import 'pusher.dart';
import 'sheets_api.dart';

class SyncEngine {
  static int _intervalMs = 15000; // Default to 15 seconds
  static bool _isSyncing = false;
  static final _syncStatusController = StreamController<bool>.broadcast();
  static int _rateLimitBackoffMultiplier = 1; // Start with 1 (no multiplier)

  static bool get isSyncing => _isSyncing;
  static Stream<bool> get syncStatusStream => _syncStatusController.stream;

  static void _setSyncing(bool value) {
    _isSyncing = value;
    _syncStatusController.add(value);
  }

  static Future<void> startup(AppState appState) async {
    debugPrint('[SyncEngine] Initializing...');
    // Note: dotenv.load() should be moved to main.dart per requirements
    // await dotenv.load(fileName: 'assets/.env');

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

    // NEW: Check for col_map and detect if missing - per plan Section 7.9 Step 3
    final colMapResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['col_map']);
    if (colMapResult.isEmpty || colMapResult.first['value'] == null || colMapResult.first['value'] == '') {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        try {
          final sheetIdResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
          final sheetTabResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
          
          if (sheetIdResult.isNotEmpty && sheetTabResult.isNotEmpty) {
            final sheetId = sheetIdResult.first['value'] as String;
            final sheetTab = sheetTabResult.first['value'] as String;
            await SheetsApi.detectColMap(db, token, sheetId, sheetTab);
          } else {
            debugPrint('[SyncEngine] Missing sheet configuration for column detection');
          }
        } on SheetsColMapException catch (e) {
          debugPrint('[SyncEngine] Column map detection failed: ${e.toString()}');
          appState.setSyncError('Column map detection failed: ${e.toString()}');
          return; // halt sync
        }
      }
    }

    // Load interval from .env or default to 15s
    final configuredInterval = dotenv.env['SYNC_INTERVAL_MS'];
    _intervalMs = int.tryParse(configuredInterval ?? '') ?? 15000;
    debugPrint('[SyncEngine] Interval set to $_intervalMs ms');

    // Initial sync after 3s
    await Future.delayed(const Duration(seconds: 3));
    unawaited(_syncLoop(appState)); // Fire-and-forget sync loop
  }

  static Future<bool> performFullSync(AppState appState) async {
    if (_isSyncing) return false;
    _setSyncing(true);
    debugPrint('[SyncEngine] Performing full sync...');
    try {
      final pushSuccess = await Pusher.pushPendingUpdates(appState);
      
      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;
      
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) return false;

      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      
      return pushSuccess;
    } on SheetsRateLimitException {
      // Increase the backoff multiplier when encountering rate limits
      _increaseBackoff();
      debugPrint('[SyncEngine] Rate limit encountered during full sync, increasing backoff to ${_intervalMs * _rateLimitBackoffMultiplier} ms');
      return false;
    } catch (e) {
      debugPrint('[SyncEngine] Error during full sync: $e');
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  static Future<bool> performPullSync(AppState appState) async {
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
    } on SheetsRateLimitException {
      // Increase the backoff multiplier when encountering rate limits
      _increaseBackoff();
      debugPrint('[SyncEngine] Rate limit encountered during pull sync, increasing backoff to ${_intervalMs * _rateLimitBackoffMultiplier} ms');
      return false;
    } catch (e) {
      debugPrint('[SyncEngine] Error during pull sync: $e');
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  static Future<void> _syncLoop(AppState appState) async {
    // Run sync loop indefinitely
    while (true) {
      if (_isSyncing) {
        await Future.delayed(Duration(milliseconds: _intervalMs * _rateLimitBackoffMultiplier));
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

      try {
        // Perform push sync first
        await Pusher.pushPendingUpdates(appState);
        
        // Then perform pull sync
        final db = await DatabaseHelper.database;
        await Puller.pull(db, token, sheetId, sheetName);
        
        // If both succeeded, potentially decrease backoff (reset to normal)
        if (_rateLimitBackoffMultiplier > 1) {
          _decreaseBackoff();
          debugPrint('[SyncEngine] Success after rate limit, decreasing backoff to ${_intervalMs * _rateLimitBackoffMultiplier} ms');
        }
      } on SheetsRateLimitException {
        // Increase the backoff multiplier when encountering rate limits
        _increaseBackoff();
        debugPrint('[SyncEngine] Rate limit encountered in loop, increasing backoff to ${_intervalMs * _rateLimitBackoffMultiplier} ms');
      } catch (e) {
        debugPrint('[SyncEngine] Error during sync: $e');
      }

      // Log results
      final pendingCount = await SyncQueueDao.getPendingCount();
      appState.setPendingTaskCount(pendingCount); // Update UI with pending count
      debugPrint('[SyncEngine] Sync completed. Pending: $pendingCount');

      // Wait for next sync
      await Future.delayed(Duration(milliseconds: _intervalMs * _rateLimitBackoffMultiplier));
    }
  }

  // Helper to increase backoff multiplier (with max)
  static void _increaseBackoff() {
    _rateLimitBackoffMultiplier = _rateLimitBackoffMultiplier * 2;
    if (_rateLimitBackoffMultiplier > 8) { // Max 8x the original interval (2 minutes if default is 15s)
      _rateLimitBackoffMultiplier = 8;
    }
  }

  // Helper to decrease backoff multiplier
  static void _decreaseBackoff() {
    _rateLimitBackoffMultiplier = _rateLimitBackoffMultiplier ~/ 2;
    if (_rateLimitBackoffMultiplier < 1) {
      _rateLimitBackoffMultiplier = 1;
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