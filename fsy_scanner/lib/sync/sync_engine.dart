import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
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
  // Adaptive polling intervals
  static const int _activeIntervalMs = 2000; // 2 seconds when actively scanning
  static const int _idleIntervalMs = 300000; // 5 minutes when idle
  static const int _idleThresholdSeconds =
      300; // 5 minutes without activity = idle
  static const int _offlineRetryMs = 10000; // 10 seconds when offline
  static const int _noAuthRetryMs = 30000; // 30 seconds when no auth token
  static const int _noConfigRetryMs =
      30000; // 30 seconds when missing sheet config

  static bool _isSyncing = false;
  static final _syncStatusController = StreamController<bool>.broadcast();
  static int _rateLimitBackoffMultiplier = 1;
  static DateTime _lastUserActivity = DateTime.now();

  static bool get isSyncing => _isSyncing;
  static Stream<bool> get syncStatusStream => _syncStatusController.stream;

  static void _setSyncing(bool value) {
    _isSyncing = value;
    _syncStatusController.add(value);
  }

  static void notifyUserActivity() {
    _lastUserActivity = DateTime.now();
  }

  static Future<void> startup(AppState appState) async {
    LoggerUtil.info('[SyncEngine] Initializing...');

    final db = await DatabaseHelper.database;
    await SyncQueueDao.resetInProgressTasks();

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

    final colMapResult = await db
        .query('app_settings', where: 'key = ?', whereArgs: ['col_map']);

    if (colMapResult.isEmpty ||
        colMapResult.first['value'] == null ||
        (colMapResult.first['value'] as String).isEmpty) {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        try {
          final sheetIdResult = await db.query('app_settings',
              where: 'key = ?', whereArgs: ['sheets_id']);
          final sheetTabResult = await db.query('app_settings',
              where: 'key = ?', whereArgs: ['sheets_tab']);

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

    LoggerUtil.info('[SyncEngine] Active interval: ${_activeIntervalMs}ms, '
        'Idle interval: ${_idleIntervalMs}ms, '
        'Idle threshold: ${_idleThresholdSeconds}s');

    _lastUserActivity = DateTime.now();

    await Future.delayed(const Duration(seconds: 3));
    unawaited(_syncLoop(appState));
  }

  static void dispose() {
    _syncStatusController.close();
  }

  static Future<bool> performFullSync(AppState appState) async {
    notifyUserActivity();
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
      unawaited(appState.refreshParticipantsCount());
      appState.setLastSyncedAt(DateTime.now());

      LoggerUtil.info('[SyncEngine] Full sync completed');
      return pushSuccess;
    } on SheetsRateLimitException {
      _increaseBackoff();
      LoggerUtil.warn(
          '[SyncEngine] Rate limit, backoff: ${_currentIntervalMs()}ms');
      return false;
    } catch (e) {
      LoggerUtil.error('[SyncEngine] Full sync error: $e', error: e);
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  static Future<bool> performPullSync(AppState appState) async {
    notifyUserActivity();
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
      unawaited(appState.refreshParticipantsCount());
      appState.setLastSyncedAt(DateTime.now());

      LoggerUtil.info('[SyncEngine] Pull sync completed');
      return true;
    } on SheetsRateLimitException {
      _increaseBackoff();
      LoggerUtil.warn(
          '[SyncEngine] Rate limit, backoff: ${_currentIntervalMs()}ms');
      return false;
    } catch (e) {
      LoggerUtil.error('[SyncEngine] Pull sync error: $e', error: e);
      return false;
    } finally {
      _setSyncing(false);
    }
  }

  static Future<void> pushImmediately(AppState appState) async {
    notifyUserActivity();
    if (_isSyncing) return;
    LoggerUtil.debug('[SyncEngine] Push immediately requested');
    try {
      final token = await GoogleAuth.getValidToken();
      if (token != null) {
        await Pusher.pushPendingUpdates(appState);
      }
    } catch (e) {
      LoggerUtil.error('[SyncEngine] Immediate push error: $e', error: e);
    }
  }

  static Future<void> _syncLoop(AppState appState) async {
    final initialConnectivity = await Connectivity().checkConnectivity();
    appState
        .setIsOnline(!initialConnectivity.contains(ConnectivityResult.none));

    while (true) {
      if (_isSyncing) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      final connectivityResult = await Connectivity().checkConnectivity();
      final isCurrentlyOnline =
          !connectivityResult.contains(ConnectivityResult.none);

      if (isCurrentlyOnline != appState.isOnline) {
        appState.setIsOnline(isCurrentlyOnline);
        if (isCurrentlyOnline) {
          LoggerUtil.info('[SyncEngine] Connection restored');
          _lastUserActivity = DateTime.now();
        } else {
          LoggerUtil.warn('[SyncEngine] Connection lost');
        }
      }

      if (connectivityResult.contains(ConnectivityResult.none)) {
        LoggerUtil.debug(
            '[SyncEngine] Offline, waiting ${_offlineRetryMs}ms...');
        await Future.delayed(const Duration(milliseconds: _offlineRetryMs));
        continue;
      }

      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        LoggerUtil.warn(
            '[SyncEngine] No auth token, waiting ${_noAuthRetryMs}ms...');
        await Future.delayed(const Duration(milliseconds: _noAuthRetryMs));
        continue;
      }

      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) {
        LoggerUtil.warn(
            '[SyncEngine] Missing sheet config, waiting ${_noConfigRetryMs}ms...');
        await Future.delayed(const Duration(milliseconds: _noConfigRetryMs));
        continue;
      }

      final lastPulledResult = await _getSettingValue('last_pulled_at');
      final isFirstLoad = lastPulledResult == null || lastPulledResult == '0';

      if (isFirstLoad) {
        appState.setInitialLoading(true);
      }

      try {
        await Pusher.pushPendingUpdates(appState);

        final db = await DatabaseHelper.database;
        await Puller.pull(db, token, sheetId, sheetName);

        // Update count and last sync time
        unawaited(appState.refreshParticipantsCount());
        appState.setLastSyncedAt(DateTime.now());

        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }

        if (_rateLimitBackoffMultiplier > 1) {
          _decreaseBackoff();
          LoggerUtil.info(
              '[SyncEngine] Backoff decreased to ${_currentIntervalMs()}ms');
        }
      } on SheetsRateLimitException {
        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }
        _increaseBackoff();
        LoggerUtil.warn(
            '[SyncEngine] Rate limit, backoff: ${_currentIntervalMs()}ms');
      } catch (e) {
        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }
        LoggerUtil.error('[SyncEngine] Sync error: $e', error: e);
      }

      final pendingCount = await SyncQueueDao.getPendingCount();
      appState.setPendingTaskCount(pendingCount);
      LoggerUtil.debug('[SyncEngine] Sync done. Pending: $pendingCount');

      final waitMs = _currentIntervalMs();
      LoggerUtil.debug('[SyncEngine] Next sync in ${waitMs}ms');
      await Future.delayed(Duration(milliseconds: waitMs));
    }
  }

  static int _currentIntervalMs() {
    final idleSeconds = DateTime.now().difference(_lastUserActivity).inSeconds;
    final baseInterval = idleSeconds > _idleThresholdSeconds
        ? _idleIntervalMs
        : _activeIntervalMs;
    return baseInterval * _rateLimitBackoffMultiplier;
  }

  static void _increaseBackoff() {
    _rateLimitBackoffMultiplier = (_rateLimitBackoffMultiplier * 2).clamp(1, 8);
  }

  static void _decreaseBackoff() {
    _rateLimitBackoffMultiplier =
        (_rateLimitBackoffMultiplier ~/ 2).clamp(1, 8);
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
