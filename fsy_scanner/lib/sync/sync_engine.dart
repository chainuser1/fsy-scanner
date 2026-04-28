import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import '../providers/app_state.dart';
import '../utils/logger.dart';
import 'puller.dart';
import 'pusher.dart';
import 'sheets_api.dart';

class SyncEngine {
  static int _intervalMs = 15000; // Default to 15 seconds
  static bool _isSyncing = false;
  static final _syncStatusController = StreamController<bool>.broadcast();
  static int _rateLimitBackoffMultiplier = 1;

  static bool get isSyncing => _isSyncing;
  static Stream<bool> get syncStatusStream => _syncStatusController.stream;

  static void _setSyncing(bool value) {
    _isSyncing = value;
    _syncStatusController.add(value);
  }

  /// Initialize sync engine and start periodic sync loop
  static Future<void> startup(AppState appState) async {
    LoggerUtil.info('[SyncEngine] Initializing...');

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

    // Check for col_map and detect if missing
    final colMapResult = await db.query(
      'app_settings', where: 'key = ?', whereArgs: ['col_map']);
    
    if (colMapResult.isEmpty ||
        colMapResult.first['value'] == null ||
        (colMapResult.first['value'] as String).isEmpty) {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        try {
          final sheetIdResult = await db.query(
            'app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
          final sheetTabResult = await db.query(
            'app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
          
          if (sheetIdResult.isNotEmpty && sheetTabResult.isNotEmpty) {
            final sheetId = sheetIdResult.first['value'] as String;
            final sheetTab = sheetTabResult.first['value'] as String;
            LoggerUtil.info('[SyncEngine] Detecting column map...');
            await SheetsApi.detectColMap(db, token, sheetId, sheetTab);
          }
        } on SheetsColMapException catch (e) {
          LoggerUtil.error('[SyncEngine] Column map detection failed: $e');
          appState.setSyncError('Column map detection failed: $e');
          return;
        }
      }
    }

    // Load interval from .env or default to 15s
    final configuredInterval = dotenv.env['SYNC_INTERVAL_MS'];
    _intervalMs = int.tryParse(configuredInterval ?? '') ?? 15000;
    LoggerUtil.info('[SyncEngine] Interval set to $_intervalMs ms');

    // Start sync loop after short delay
    await Future.delayed(const Duration(seconds: 3));
    unawaited(_syncLoop(appState));
  }

  /// Dispose the stream controller
  static void dispose() {
    _syncStatusController.close();
  }

  /// Perform a full sync (push then pull)
  static Future<bool> performFullSync(AppState appState) async {
    if (_isSyncing) return false;
    _setSyncing(true);
    LoggerUtil.info('[SyncEngine] Performing full sync...');
    try {
      final pushSuccess = await Pusher.pushPendingUpdates(appState);
      
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        LoggerUtil.warn('[SyncEngine] No auth token for full sync');
        return false;
      }
      
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) {
        LoggerUtil.warn('[SyncEngine] Missing sheet config for full sync');
        return false;
      }

      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      
      LoggerUtil.info('[SyncEngine] Full sync completed');
      return pushSuccess;
    } on SheetsRateLimitException {
      _increaseBackoff();
      LoggerUtil.warn('[SyncEngine] Rate limit, backoff: ${_intervalMs * _rateLimitBackoffMultiplier}ms');
      return false;
    } catch (e) {
      LoggerUtil.error('[SyncEngine] Full sync error: $e', error: e);
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  /// Perform a pull-only sync
  static Future<bool> performPullSync(AppState appState) async {
    if (_isSyncing) return false;
    _setSyncing(true);
    LoggerUtil.info('[SyncEngine] Performing pull sync...');
    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        LoggerUtil.warn('[SyncEngine] No auth token for pull sync');
        return false;
      }
      
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) {
        LoggerUtil.warn('[SyncEngine] Missing sheet config for pull sync');
        return false;
      }

      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      LoggerUtil.info('[SyncEngine] Pull sync completed');
      return true;
    } on SheetsRateLimitException {
      _increaseBackoff();
      LoggerUtil.warn('[SyncEngine] Rate limit, backoff: ${_intervalMs * _rateLimitBackoffMultiplier}ms');
      return false;
    } catch (e) {
      LoggerUtil.error('[SyncEngine] Pull sync error: $e', error: e);
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  /// Background sync loop running at configured interval
  static Future<void> _syncLoop(AppState appState) async {
    // Check initial connectivity
    final initialConnectivity = await Connectivity().checkConnectivity();
    appState.setIsOnline(!initialConnectivity.contains(ConnectivityResult.none));

    while (true) {
      if (_isSyncing) {
        await Future.delayed(Duration(milliseconds: _intervalMs * _rateLimitBackoffMultiplier));
        continue;
      }

      // Check connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      final isCurrentlyOnline = !connectivityResult.contains(ConnectivityResult.none);
      
      if (isCurrentlyOnline != appState.isOnline) {
        appState.setIsOnline(isCurrentlyOnline);
        if (isCurrentlyOnline) {
          LoggerUtil.info('[SyncEngine] Connection restored');
        } else {
          LoggerUtil.warn('[SyncEngine] Connection lost');
        }
      }

      // Skip if offline
      if (connectivityResult.contains(ConnectivityResult.none)) {
        LoggerUtil.debug('[SyncEngine] Offline, waiting...');
        await Future.delayed(const Duration(seconds: 10));
        continue;
      }

      // Get auth token
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        LoggerUtil.warn('[SyncEngine] No auth token, waiting...');
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }

      // Get sheet config
      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) {
        LoggerUtil.warn('[SyncEngine] Missing sheet config, waiting...');
        await Future.delayed(const Duration(seconds: 30));
        continue;
      }

      // Check if this is the first load
      final lastPulledResult = await _getSettingValue('last_pulled_at');
      final isFirstLoad = lastPulledResult == null || lastPulledResult == '0';
      
      if (isFirstLoad) {
        appState.setInitialLoading(true);
      }

      try {
        // Push then pull
        await Pusher.pushPendingUpdates(appState);
        
        final db = await DatabaseHelper.database;
        await Puller.pull(db, token, sheetId, sheetName);
        
        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }
        
        // Decrease backoff on success
        if (_rateLimitBackoffMultiplier > 1) {
          _decreaseBackoff();
          LoggerUtil.info('[SyncEngine] Backoff decreased to ${_intervalMs * _rateLimitBackoffMultiplier}ms');
        }
      } on SheetsRateLimitException {
        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }
        _increaseBackoff();
        LoggerUtil.warn('[SyncEngine] Rate limit, backoff: ${_intervalMs * _rateLimitBackoffMultiplier}ms');
      } catch (e) {
        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }
        LoggerUtil.error('[SyncEngine] Sync error: $e', error: e);
      }

      // Update pending count
      final pendingCount = await SyncQueueDao.getPendingCount();
      appState.setPendingTaskCount(pendingCount);
      LoggerUtil.debug('[SyncEngine] Sync done. Pending: $pendingCount');

      // Wait for next tick
      await Future.delayed(Duration(milliseconds: _intervalMs * _rateLimitBackoffMultiplier));
    }
  }

  static void _increaseBackoff() {
    _rateLimitBackoffMultiplier = (_rateLimitBackoffMultiplier * 2).clamp(1, 8);
  }

  static void _decreaseBackoff() {
    _rateLimitBackoffMultiplier = (_rateLimitBackoffMultiplier ~/ 2).clamp(1, 8);
  }

  static Future<String?> _getSettingValue(String key) async {
    try {
      final db = await DatabaseHelper.database;
      final result = await db.rawQuery(
        'SELECT value FROM app_settings WHERE key = ?',
        [key],
      );
      if (result.isNotEmpty) {
        return result.first['value'] as String?;
      }
      return null;
    } catch (e) {
      LoggerUtil.error('[SyncEngine] Error reading setting $key: $e', error: e);
      return null;
    }
  }
}