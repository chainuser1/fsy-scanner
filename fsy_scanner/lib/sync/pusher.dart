import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import '../auth/google_auth.dart';
import '../db/database_helper.dart';
import '../db/sync_queue_dao.dart';
import '../models/sync_task.dart';
import '../providers/app_state.dart';
import 'sheets_api.dart';

class Pusher {
  static Future<bool> pushPendingUpdates(AppState appState) async {
    debugPrint('[Pusher] Starting pending updates...');
    
    try {
      final token = await GoogleAuth.getValidToken();
      if (token == null) return false;

      final db = await DatabaseHelper.database;
      
      // Get sheet config
      final sheetIdResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['sheets_id']);
      final sheetTabResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['sheets_tab']);
      final colMapResult = await db.query('app_settings', where: 'key = ?', whereArgs: ['col_map']);

      if (sheetIdResult.isEmpty || sheetTabResult.isEmpty || colMapResult.isEmpty) {
        debugPrint('[Pusher] Missing sheet configuration');
        return false;
      }

      final sheetId = sheetIdResult.first['value'] as String;
      final tabName = sheetTabResult.first['value'] as String;
      final colMap = Map<String, int>.from(jsonDecode(colMapResult.first['value'] as String));

      while (true) {
        final task = await SyncQueueDao.claimNextTask();
        if (task == null) break;

        try {
          final success = await _processTask(db, token, sheetId, tabName, colMap, task);
          
          if (success) {
            await SyncQueueDao.markCompleted(task.id!);
            // Verify that markCompleted deletes the row
            final completedTask = await SyncQueueDao.getTask(task.id!);
            if (completedTask != null) {
              debugPrint('[Pusher] Warning: Task ${task.id} not deleted after completion');
            }
          } else {
            await SyncQueueDao.markFailed(task.id!, 'Failed to update Sheets');
            
            // Check if task has reached max attempts
            final failedTask = await SyncQueueDao.getTask(task.id!);
            if (failedTask != null && failedTask.attempts >= 10) {
              // Increment the failed task count in AppState
              appState.incrementFailedTaskCount();
              // Set a sync error in AppState to show to the user
              appState.setSyncError('${failedTask.attempts} tasks failed after 10 attempts');
            }
            
            // If we failed, stop draining to avoid rate limits or repeated errors
            return false;
          }
        } on SheetsRateLimitException {
          // If we encounter rate limiting, mark the task as failed and rethrow
          await SyncQueueDao.markFailed(task.id!, 'Rate limit encountered');
          rethrow; // Rethrow to be caught by sync_engine.dart
        }
      }
      
      return true;
    } catch (e) {
      debugPrint('[Pusher] Error pushing updates: $e');
      // If it's a rate limit exception, we should propagate it
      if (e is SheetsRateLimitException) {
        rethrow;
      }
      return false;
    }
  }
  
  static Future<bool> _processTask(Database db, String token, String sheetId, String tabName, Map<String, int> colMap, SyncTask task) async {
    try {
      final Map<String, dynamic> payload = jsonDecode(task.payload);
      final int sheetsRow = payload['sheetsRow'] ?? 0;
      if (sheetsRow == 0) return false;

      final Map<String, String> values = {};

      if (task.type == 'mark_registered') {
        values['Registered'] = 'Y';
        values['Verified At'] = DateTime.fromMillisecondsSinceEpoch(payload['verifiedAt']).toIso8601String();
        // Section 7.8 also mentions Registered By, but the sheet contract 4.1 doesn't have it as a column.
        // I'll stick to what's in the contract 4.1 table.
      } else if (task.type == 'mark_printed') {
        values['Printed At'] = DateTime.fromMillisecondsSinceEpoch(payload['printedAt']).toIso8601String();
      }

      if (values.isEmpty) return true;

      await SheetsApi.updateRegistrationRow(token, sheetId, tabName, sheetsRow, colMap, values);
      return true;
    } on SheetsRateLimitException {
      // Re-throw rate limit exceptions so they can be handled upstream
      rethrow;
    } catch (e) {
      debugPrint('[Pusher] Error processing task ${task.id}: $e');
      return false;
    }
  }
}