import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import '../models/sync_task.dart';
import '../providers/app_state.dart';
import '../utils/logger.dart';
import 'sheets_api.dart';

class Pusher {
  /// Push all pending sync tasks to Google Sheets
  static Future<bool> pushPendingUpdates(AppState appState) async {
    LoggerUtil.debug('[Pusher] Starting pending updates...');
    
    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        LoggerUtil.warn('[Pusher] No valid token available');
        return false;
      }

      final db = await DatabaseHelper.database;
      
      // Get sheet config
      final sheetIdResult = await db.query(
        'app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
      final sheetTabResult = await db.query(
        'app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
      final colMapResult = await db.query(
        'app_settings', where: 'key = ?', whereArgs: ['col_map']);

      if (sheetIdResult.isEmpty || sheetTabResult.isEmpty || colMapResult.isEmpty) {
        LoggerUtil.warn('[Pusher] Missing sheet configuration');
        return false;
      }

      final sheetId = sheetIdResult.first['value'] as String;
      final tabName = sheetTabResult.first['value'] as String;
      final colMap = Map<String, int>.from(
        jsonDecode(colMapResult.first['value'] as String));

      while (true) {
        final task = await SyncQueueDao.claimNextTask();
        if (task == null) {
          LoggerUtil.debug('[Pusher] No more pending tasks');
          break;
        }

        try {
          final success = await _processTask(
            db, token, sheetId, tabName, colMap, task);
          
          if (success) {
            await SyncQueueDao.markCompleted(task.id!);
            LoggerUtil.debug('[Pusher] Task ${task.id} completed');
          } else {
            await SyncQueueDao.markFailed(task.id!, 'Failed to update Sheets');
            LoggerUtil.warn('[Pusher] Task ${task.id} failed');
            
            // Check if task has reached max attempts
            final failedTask = await SyncQueueDao.getTask(task.id!);
            if (failedTask != null && failedTask.attempts >= 10) {
              appState.incrementFailedTaskCount();
              appState.setSyncError(
                '${failedTask.attempts} tasks failed after 10 attempts');
              LoggerUtil.error(
                '[Pusher] Task ${task.id} permanently failed after 10 attempts');
            }
            
            return false;
          }
        } on SheetsRateLimitException {
          await SyncQueueDao.markFailed(task.id!, 'Rate limit encountered');
          LoggerUtil.warn('[Pusher] Rate limit on task ${task.id}');
          rethrow;
        }
      }
      
      return true;
    } on SheetsRateLimitException {
      rethrow;
    } catch (e) {
      LoggerUtil.error('[Pusher] Error: $e', error: e);
      return false;
    }
  }
  
  /// Process a single sync task
  static Future<bool> _processTask(
    Database db,
    String token,
    String sheetId,
    String tabName,
    Map<String, int> colMap,
    SyncTask task,
  ) async {
    try {
      final Map<String, dynamic> payload = jsonDecode(task.payload);
      final int? sheetsRow = payload['sheetsRow'] as int?;
      
      if (sheetsRow == null || sheetsRow == 0) {
        LoggerUtil.warn('[Pusher] Invalid sheetsRow in task ${task.id}');
        return false;
      }

      final Map<String, String> values = {};

      if (task.type == SyncQueueDao.typeMarkRegistered) {
        values['Registered'] = 'Y';
        final verifiedAt = payload['verifiedAt'] as int?;
        if (verifiedAt != null) {
          values['Verified At'] =
              DateTime.fromMillisecondsSinceEpoch(verifiedAt).toIso8601String();
        }
      } else if (task.type == SyncQueueDao.typeMarkPrinted) {
        final printedAt = payload['printedAt'] as int?;
        if (printedAt != null) {
          values['Printed At'] =
              DateTime.fromMillisecondsSinceEpoch(printedAt).toIso8601String();
        }
      }

      if (values.isEmpty) {
        LoggerUtil.warn('[Pusher] No values to update for task ${task.id}');
        return true;
      }

      await SheetsApi.updateRegistrationRow(
        token, sheetId, tabName, sheetsRow, colMap, values);
      LoggerUtil.info('[Pusher] Updated row $sheetsRow for task ${task.id}');
      return true;
    } on SheetsRateLimitException {
      rethrow;
    } catch (e) {
      LoggerUtil.error('[Pusher] Error processing task ${task.id}: $e', error: e);
      return false;
    }
  }
}