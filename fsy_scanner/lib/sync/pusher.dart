import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import '../models/sync_task.dart';
import '../providers/app_state.dart';
import '../utils/logger.dart';
import 'sheets_api.dart';

class Pusher {
  static Future<bool> pushPendingUpdates(AppState appState) async {
    LoggerUtil.debug('[Pusher] Starting pending updates...');

    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) {
        LoggerUtil.warn('[Pusher] No valid token available');
        return false;
      }

      final db = await DatabaseHelper.database;

      final sheetIdResult = await db
          .query('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
      final sheetTabResult = await db
          .query('app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
      final colMapResult = await db
          .query('app_settings', where: 'key = ?', whereArgs: ['col_map']);

      if (sheetIdResult.isEmpty ||
          sheetTabResult.isEmpty ||
          colMapResult.isEmpty) {
        LoggerUtil.warn('[Pusher] Missing sheet configuration');
        return false;
      }

      final sheetId = sheetIdResult.first['value'] as String;
      final tabName = sheetTabResult.first['value'] as String;
      final colMap = Map<String, int>.from(
          jsonDecode(colMapResult.first['value'] as String));

      while (true) {
        final task = await SyncQueueDao.claimNextTask();
        if (task == null) break;

        try {
          final success =
              await _processTask(db, token, sheetId, tabName, colMap, task);

          if (success) {
            await SyncQueueDao.markCompleted(task.id!);
            LoggerUtil.debug('[Pusher] Task ${task.id} completed');
          } else {
            await SyncQueueDao.markFailed(task.id!, 'Failed to update Sheets');
            LoggerUtil.warn('[Pusher] Task ${task.id} failed');

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
      final String participantId = payload['participantId'] as String? ?? '';
      if (participantId.isEmpty) {
        LoggerUtil.warn('[Pusher] No participantId in task ${task.id}');
        return false;
      }

      final int? currentRow = await SheetsApi.findRowByValue(
        accessToken: token,
        sheetId: sheetId,
        tabName: tabName,
        colMap: colMap,
        searchValue: participantId,
      );
      if (currentRow == null) {
        LoggerUtil.warn(
            '[Pusher] Participant $participantId not found in sheet');
        return false;
      }

      final Map<String, String> values = {};

      if (task.type == SyncQueueDao.typeMarkRegistered) {
        final verifiedAt = payload['verifiedAt'] as int?;
        if (verifiedAt != null) {
          values['Verified At'] =
              DateTime.fromMillisecondsSinceEpoch(verifiedAt).toIso8601String();
        }
        final registeredBy = payload['registeredBy'] as String?;
        if (registeredBy != null) {
          values['Device ID'] = registeredBy;
        }
      } else if (task.type == SyncQueueDao.typeMarkPrinted) {
        final printedAt = payload['printedAt'] as int?;
        if (printedAt != null) {
          values['Printed At'] =
              DateTime.fromMillisecondsSinceEpoch(printedAt).toIso8601String();
        }
      } else if (task.type == SyncQueueDao.typeMarkUnverified) {
        // Clear Verified At and Device ID
        values['Verified At'] = '';
        values['Device ID'] = '';
      }

      if (values.isNotEmpty) {
        await SheetsApi.updateCells(
          accessToken: token,
          sheetId: sheetId,
          tabName: tabName,
          row: currentRow,
          colMap: colMap,
          values: values,
        );
      }
      LoggerUtil.info('[Pusher] Updated row $currentRow for $participantId');
      return true;
    } on SheetsRateLimitException {
      rethrow;
    } catch (e) {
      LoggerUtil.error('[Pusher] Error processing task ${task.id}: $e',
          error: e);
      return false;
    }
  }
}
