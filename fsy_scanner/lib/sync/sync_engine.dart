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
  static const int _activeIntervalMs = 2000;
  static const int _idleIntervalMs = 300000;
  static const int _idleThresholdSeconds = 300;
  static const int _offlineRetryMs = 10000;
  static const int _noAuthRetryMs = 30000;
  static const int _noConfigRetryMs = 30000;

  static bool _isSyncing = false;
  static final _syncStatusController =
      StreamController<Map<String, dynamic>>.broadcast();
  static int _rateLimitBackoffMultiplier = 1;
  static DateTime _lastUserActivity = DateTime.now();

  static bool get isSyncing => _isSyncing;
  static Stream<Map<String, dynamic>> get syncStatusStream =>
      _syncStatusController.stream;

  static void _setSyncing(bool value, {String? message, double? progress}) {
    _isSyncing = value;
    _syncStatusController.add({
      'syncing': value,
      'message': message ?? '',
      'progress': progress ?? 0.0,
    });
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

    LoggerUtil.info(
        '[SyncEngine] Active interval: ${_activeIntervalMs}ms, Idle: ${_idleIntervalMs}ms');
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
    _setSyncing(true, message: 'Full sync started');
    LoggerUtil.info('[SyncEngine] Performing full sync...');
    try {
      _setSyncing(true, message: 'Pushing pending updates...', progress: 0.0);
      final pushSuccess = await Pusher.pushPendingUpdates(appState);
      _setSyncing(true, message: 'Pulling latest data...', progress: 0.5);

      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;

      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) return false;

      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      unawaited(appState.refreshParticipantsCount());
      appState.setLastSyncedAt(DateTime.now());

      _setSyncing(true, message: 'Sync complete', progress: 1.0);
      await Future.delayed(const Duration(seconds: 1));
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
    _setSyncing(true, message: 'Pull sync started');
    LoggerUtil.info('[SyncEngine] Performing pull sync...');
    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;

      final sheetId = await _getSettingValue('sheets_id');
      final sheetName = await _getSettingValue('sheets_tab');
      if (sheetId == null || sheetName == null) return false;

      _setSyncing(true, message: 'Fetching data...', progress: 0.5);
      final db = await DatabaseHelper.database;
      await Puller.pull(db, token, sheetId, sheetName);
      unawaited(appState.refreshParticipantsCount());
      appState.setLastSyncedAt(DateTime.now());

      _setSyncing(true, message: 'Pull complete', progress: 1.0);
      await Future.delayed(const Duration(seconds: 1));
      return true;
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
      // Safety: force-reset syncing flag if it's been stuck for > 30 seconds
      if (_isSyncing) {
        LoggerUtil.debug(
            '[SyncEngine] Waiting for previous sync to complete...');
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

      LoggerUtil.info('[SyncEngine] Starting sync tick...');
      try {
        _setSyncing(true, message: 'Pushing…', progress: 0.0);
        await Pusher.pushPendingUpdates(appState);
        _setSyncing(true, message: 'Pulling…', progress: 0.5);

        final db = await DatabaseHelper.database;
        await Puller.pull(db, token, sheetId, sheetName);
        unawaited(appState.refreshParticipantsCount());
        appState.setLastSyncedAt(DateTime.now());

        _setSyncing(true, message: 'Sync done', progress: 1.0);
        await Future.delayed(const Duration(milliseconds: 500));

        if (isFirstLoad) {
          appState.setInitialLoading(false);
        }

        if (_rateLimitBackoffMultiplier > 1) {
          _decreaseBackoff();
          LoggerUtil.info(
              '[SyncEngine] Backoff decreased to ${_currentIntervalMs()}ms');
        }
      } on SheetsRateLimitException {
        if (isFirstLoad) appState.setInitialLoading(false);
        _increaseBackoff();
        LoggerUtil.warn(
            '[SyncEngine] Rate limit, backoff: ${_currentIntervalMs()}ms');
      } catch (e) {
        if (isFirstLoad) appState.setInitialLoading(false);
        LoggerUtil.error('[SyncEngine] Sync error: $e', error: e);
      } finally {
        _setSyncing(false);
      }

      final pendingCount = await SyncQueueDao.getPendingCount();
      appState.setPendingTaskCount(pendingCount);
      LoggerUtil.info(
          '[SyncEngine] Sync tick complete. Pending: $pendingCount');

      final waitMs = _currentIntervalMs();
      LoggerUtil.info('[SyncEngine] Next sync in ${waitMs}ms');
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
      final result = await db
          .rawQuery('SELECT value FROM app_settings WHERE key = ?', [key]);
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
